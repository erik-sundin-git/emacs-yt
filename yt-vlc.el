;;; yt-vlc.el --- Play YouTube videos in VLC -*- lexical-binding: t; -*-

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

;; The VLC backend.  VLC is started once per video with the stream URLs
;; that yt-player.el resolved, and is not controlled afterwards: a new
;; video replaces the running VLC, and stopping kills it.  Since yt
;; cannot see how far you watch, a video counts as watched as soon as
;; VLC starts playing it.

;;; Code:

(require 'cl-lib)
(require 'yt)
(require 'yt-video)
(require 'yt-process)
(require 'yt-cache)
(require 'yt-player)

(defvar yt-vlc--process nil
  "The running VLC process, or nil.")

(defun yt-vlc-args (streams &optional start)
  "Return the VLC arguments that play STREAMS, a plist, from START.
STREAMS come from `yt-ytdlp-parse-streams'.  START is in seconds."
  (let ((user-agent (cdr (assoc-string "User-Agent" (plist-get streams :headers) t)))
        (title (plist-get streams :title))
        (audio (plist-get streams :audio)))
    (append yt-vlc-extra-args
            (list "--no-video-title-show" "--play-and-exit")
            (and title (list (concat "--meta-title=" title)))
            (and user-agent (list (concat "--http-user-agent=" user-agent)))
            (and start (> start 0) (list (format "--start-time=%d" start)))
            (and audio (list (concat "--input-slave=" audio)))
            (list (plist-get streams :video)))))

(defun yt-vlc--sentinel (process _event)
  "Report how the VLC PROCESS ended."
  (unless (process-live-p process)
    (when (eq process yt-vlc--process)
      (setq yt-vlc--process nil))
    (let ((buffer (process-buffer process))
          (status (process-exit-status process)))
      (when (and (eq (process-status process) 'exit) (/= status 0))
        (yt-player-log "VLC exited with status %d%s" status
                       (if (buffer-live-p buffer)
                           (concat ":\n" (with-current-buffer buffer (buffer-string)))
                         ""))
        (message "%s" (substitute-command-keys
                       (format "VLC exited with status %d; \\[yt-player-show-log] shows its output"
                               status))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun yt-vlc--kill ()
  "Kill the running VLC, if any."
  (when (process-live-p yt-vlc--process)
    (delete-process yt-vlc--process))
  (setq yt-vlc--process nil))

(cl-defmethod yt-player-backend-check ((_backend (eql 'vlc)))
  "Signal a `user-error' if VLC is not installed."
  (unless (executable-find yt-vlc-program)
    (user-error "VLC not found: install it, set `yt-vlc-program', or use the yt sandbox")))

(cl-defmethod yt-player-backend-play ((_backend (eql 'vlc)) video streams &key start)
  "Play VIDEO with the resolved STREAMS in a new VLC, from START.
A running VLC is closed first.  VIDEO is marked watched."
  (yt-vlc--kill)
  (let* ((process-environment (append (yt-player-display-environment)
                                      process-environment))
         (args (yt-vlc-args streams start))
         (buffer (generate-new-buffer " *yt-vlc*")))
    (yt-process-log "%s %s" yt-vlc-program
                    (mapconcat #'yt-player--redact args " "))
    (setq yt-vlc--process
          (make-process :name "yt-vlc" :buffer buffer
                        :command (cons yt-vlc-program args)
                        :connection-type 'pipe :noquery t
                        :sentinel #'yt-vlc--sentinel))
    (when (yt-video-id video)
      (yt-mark-watched video))
    (message "Playing “%s” in VLC" (yt-player--title video))))

(cl-defmethod yt-player-backend-stop ((_backend (eql 'vlc)))
  "Close VLC."
  (if (process-live-p yt-vlc--process)
      (progn (yt-vlc--kill)
             (message "Closed VLC"))
    (message "VLC is not running")))

(provide 'yt-vlc)
;;; yt-vlc.el ends here
