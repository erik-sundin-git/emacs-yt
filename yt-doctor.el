;;; yt-doctor.el --- Diagnostics for yt -*- lexical-binding: t; -*-

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

;; `yt-doctor' shows what yt depends on and whether it works: the
;; programs, the environment, the directories, the cookie file (modes
;; and counts only, never values) and the sign-in state.
;; `yt-debug-fetch-feed' fetches the subscription feed and lists the
;; parsed entries, which is useful until the feed buffer exists.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'yt)
(require 'yt-video)
(require 'yt-ytdlp)
(require 'yt-auth)

(defun yt-doctor--insert (label value &optional face)
  "Insert a line with LABEL and VALUE, VALUE shown in FACE."
  (insert (format "%-22s " label)
          (propertize (format "%s" value) 'face (or face 'default))
          "\n"))

(defun yt-doctor--program (label program)
  "Insert a line saying where PROGRAM, described by LABEL, was found."
  (let ((path (executable-find program)))
    (yt-doctor--insert label (or path (format "%s: not found" program))
                       (if path 'success 'error))))

(defun yt-doctor--directory (label fn)
  "Insert a line for the directory returned by FN, described by LABEL.
FN is called to create and check the directory."
  (condition-case err
      (yt-doctor--insert label (funcall fn) 'success)
    (user-error (yt-doctor--insert label (error-message-string err) 'error))))

(defun yt-doctor--cookie-stats (file)
  "Return (COUNT . DOMAINS) for the Netscape cookie FILE.
Only the domain field of each cookie is read; values are ignored."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((count 0) domains)
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((fields (split-string line "\t")))
          (when (= (length fields) 7)
            (setq count (1+ count))
            (cl-pushnew (car fields) domains :test #'equal))))
      (cons count (sort domains #'string<)))))

(defun yt-doctor--cookie-file ()
  "Insert lines describing the master cookie file."
  (let ((file (condition-case nil (yt-auth-cookie-file) (user-error nil))))
    (cond
     ((not file))
     ((not (file-exists-p file))
      (yt-doctor--insert "Cookie file" "none (M-x yt-login)" 'warning))
     (t
      (let ((modes (file-modes file))
            (stats (yt-doctor--cookie-stats file)))
        (yt-doctor--insert "Cookie file" file)
        (yt-doctor--insert "  mode" (format "%o" modes)
                           (if (= modes #o600) 'success 'error))
        (yt-doctor--insert "  cookies" (car stats))
        (yt-doctor--insert "  domains" (string-join (cdr stats) " ")
                           (if (seq-every-p (lambda (d) (string-suffix-p "youtube.com" d))
                                            (cdr stats))
                               'success 'error)))))))

;;;###autoload
(defun yt-doctor ()
  "Show what yt depends on and whether it works."
  (interactive)
  (let ((buffer (get-buffer-create "*yt-doctor*"))
        (version (ignore-errors
                   (car (process-lines yt-ytdlp-program "--version")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (yt-doctor--insert "Emacs" emacs-version)
        (yt-doctor--program "yt-dlp" yt-ytdlp-program)
        (when version
          (let ((problem (yt-ytdlp-version-problem version)))
            (yt-doctor--insert "  version" (or problem version)
                               (if problem 'warning 'success))))
        (yt-doctor--program "Cookie exporter" yt-export-cookies-program)
        (yt-doctor--program "mpv" "mpv")
        (yt-doctor--program "VLC" "vlc")
        (let ((wayland (getenv "WAYLAND_DISPLAY" (selected-frame))))
          (yt-doctor--insert "WAYLAND_DISPLAY" (or wayland "not set")
                             (if wayland 'success 'warning)))
        (let ((dbus (getenv "DBUS_SESSION_BUS_ADDRESS")))
          (yt-doctor--insert "D-Bus session" (if dbus "available" "not set")
                             (if dbus 'success 'warning)))
        (yt-doctor--directory "State directory" #'yt-ensure-state-directory)
        (yt-doctor--directory "Runtime directory" #'yt-ensure-runtime-directory)
        (let ((profile (yt-auth-profile)))
          (yt-doctor--insert "Chromium profile"
                             (if profile (yt-auth--profile-label profile)
                               "not chosen (M-x yt-login)")
                             (if profile 'success 'warning)))
        (yt-doctor--cookie-file)
        (yt-doctor--insert "Sign-in state" (yt-auth-state)
                           (if (eq (yt-auth-state) 'ok) 'success 'warning))
        (when-let* ((backoff (yt-auth--backing-off)))
          (yt-doctor--insert "Backing off" (format "%s until %s" (car backoff)
                                                   (format-time-string
                                                    "%H:%M" (cdr backoff)))
                             'warning)))
      (special-mode))
    (pop-to-buffer buffer)))

;;;; Debug feed

(defun yt-doctor--show-feed (buffer videos seconds info)
  "Show VIDEOS fetched in SECONDS in BUFFER; INFO is from `yt-auth-run'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (now (yt--now)))
        (erase-buffer)
        (insert (format "%d entries in %.1f s%s\n\n" (length videos) seconds
                        (if-let* ((class (plist-get info :class)))
                            (format "; warning: %s" class)
                          "")))
        (dolist (video videos)
          (insert (format "%3d  %5s  %8s  %-20s  %s\n"
                          (yt-video-feed-index video)
                          (yt-video-format-age (yt-video-timestamp video) now)
                          (yt-video-format-duration (yt-video-duration video))
                          (truncate-string-to-width
                           (or (yt-video-channel video) "") 20 nil nil "…")
                          (or (yt-video-title video) ""))))
        (goto-char (point-min))))))

;;;###autoload
(defun yt-debug-fetch-feed (&optional limit)
  "Fetch the first LIMIT entries of the subscription feed and list them.
LIMIT defaults to 30; with a prefix argument, ask for it."
  (interactive (list (if current-prefix-arg
                         (read-number "Entries: " yt-feed-limit)
                       30)))
  (let ((buffer (get-buffer-create "*yt-debug-feed*"))
        (start (yt--now))
        (videos nil))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Fetching the subscription feed...\n"))
      (special-mode))
    (display-buffer buffer)
    (yt-auth-run (yt-ytdlp-feed-args (or limit 30))
                 :parse 'ndjson :key '(yt-debug . feed) :source 'feed
                 :ignore-backoff t
                 :on-line (lambda (entry)
                            (when-let* ((video (yt-video-from-json entry t)))
                              (setf (yt-video-feed-index video) (length videos))
                              (push video videos))
                            nil)
                 :on-success (lambda (_value info)
                               (yt-doctor--show-feed buffer (reverse videos)
                                                     (- (yt--now) start) info))
                 :on-error (lambda (err)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (let ((inhibit-read-only t))
                                   (erase-buffer)
                                   (insert (plist-get err :message) "\n"))))
                             (message "%s" (plist-get err :message))))))

(provide 'yt-doctor)
;;; yt-doctor.el ends here
