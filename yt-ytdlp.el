;;; yt-ytdlp.el --- yt-dlp arguments and error classification -*- lexical-binding: t; -*-

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

;; Everything yt knows about yt-dlp's command line and messages: the
;; argument lists for each kind of request, the ordered table that
;; turns yt-dlp's standard error into a problem class, the messages
;; shown for each class, and the version check.  Running yt-dlp with
;; cookies is done by `yt-auth-run' in yt-auth.el.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'yt)
(require 'yt-process)

(defconst yt-ytdlp-base-args
  '("--ignore-config" "--color" "never" "--no-progress"
    "--socket-timeout" "20")
  "Arguments passed to every yt-dlp invocation, before the cookie file.")

(defconst yt-ytdlp--denied-args
  '("-v" "--verbose" "--print-traffic" "--dump-pages" "--write-pages"
    "--load-pages" "--write-info-json" "--cookies" "--cookies-from-browser"
    "--no-cookies" "--no-cookies-from-browser" "--print" "-O"
    "--no-warnings" "-q" "--quiet" "--compat-options" "--config-locations")
  "Options refused in `yt-ytdlp-extra-args'.
They would print secrets, change the output yt parses, hide the
warnings yt classifies, or replace yt's cookie handling.")

(defun yt-ytdlp--check-extra-args (args)
  "Return ARGS, or signal a `user-error' if one of them is denied."
  (dolist (arg args args)
    (dolist (flag yt-ytdlp--denied-args)
      (when (or (equal arg flag) (string-prefix-p (concat flag "=") arg))
        (user-error "Refusing to pass %s to yt-dlp; remove it from `yt-ytdlp-extra-args'"
                    arg)))))

(defun yt-ytdlp-args (cookie-file args)
  "Return the complete yt-dlp argument list for ARGS with COOKIE-FILE.
ARGS come from one of the `yt-ytdlp-*-args' functions and end with
\"--\" and the URL, so that nothing after \"--\" is read as an option."
  (append yt-ytdlp-base-args
          (list "--cookies" cookie-file)
          (yt-ytdlp--check-extra-args yt-ytdlp-extra-args)
          args))

(defun yt-ytdlp-feed-args (limit)
  "Return arguments that stream the first LIMIT subscription feed entries.
The output is one JSON object per line."
  (list "--flat-playlist" "--lazy-playlist" "-I" (format "1:%d" limit)
        "--extractor-args" "youtubetab:approximate_date"
        "-j" "--" ":ytsubs"))

(defun yt-ytdlp-verify-args ()
  "Return arguments that fetch three feed entries as one JSON document.
`:ytsubs' fails when yt-dlp has no login cookies, which makes this a
cheap check that the cookies work."
  (list "--flat-playlist" "-I" "1:3" "-J" "--" ":ytsubs"))

;;;; Error classification

(defconst yt-ytdlp-error-patterns
  '((bot-check . "not a bot")
    (age . "confirm your age\\|age-restricted\\|inappropriate for some users")
    (members . "members-only\\|join this channel")
    (rate-limit . "rate-limited\\|HTTP Error 429\\|try again later")
    (expired . "login details are needed\\|no longer valid")
    (bad-profile . "could not find [a-z]+ cookies database")
    (corrupt-cookies . "failed to load cookies\\|does not look like a Netscape format\\|must be Netscape formatted")
    (network . "urlopen error\\|name resolution\\|timed out\\|network is unreachable\\|connection refused")
    (extractor . "unable to extract\\|unable to recognize tab page\\|signature solving failed\\|n challenge solving failed")
    (format . "requested format is not available"))
  "Ordered alist of (CLASS . REGEXP) for yt-dlp's standard error.
The first CLASS whose REGEXP matches wins, so more specific problems
come first.  For example, the bot check message also says \"Use
--cookies-from-browser or --cookies\", which is why that hint is not
a pattern for `expired'.  The bot check pattern avoids the
apostrophe in \"you're\" because YouTube sends a curly one.")

(defconst yt-ytdlp--feed-patterns
  '((expired . "redirected to youtube\\.com home page"))
  "Extra patterns that apply only to the subscription feed.
For a channel URL the same message means the channel does not exist.")

(defun yt-ytdlp-classify (stderr &optional source)
  "Return the class of the first known problem in STDERR, or nil.
Only the ERROR: and WARNING: lines of STDERR are considered.  SOURCE
`feed' or `verify' adds patterns that only mean an expired session
for the subscription feed."
  (let* ((case-fold-search t)
         (text (string-join
                (seq-filter (lambda (line)
                              (string-match-p "\\`\\(?:ERROR\\|WARNING\\):" line))
                            (split-string (or stderr "") "\n"))
                "\n"))
         (patterns (append yt-ytdlp-error-patterns
                           (and (memq source '(feed verify))
                                yt-ytdlp--feed-patterns))))
    (car (seq-find (lambda (pattern) (string-match-p (cdr pattern) text))
                   patterns))))

