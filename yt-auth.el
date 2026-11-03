;;; yt-auth.el --- Sign in to YouTube with Chromium cookies -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; yt signs in with the YouTube cookies of a Chromium profile that is
;; used only for YouTube.  `yt-login' asks for the profile and runs the
;; yt-export-cookies program, which writes only the youtube.com cookies
;; to a mode 0600 "master" file in `yt-state-directory'.
;;
;; yt-dlp never sees the master file.  `yt-auth-run' gives every
;; yt-dlp run a private copy in the runtime directory.  yt-dlp saves
;; cookies that YouTube rotated into that copy when it exits; after a
;; successful run the copy replaces the master file, unless the master
;; was re-exported in the meantime (tracked by a generation counter).
;; When a run finds the session expired, the cookies are re-exported
;; once (concurrent runs share one export) and the run is retried once.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'yt)
(require 'yt-process)
(require 'yt-ytdlp)

(defvar yt-auth-bot-check-backoff 900
  "Seconds to stop sending requests after YouTube asks for a bot check.")

(defvar yt-auth-rate-limit-backoff 3600
  "Seconds to stop sending requests after YouTube limits the rate.")

(defvar yt-auth-state-change-hook nil
  "Hook run after the sign-in state changes; see `yt-auth-state'.")

(defvar yt-auth-export-timeout 30
  "Seconds after which the cookie exporter is stopped.
It waits for the keyring, which may be locked.")

(defvar yt-auth--state 'unknown
  "The sign-in state; see `yt-auth-state'.")

(defvar yt-auth--state-time nil
  "When `yt-auth--state' last changed, in seconds since the epoch.")

(defvar yt-auth--generation 0
  "Counter incremented each time the master cookie file is replaced.")

(defvar yt-auth--export-waiters nil
  "Callbacks waiting for the running cookie export.")

(defvar yt-auth--backoff nil
  "Nil, or (CLASS . UNTIL) while yt waits after a bot check or rate limit.")

(defvar yt-auth--stale-copies-cleaned nil
  "Non-nil once old cookie copies were removed in this session.")

(defun yt-auth-state ()
  "Return the sign-in state.
It is one of `unknown', `ok', `no-cookies', `expired', `keyring',
`bad-profile', `bot-check', `rate-limit' and `corrupt-cookies'."
  yt-auth--state)

(defun yt-auth--set-state (state)
  "Set the sign-in state to STATE and run `yt-auth-state-change-hook'."
  (setq yt-auth--state state
        yt-auth--state-time (yt--now))
  (run-hooks 'yt-auth-state-change-hook))

(defun yt-auth-set-state (state)
  "Set the sign-in state to STATE, one of those of `yt-auth-state'.
For requests yt sends without yt-dlp, such as subscribing."
  (yt-auth--set-state state))

(defun yt-auth-note-failure (class)
  "Note a failure of CLASS, such as `rate-limit', of a request yt sent itself.
Set the sign-in state, and pause requests after a bot check or a
rate limit."
  (yt-auth--set-state class)
  (yt-auth--start-backoff class))

(defun yt-auth-cookie-file ()
  "Return the name of the master cookie file."
  (expand-file-name "cookies.txt" (yt-ensure-state-directory)))

;;;; Chromium profiles

(defun yt-auth-chromium-profiles ()
  "Return an alist (DIRECTORY . NAME) of the Chromium profiles.
The list comes from \"Local State\" in `yt-chromium-directory'."
  (let ((file (expand-file-name "Local State" yt-chromium-directory))
        profiles)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let* ((json (condition-case nil
                         (json-parse-buffer :object-type 'hash-table
                                            :null-object nil
                                            :false-object nil)
                       (json-error nil)))
               (profile (and (hash-table-p json) (gethash "profile" json)))
               (cache (and (hash-table-p profile)
                           (gethash "info_cache" profile))))
          (when (hash-table-p cache)
            (maphash (lambda (dir info)
                       (push (cons dir (or (and (hash-table-p info)
                                                (gethash "name" info))
                                           dir))
                             profiles))
                     cache)))))
    (sort profiles (lambda (a b) (string< (car a) (car b))))))

