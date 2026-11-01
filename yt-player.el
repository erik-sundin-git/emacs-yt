;;; yt-player.el --- Play YouTube videos -*- lexical-binding: t; -*-

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

;; The player interface and the commands that play videos.  A backend
;; (VLC in yt-vlc.el, mpv in yt-mpv.el) is a symbol with methods for
;; the `yt-player-backend-*' generic functions below; `yt-player-backend' picks one.
;;
;; Players never talk to YouTube themselves.  yt resolves the stream
;; URLs with yt-dlp (`yt-player-resolve'), using the signed-in cookies,
;; then waits until YouTube releases the streams: yt-dlp reports an
;; "available_at" time a few seconds ahead, and fetching a stream
;; earlier fails with HTTP 403.  Only then does the backend get the
;; URLs.  The URLs are signed for the user's IP address and expire, so
;; they are never cached or logged.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yt)
(require 'yt-video)
(require 'yt-process)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-cache)

(defvar yt-player-available-margin 1.0
  "Seconds to wait after the time YouTube releases the streams.")

(defvar yt-player-log-buffer "*yt-player-log*"
  "Name of the buffer that collects playback problems.")

(defvar yt-player--wait-timer nil
  "Timer that starts the player once the streams are released.")

(defvar yt-player--last-display nil
  "The display environment entries seen last, see `yt-player-display-environment'.")

(defvar yt-player--current-backend nil
  "The backend that played last, used by `yt-player-stop'.")

;;;; Backends

(cl-defgeneric yt-player-backend-check (backend)
  "Signal a `user-error' if BACKEND cannot play videos."
  (user-error "Unknown yt player backend `%s'" backend))

(cl-defgeneric yt-player-backend-play (backend video streams &key start)
  "Play VIDEO, whose resolved STREAMS are a plist, with BACKEND now.
STREAMS come from `yt-ytdlp-parse-streams'.  START is the position
to start at, in seconds, or nil.")

(cl-defgeneric yt-player-backend-enqueue (backend _video _streams)
  "Add the video with the resolved streams to the BACKEND's playlist."
  (user-error "The %s player cannot queue videos" backend))

(cl-defgeneric yt-player-backend-stop (backend)
  "Stop the BACKEND's playback.")

(cl-defgeneric yt-player-backend-command (backend command &rest _args)
  "Send COMMAND, a symbol such as `pause', to the BACKEND."
  (user-error "The %s player does not support `%s'" backend command))

(defun yt-player--mpv-available-p ()
  "Return non-nil if mpv and yt's mpv backend are installed."
  (and (locate-library "yt-mpv")
       (executable-find (or (bound-and-true-p yt-mpv-program) "mpv"))))

(defun yt-player-backend ()
  "Return the backend to use, resolving `auto' in `yt-player-backend'."
  (if (eq yt-player-backend 'auto)
      (if (yt-player--mpv-available-p) 'mpv 'vlc)
    yt-player-backend))

(defun yt-player--load (backend)
  "Load the library of BACKEND, if it has one, and check it can play."
  (require (intern (format "yt-%s" backend)) nil t)
  (yt-player-backend-check backend))

(defun yt-player-display-environment ()
  "Return the environment entries that name the graphical display.
They come from the selected frame, so that a player started from an
Emacs daemon opens on the display of the frame in use; otherwise from
the last frame that had a display.  Signal a `user-error' if there
is none."
  (let ((wayland (or (getenv "WAYLAND_DISPLAY" (selected-frame))
                     (getenv "WAYLAND_DISPLAY")))
        (x (or (getenv "DISPLAY" (selected-frame)) (getenv "DISPLAY"))))
    (if (or wayland x)
        (setq yt-player--last-display
              (delq nil (list (and wayland (concat "WAYLAND_DISPLAY=" wayland))
                              (and x (concat "DISPLAY=" x)))))
      (or yt-player--last-display
          (user-error "No graphical display found: open a graphical Emacs frame, then try again")))))

;;;; Problems

(defun yt-player--redact (text)
  "Return TEXT with stream URLs replaced by a placeholder."
  (replace-regexp-in-string
   "[^[:space:]\"'`=]*googlevideo\\.com[^[:space:]\"'`]*" "<stream URL>" text t t))

(defun yt-player-log (format-string &rest args)
  "Add a line made from FORMAT-STRING and ARGS to the player log.
Stream URLs are left out."
  (with-current-buffer (get-buffer-create yt-player-log-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "[%F %T] ")
              (yt-player--redact (apply #'format format-string args)))
      (unless (bolp) (insert "\n")))))

;;;###autoload
(defun yt-player-show-log ()
  "Show the log of playback problems."
  (interactive)
  (let ((buffer (get-buffer-create yt-player-log-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    (display-buffer buffer)))

;;;; Resolving streams

(defun yt-player--title (video)
  "Return a short name for VIDEO, for messages."
  (or (yt-video-title video) (yt-video-id video)))

(defun yt-player-resolve (video callback on-error &optional format)
  "Resolve the streams of VIDEO and call CALLBACK with them.
CALLBACK gets the streams plist of `yt-ytdlp-parse-streams' and the
yt-dlp JSON.  ON-ERROR gets the error plist of `yt-auth-run'.  FORMAT
defaults to `yt-player-format'; if it is not available, the streams
are resolved once more with format \"b\".  A new call cancels a
running one, whose ON-ERROR then gets :type `cancelled'."
  (let ((format (or format yt-player-format)))
    (yt-auth-run
     (yt-ytdlp-resolve-args format (yt-video-url video))
     :key '(yt-player . resolve) :force t :parse 'json
     :on-success
     (lambda (info _info)
       (if-let* ((streams (yt-ytdlp-parse-streams info)))
           (funcall callback streams info)
         (funcall on-error (list :type 'parse :class 'parse
                                 :message "yt-dlp found no stream to play"))))
     :on-error
     (lambda (err)
       (if (and (eq (plist-get err :class) 'format) (not (equal format "b")))
           (yt-player-resolve video callback on-error "b")
         (funcall on-error err))))))

(defun yt-player--when-available (streams fn)
  "Call FN from a timer once YouTube releases STREAMS.
That is `yt-player-available-margin' seconds after their
:available-at time, or at once if they have none.  A new call
replaces a waiting one."
  (when (timerp yt-player--wait-timer)
    (cancel-timer yt-player--wait-timer))
  (let* ((at (plist-get streams :available-at))
         (delay (if at (max 0 (- (+ at yt-player-available-margin) (yt--now))) 0)))
    (when (> delay 3)
      (message "Waiting %d s for YouTube to release the stream..." (ceiling delay)))
    (setq yt-player--wait-timer
          (run-at-time delay nil (lambda ()
                                   (setq yt-player--wait-timer nil)
                                   (funcall fn))))))

(defun yt-player--failed (err)
  "Report the failed playback ERR, an error plist from `yt-player-resolve'."
  (unless (eq (plist-get err :type) 'cancelled)
    (yt-player-log "%s" (plist-get err :message))
    (when-let* ((stderr (plist-get err :stderr)))
      (unless (string-blank-p stderr)
        (yt-player-log "yt-dlp: %s" (string-trim stderr))))
    (message "%s" (substitute-command-keys
                   (concat (plist-get err :message)
                           (if (memq (plist-get err :class)
                                     '(nil parse exit extractor format))
                               "; \\[yt-player-show-log] shows details"
                             ""))))))

(defun yt-player--start (backend video method &rest args)
  "Resolve VIDEO and pass it to METHOD of BACKEND with ARGS.
METHOD is `yt-player-backend-play' or `yt-player-backend-enqueue'."
  (yt-player--load backend)
  (yt-player-display-environment)
  (message "Resolving “%s”..." (yt-player--title video))
  (yt-player-resolve
   video
   (lambda (streams _info)
     (unless (yt-video-title video)
       (setf (yt-video-title video) (plist-get streams :title)))
     (yt-player--when-available
      streams
      (lambda ()
        (setq yt-player--current-backend backend)
        (apply method backend video streams args))))
   #'yt-player--failed))

;;;; Commands

(defun yt-player--read-video ()
  "Return the video at point, or ask for a YouTube URL."
  (or (yt-video-at-point)
      (yt-player--read-url)))

(defun yt-player--read-url ()
  "Ask for a YouTube URL and return its `yt-video'."
  (let* ((default (seq-find (lambda (s) (and (stringp s) (yt-video-from-url s)))
                            (list (thing-at-point 'url t)
                                  (ignore-errors (current-kill 0 t)))))
         (url (read-string (format-prompt "YouTube URL" default) nil nil default)))
    (or (yt-video-from-url url)
        (user-error "Not a YouTube video URL: %s" url))))

;;;###autoload
(defun yt-play (video &optional backend)
  "Play VIDEO with BACKEND, which defaults to `yt-player-backend'.
Interactively, play the video at point, or ask for a URL."
  (interactive (list (yt-player--read-video)))
  (yt-player--start (or backend (yt-player-backend)) video #'yt-player-backend-play))

;;;###autoload
(defun yt-play-vlc (video)
  "Play VIDEO in VLC.
Interactively, play the video at point, or ask for a URL."
  (interactive (list (yt-player--read-video)))
  (yt-play video 'vlc))

;;;###autoload
(defun yt-play-url (url)
  "Play the YouTube video at URL."
  (interactive (list (yt-video-url (yt-player--read-url))))
  (yt-play (or (yt-video-from-url url)
               (user-error "Not a YouTube video URL: %s" url))))

;;;###autoload
(defun yt-player-stop ()
  "Stop playback, including a video that is still being resolved."
  (interactive)
  (let ((pending (or (yt-process-cancel '(yt-player . resolve))
                     (and (timerp yt-player--wait-timer)
                          (progn (cancel-timer yt-player--wait-timer) t)))))
    (setq yt-player--wait-timer nil)
    (cond (yt-player--current-backend
           (yt-player-backend-stop yt-player--current-backend))
          ((not pending)
           (message "Nothing is playing")))))

(provide 'yt-player)
;;; yt-player.el ends here