(defun yt-ytdlp--last-error-line (stderr)
  "Return the most useful line of STDERR for an unknown problem."
  (let ((lines (seq-remove #'string-blank-p
                           (split-string (or stderr "") "\n"))))
    (or (car (last (seq-filter (lambda (line)
                                 (string-prefix-p "ERROR:" line))
                               lines)))
        (car (last lines))
        "yt-dlp failed without an error message")))

(defun yt-ytdlp-update-hint ()
  "Return the hint for updating yt-dlp, see `yt-ytdlp-update-hint'."
  (format yt-ytdlp-update-hint
          (or (executable-find yt-ytdlp-program) yt-ytdlp-program)))

(defun yt-ytdlp-error-message (class &optional stderr)
  "Return the message to show for the problem CLASS.
STDERR is used for classes yt does not know."
  (pcase class
    ('bot-check "YouTube asks you to confirm you are not a bot: open YouTube in the yt Chromium profile, then try again")
    ('age "This video is age-restricted")
    ('members "This video is for channel members only")
    ('rate-limit "YouTube is limiting requests: try again later")
    ('expired "Your YouTube session has expired: sign in to YouTube in the yt Chromium profile, then run M-x yt-login")
    ('no-cookies "Not signed in to YouTube: run M-x yt-login")
    ('bad-profile "Chromium profile not found: run C-u M-x yt-login to choose another one")
    ('corrupt-cookies "The yt cookie file is damaged: run M-x yt-login")
    ('network "Cannot reach YouTube: check the network connection")
    ('extractor (concat "yt-dlp could not read YouTube's response; "
                        (yt-ytdlp-update-hint)))
    ('format "The requested video format is not available")
    ('timeout "yt-dlp took too long and was stopped")
    ('cancelled "Cancelled")
    (_ (yt-ytdlp--last-error-line stderr))))

;;;; Version check

(defun yt-ytdlp-parse-version (string)
  "Return the release date in the yt-dlp version STRING as epoch seconds.
STRING looks like \"2026.10.21\", possibly with a further \".N\".
Return nil if it cannot be parsed."
  (when (and (stringp string)
             (string-match "\\`[[:space:]]*\\([0-9]\\{4\\}\\)\\.\\([0-9]\\{1,2\\}\\)\\.\\([0-9]\\{1,2\\}\\)"
                           string))
    (time-convert (encode-time
                   (list 0 0 0
                         (string-to-number (match-string 3 string))
                         (string-to-number (match-string 2 string))
                         (string-to-number (match-string 1 string))
                         nil nil 0))
                  'integer)))

(defun yt-ytdlp-version-problem (version &optional now)
  "Return a warning about the yt-dlp VERSION string, or nil if it is fine.
VERSION is too old if it predates `yt-ytdlp-min-version' or was
released more than 60 days before NOW, which defaults to the current
time."
  (let ((released (yt-ytdlp-parse-version version))
        (minimum (yt-ytdlp-parse-version yt-ytdlp-min-version)))
    (cond
     ((not released)
      (format "Cannot read the yt-dlp version %S" version))
     ((and minimum (< released minimum))
      (format "yt-dlp %s is older than %s, the oldest version yt supports; %s"
              (string-trim version) yt-ytdlp-min-version
              (yt-ytdlp-update-hint)))
     ((> (- (or now (yt--now)) released) (* 60 86400))
      (format "yt-dlp %s is more than 60 days old, and YouTube changes often; %s"
              (string-trim version) (yt-ytdlp-update-hint))))))

(defvar yt-ytdlp--version-checked nil
  "Non-nil once the yt-dlp version was checked in this session.")

(defun yt-ytdlp-check-version ()
  "Warn once per session if the installed yt-dlp is too old.
The check runs asynchronously."
  (unless yt-ytdlp--version-checked
    (setq yt-ytdlp--version-checked t)
    (yt-process-run yt-ytdlp-program '("--version")
                    :parse nil :key '(yt-ytdlp . version) :timeout 30
                    :on-success
                    (lambda (output _info)
                      (when-let* ((problem (yt-ytdlp-version-problem output)))
                        (display-warning 'yt problem))))))

(provide 'yt-ytdlp)
;;; yt-ytdlp.el ends here