(defun yt-auth-profile ()
  "Return the Chromium profile directory to read cookies from, or nil."
  (or yt-cookie-profile (yt-state-get 'cookie-profile)))

(defun yt-auth-profile-label (dir)
  "Return a description of the Chromium profile directory DIR."
  (let ((name (cdr (assoc dir (yt-auth-chromium-profiles)))))
    (if (and name (not (equal name dir)))
        (format "‘%s’ (%s)" name dir)
      (format "‘%s’" dir))))

(defun yt-auth-read-profile ()
  "Ask which Chromium profile to read YouTube cookies from.
Return its directory name.  Choosing the Default profile needs
confirmation, because it usually holds the main Google session."
  (let* ((profiles (or (yt-auth-chromium-profiles)
                       (user-error "No Chromium profiles found in %s"
                                   yt-chromium-directory)))
         (candidates (mapcar (lambda (p)
                               (cons (format "%s (%s)" (cdr p) (car p)) (car p)))
                             profiles))
         (default (car (seq-find (lambda (c)
                                   (equal (cdr (assoc (cdr c) profiles))
                                          "emacs-yt"))
                                 candidates)))
         (dir (cdr (assoc (completing-read "Chromium profile for YouTube: "
                                           candidates nil t nil nil default)
                          candidates))))
    (when (and (equal dir "Default")
               (not (yes-or-no-p "The Default profile usually holds your main \
Google session, and its cookies would be stored in a file; use it anyway? ")))
      (user-error "Create a Chromium profile used only for YouTube, then run M-x yt-login"))
    dir))

;;;; Exporting cookies

(defun yt-auth--export-failure (err)
  "Return a failure plist (:class :message) for the export error ERR."
  (let* ((summary (ignore-errors
                    (yt-process-parse-json (plist-get err :stdout))))
         (problem (or (plist-get summary :error) ""))
         (label (yt-auth-profile-label (yt-auth-profile))))
    (cond
     ((eq (plist-get err :type) 'timeout)
      (list :class 'timeout
            :message (format "Reading the cookies took more than %d s: is the keyring locked?  Unlock it, then try again"
                             yt-auth-export-timeout)))
     ((eq (plist-get err :type) 'cancelled)
      (list :class 'cancelled :message "Reading the cookies was cancelled"))
     ((eq (plist-get err :type) 'missing)
      (list :class 'missing
            :message (format "%s not found: install it (see Installation in yt's README), or set `yt-export-cookies-program'"
                             yt-export-cookies-program)))
     ((string-match-p "could not find [a-z]+ cookies database" problem)
      (list :class 'bad-profile
            :message (format "Chromium profile %s has no cookies: run C-u M-x yt-login to choose another one"
                             label)))
     ((> (or (plist-get summary :decrypt_failures) 0) 0)
      (list :class 'keyring
            :message (format "Could not decrypt %d cookies of Chromium profile %s: unlock the keyring, then try again"
                             (plist-get summary :decrypt_failures) label)))
     ((and summary (not (plist-get summary :has_login_info)))
      (list :class 'no-cookies
            :message (format "Chromium profile %s is not signed in to YouTube: sign in there, then run M-x yt-login"
                             label)))
     ((not (string-empty-p problem))
      (list :class 'keyring
            :message (format "Could not read the cookies of Chromium profile %s: %s"
                             label problem)))
     (t
      (list :class 'unknown
            :message (format "Exporting cookies failed: %s"
                             (yt-ytdlp-error-message nil (plist-get err :stderr))))))))

(defun yt-auth--export-done (ok result)
  "Finish the cookie export and call the waiting callbacks with OK and RESULT."
  (let ((waiters (nreverse yt-auth--export-waiters)))
    (setq yt-auth--export-waiters nil)
    (cond (ok (cl-incf yt-auth--generation))
          ;; A missing or hanging exporter says nothing about the session.
          ((memq (plist-get result :class) '(no-cookies keyring bad-profile corrupt-cookies))
           (yt-auth--set-state (plist-get result :class))))
    (dolist (waiter waiters)
      (with-demoted-errors "yt: %S"
        (funcall waiter ok result)))))

(defun yt-auth-export (callback)
  "Export the cookies of the chosen Chromium profile to the master file.
Call CALLBACK with OK and RESULT when done: on success RESULT is the
exporter's summary, a plist; on failure it is a plist with :class and
:message.  Calls made while an export is running share its result."
  ;; An export is under way while anyone waits for it: its process may
  ;; have exited already, with its callback still to come from a timer.
  (push callback yt-auth--export-waiters)
  (unless (cdr yt-auth--export-waiters)
    (condition-case err
        (yt-auth--start-export)
      ;; Such as a state directory yt refuses to use: end the export
      ;; now, or later exports would wait for it forever.
      (error (yt-process-deliver #'yt-auth--export-done nil
                                 (list :class 'no-cookies
                                       :message (error-message-string err)))))))

(defun yt-auth--start-export ()
  "Start the cookie exporter for `yt-auth-export'."
  (let ((profile (yt-auth-profile)))
    (if (not profile)
        (yt-process-deliver
         #'yt-auth--export-done nil
         (list :class 'no-cookies
               :message "No Chromium profile chosen: run M-x yt-login"))
      (yt-process-run
       yt-export-cookies-program
       (list "--profile" profile "--output" (yt-auth-cookie-file))
       :key '(yt-auth . export) :parse 'json :timeout yt-auth-export-timeout
       :on-success (lambda (summary _info)
                     (yt-auth--export-done t summary))
       :on-error (lambda (err)
                   (yt-auth--export-done nil (yt-auth--export-failure err)))))))

;;;; Per-run cookie copies

(defun yt-auth-sweep-leftovers (&optional all)
  "Delete the secret files that runs which never finished left behind.
They are cookie copies and curl configs (holding an authorization
header) in the runtime directory, and partly written cookie files in
the state directory, if older than an hour, or all of them if ALL is
non-nil; and the sockets of mpv processes that no longer run."
  (let ((old (time-subtract nil 3600)))
    (pcase-dolist (`(,dir . ,regexp)
                   `((,(yt-ensure-runtime-directory)
                      . "\\`\\(?:cookies-.*\\.txt\\|curl-.*\\.conf\\)\\'")
                     (,(yt-ensure-state-directory) . "\\`\\.cookies-")))
      (dolist (file (directory-files dir t regexp))
        (when (or all (time-less-p (file-attribute-modification-time (file-attributes file))
                                   old))
          (ignore-errors (delete-file file))))))
  (dolist (socket (directory-files (yt-ensure-runtime-directory) t
                                   "\\`mpv-\\([0-9]+\\)-[0-9]+\\.sock\\'"))
    (let ((pid (string-to-number
                (progn (string-match "mpv-\\([0-9]+\\)-" (file-name-nondirectory socket))
                       (match-string 1 (file-name-nondirectory socket))))))
      (unless (or (= pid (emacs-pid)) (process-attributes pid))
        (ignore-errors (delete-file socket))))))

(defun yt-auth-call-with-cookie-copy (fn)
  "Call FN with a private copy of the cookie file, which FN must delete.
If FN signals before it is done with the copy, the copy is deleted
here.  Return what FN returns."
  (let ((copy (yt-auth--copy-cookies (yt-auth-cookie-file))))
    (condition-case err
        (funcall fn copy)
      (error (ignore-errors (delete-file copy))
             (signal (car err) (cdr err))))))

(defun yt-auth--copy-cookies (master)
  "Return a private copy of the cookie file MASTER in the runtime directory."
  (let ((dir (yt-ensure-runtime-directory)))
    (unless yt-auth--stale-copies-cleaned
      (setq yt-auth--stale-copies-cleaned t)
      (yt-auth-sweep-leftovers))
    (let ((copy (with-file-modes #o600
                  (make-temp-file (expand-file-name "cookies-" dir) nil ".txt"))))
      (copy-file master copy t)
      (set-file-modes copy #o600)
      copy)))

(defun yt-auth--cookie-file-valid-p (file)
  "Return non-nil if FILE is a Netscape cookie file with YouTube login cookies."
  (and (file-readable-p file)
       (with-temp-buffer
         (insert-file-contents file)
         (goto-char (point-min))
         (and (looking-at-p "# Netscape HTTP Cookie File")
              (re-search-forward "\tLOGIN_INFO\t" nil t)
              (progn
                (goto-char (point-min))
                (re-search-forward "\t\\(?:SAPISID\\|__Secure-3PAPISID\\)\t"
                                   nil t))
              t))))

(defconst yt-auth--login-cookies
  '("LOGIN_INFO" "SID" "HSID" "SSID" "APISID" "SAPISID"
    "__Secure-1PSID" "__Secure-3PSID" "__Secure-1PAPISID" "__Secure-3PAPISID")
  "The cookies of a signed-in YouTube session.")

(defun yt-auth--youtube-lines (file)
  "Return the Netscape header and the youtube.com cookie lines of FILE.
yt-dlp may save cookies of other domains into its copy; the master
file keeps only YouTube's, as the exporter writes it."
  (with-temp-buffer
    (insert-file-contents file)
    (let (lines)
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((domain (car (split-string (string-remove-prefix "#HttpOnly_" line) "\t"))))
          (when (or (string-prefix-p "# Netscape HTTP Cookie File" line)
                    (and (string-match-p "\t" line)
                         (string-match-p "\\`\\.?\\(?:[^.]+\\.\\)*youtube\\.com\\'" domain)))
            (push line lines))))
      (nreverse lines))))

(defun yt-auth--cookie-names (lines)
  "Return the names of the cookies in LINES of a Netscape cookie file."
  (delq nil (mapcar (lambda (line) (nth 5 (split-string line "\t"))) lines)))

(defun yt-auth--write-back (copy generation)
  "Make the cookie file COPY the new master file, if that is safe.
It is safe if the master file was not replaced since GENERATION and
COPY still holds every login cookie the master has.  Only the
youtube.com cookies are written.  The old master is kept as
cookies.txt.prev, and the new one replaces it atomically: it is
written next to it, then renamed over it."
  (when (= generation yt-auth--generation)
    (let* ((master (yt-auth-cookie-file))
           (lines (yt-auth--youtube-lines copy))
           (names (yt-auth--cookie-names lines))
           (needed (seq-intersection (yt-auth--cookie-names (yt-auth--youtube-lines master))
                                     yt-auth--login-cookies)))
      (when (seq-every-p (lambda (name) (member name names)) needed)
        (let ((tmp (with-file-modes #o600
                     (make-temp-file (expand-file-name ".cookies-"
                                                       (file-name-directory master))))))
          (unwind-protect
              (progn
                (with-temp-file tmp
                  (insert (string-join lines "\n") "\n"))
                (set-file-modes tmp #o600)
                (when (yt-auth--cookie-file-valid-p tmp)
                  (with-file-modes #o600
                    (copy-file master (concat master ".prev") t))
                  (set-file-modes (concat master ".prev") #o600)
                  (rename-file tmp master t)))
            (when (file-exists-p tmp)
              (ignore-errors (delete-file tmp)))))))))

;;;; Running yt-dlp with cookies

(defconst yt-auth--auth-classes
  '(expired no-cookies corrupt-cookies bot-check rate-limit)
  "Problem classes that change the sign-in state.")

(defun yt-auth--backing-off ()
  "Return (CLASS . UNTIL) while yt is backing off, else nil."
  (and yt-auth--backoff (< (yt--now) (cdr yt-auth--backoff)) yt-auth--backoff))

(defun yt-auth-backoff-description ()
  "Describe the pause after a bot check or rate limit, or return nil."
  (when-let* ((backoff (yt-auth--backing-off)))
    (format "Paused until %s (%s)"
            (format-time-string "%H:%M" (cdr backoff))
            (pcase (car backoff)
              ('bot-check "YouTube asked for a bot check")
              ('rate-limit "YouTube is limiting requests")
              (class (symbol-name class))))))

(defun yt-auth-backing-off-p ()
  "Return (CLASS . UNTIL) while yt pauses its requests, else nil.
CLASS is `bot-check' or `rate-limit', and UNTIL a time in seconds."
  (yt-auth--backing-off))

(defun yt-auth--start-backoff (class)
  "Stop sending requests for a while after a problem of CLASS."
  (let ((secs (pcase class
                ('bot-check yt-auth-bot-check-backoff)
                ('rate-limit yt-auth-rate-limit-backoff))))
    (when secs
      (setq yt-auth--backoff (cons class (+ (yt--now) secs))))))

(defun yt-auth--empty-result-p (source value info)
  "Return non-nil if a SOURCE run returned no feed entries.
VALUE and INFO are what the run returned."
  (pcase source
    ('feed (and (zerop (or (plist-get info :lines) 0))
                (not (plist-get info :stopped))))
    ((or 'verify 'channels) (null (plist-get value :entries)))))

(cl-defun yt-auth-run (args &key on-success on-error on-line (parse 'json)
                            key force source ignore-backoff retried timeout
                            redact)
  "Run yt-dlp with ARGS and a private copy of the YouTube cookies.
ARGS come from one of the `yt-ytdlp-*-args' functions.  ON-SUCCESS,
ON-ERROR, ON-LINE, PARSE, KEY, FORCE and TIMEOUT are as for
`yt-process-run'; the plist given to ON-SUCCESS also has :class, a
warning class or nil.  The plist given to ON-ERROR also has :class
and :message, which is suitable for showing to the user.

SOURCE is `feed', `verify' or `channels' for requests that need a
signed-in session; for those, an empty result means the session has
expired.
An expired session is re-exported and the run retried once.
While yt backs off after a bot check or rate limit, the run fails
at once unless IGNORE-BACKOFF is non-nil.  REDACT is a list of
arguments, such as a search query, to leave out of *yt-log*.
RETRIED is for internal use."
  (let ((master (yt-auth-cookie-file))
        (backoff (and (not ignore-backoff) (yt-auth--backing-off))))
    (cond
     (backoff
      (yt-process-deliver
       on-error
       (list :type 'backoff :class (car backoff)
             :message (format "%s (waiting until %s)"
                              (yt-ytdlp-error-message (car backoff))
                              (format-time-string "%H:%M" (cdr backoff))))))
     ((not (file-exists-p master))
      (yt-auth--set-state 'no-cookies)
      (yt-process-deliver on-error
                          (list :type 'no-cookies :class 'no-cookies
                                :message (yt-ytdlp-error-message 'no-cookies))))
     (t
      (let* ((retry (lambda ()
                      (yt-auth-run args :on-success on-success :on-error on-error
                                   :on-line on-line :parse parse :key key
                                   :source source :ignore-backoff ignore-backoff
                                   :retried t :timeout timeout :redact redact)))
             (copy (yt-auth--copy-cookies master))
             (argv (condition-case err
                       (yt-ytdlp-args copy args)
                     (error (delete-file copy)
                            (signal (car err) (cdr err)))))
             (generation yt-auth--generation)
             (fail
              (lambda (err)
                (ignore-errors (delete-file copy))
                (yt-auth--failed err source generation retried retry on-error))))
        (or (yt-process-run
             yt-ytdlp-program argv
             :key key :force force :parse parse :on-line on-line :timeout timeout
             :log-args (and redact
                            (mapcar (lambda (arg) (if (member arg redact) "REDACTED" arg))
                                    argv))
             :on-success
             (lambda (value info)
               (let* ((empty (yt-auth--empty-result-p source value info))
                      (class (if empty
                                 'expired
                               (yt-ytdlp-classify (plist-get info :stderr) source))))
                 (if (memq class yt-auth--auth-classes)
                     (funcall fail (append (list :type 'exit :class class :empty empty)
                                           info))
                   (unwind-protect
                       ;; Saving rotated cookies is a bonus: a failure
                       ;; must not turn a good run into neither result.
                       (condition-case err
                           (yt-auth--write-back copy generation)
                         (error (yt-process-log "Keeping the old cookies: %s"
                                                (error-message-string err))))
                     (ignore-errors (delete-file copy)))
                   (when source
                     (yt-auth--set-state 'ok))
                   (when on-success
                     (funcall on-success value (append (list :class class) info))))))
             :on-error fail)
            (progn (ignore-errors (delete-file copy)) nil)))))))

(defun yt-auth--failed (err source generation retried retry on-error)
  "Handle the failed run ERR of SOURCE, which started at GENERATION.
RETRIED is non-nil if the run was already retried, RETRY is a
function that retries it, and ON-ERROR is the caller's callback."
  (let* ((type (plist-get err :type))
         (class (or (plist-get err :class)
                    (pcase type
                      ('missing 'missing)
                      ('timeout 'timeout)
                      ('cancelled 'cancelled)
                      (_ (yt-ytdlp-classify (plist-get err :stderr) source))))))
    (cond
     ((and (eq class 'expired) (not retried) (/= generation yt-auth--generation))
      ;; Another run re-exported the cookies meanwhile: just retry.
      (funcall retry))
     ((and (eq class 'expired) (not retried) (yt-auth-profile))
      (yt-auth-export (lambda (ok result)
                        (if ok
                            (funcall retry)
                          (yt-auth--report err result on-error)))))
     ((and retried (plist-get err :empty))
      ;; Still nothing with freshly exported cookies: more likely an
      ;; account without subscriptions, or a yt-dlp that no longer
      ;; understands YouTube, than an expired session.
      (yt-auth--report
       err
       (list :class 'empty
             :message (format "YouTube returned no %s with freshly exported cookies; %s"
                              (if (eq source 'channels) "channels" "videos")
                              (yt-ytdlp-update-hint)))
       on-error))
     (t
      (when (memq class yt-auth--auth-classes)
        (yt-auth--set-state class)
        (yt-auth--start-backoff class))
      (yt-auth--report
       err
       (list :class class
             :message (if (eq class 'missing)
                          (format "%s not found: install yt-dlp or set `yt-ytdlp-program'"
                                  yt-ytdlp-program)
                        (yt-ytdlp-error-message class (plist-get err :stderr))))
       on-error)))))

(defun yt-auth--report (err failure on-error)
  "Call ON-ERROR with ERR extended by the :class and :message of FAILURE."
  (when on-error
    (funcall on-error (append (list :class (plist-get failure :class)
                                    :message (plist-get failure :message))
                              err))))

;;;; Commands

(defun yt-auth-ensure-profile (&optional choose)
  "Return the Chromium profile to use, asking for it if none is chosen.
Also ask if CHOOSE is non-nil, and remember the answer."
  (when (or choose (not (yt-auth-profile)))
    (when yt-cookie-profile
      (user-error "The profile is set by `yt-cookie-profile'; change that option instead"))
    (yt-state-put 'cookie-profile (yt-auth-read-profile)))
  (yt-auth-profile))

;;;###autoload
(defun yt-login (&optional choose)
  "Sign in to YouTube with the cookies of a dedicated Chromium profile.
Ask for the profile the first time, or when CHOOSE (the prefix
argument) is non-nil.  Then export the profile's YouTube cookies and
check that they work.  Use a profile that is signed in only to
YouTube: the cookies are Google session tokens and are stored in a
mode 0600 file in `yt-state-directory'."
  (interactive "P")
  (yt-auth-sweep-leftovers)
  (yt-auth-ensure-profile choose)
  (let ((label (yt-auth-profile-label (yt-auth-profile))))
    (message "Reading YouTube cookies from Chromium profile %s..." label)
    (yt-auth-export (lambda (ok result)
                      (if ok
                          (yt-check-auth)
                        (message "%s" (plist-get result :message)))))))

;;;###autoload
(defun yt-check-auth ()
  "Check that the exported cookies are still signed in to YouTube."
  (interactive)
  (yt-ytdlp-check-version)
  (yt-auth-run (yt-ytdlp-verify-args)
               :key '(yt-auth . verify) :source 'verify :ignore-backoff t
               :on-success (lambda (_value _info)
                             ;; The session works again: whatever made
                             ;; YouTube ask for a bot check was fixed.
                             (let ((paused (yt-auth--backing-off)))
                               (setq yt-auth--backoff nil)
                               (when paused
                                 (run-hooks 'yt-auth-state-change-hook))
                               (message "Signed in to YouTube with Chromium profile %s%s"
                                        (yt-auth-profile-label (yt-auth-profile))
                                        (if paused "; requests are no longer paused" ""))))
               :on-error (lambda (err) (message "%s" (plist-get err :message)))))

;;;###autoload
(defun yt-logout ()
  "Delete yt's YouTube cookies.
This does not end the session itself; sign out of YouTube in the
Chromium profile to do that."
  (interactive)
  (let ((master (yt-auth-cookie-file)))
    (dolist (file (list master (concat master ".prev")))
      (when (file-exists-p file)
        (delete-file file))))
  (yt-auth-sweep-leftovers t)
  (cl-incf yt-auth--generation)
  (yt-auth--set-state 'no-cookies)
  (message "Deleted yt's cookies.  To end the session, sign out of YouTube in the Chromium profile"))

(provide 'yt-auth)
;;; yt-auth.el ends here
