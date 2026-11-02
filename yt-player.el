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
(require 'tabulated-list)
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

(cl-defgeneric yt-player-backend-prepare (_backend _video)
  "Prepare to play VIDEO with BACKEND, while its streams are resolved."
  nil)

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

(cl-defgeneric yt-player-backend-playlist (backend _callback)
  "Call CALLBACK with the playlist of BACKEND.
The playlist is a list of plists with :index (from 0), :id, :title,
:current and :video, the `yt-video' or nil."
  (user-error "The %s player has no playlist" backend))

(defvar yt-player-playlist-changed-hook nil
  "Hook run by backends when their playlist may have changed.")

(defvar yt-player-file-started-functions nil
  "Abnormal hook run with the `yt-video' a backend started to play.")

(defcustom yt-player-youtube-history nil
  "Non-nil means the videos you play in yt are added to your YouTube history.
When a video starts, yt-dlp tells YouTube you watched it, as its
--mark-watched option does.  YouTube then counts the video as
watched to the end, shows it in your history on every device, and
uses it for recommendations.  yt's own history, \[yt-history],
does not depend on this."
  :type 'boolean
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defvar yt-player--youtube-history-sent (make-hash-table :test #'equal)
  "Ids of the videos added to the YouTube history in this session.")

(defvar yt-player-resolve-failed-functions nil
  "Abnormal hook run with a `yt-video' whose streams could not be resolved.")

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

(cl-defun yt-player-resolve (video callback on-error &key format (key '(yt-player . resolve)))
  "Resolve the streams of VIDEO and call CALLBACK with them.
CALLBACK gets the streams plist of `yt-ytdlp-parse-streams' and the
yt-dlp JSON.  ON-ERROR gets the error plist of `yt-auth-run'.  FORMAT
defaults to `yt-player-format'; if it is not available, the streams
are resolved once more with format \"b\".  A new call with the same
KEY cancels a running one, whose ON-ERROR then gets :type `cancelled'."
  (let ((format (or format yt-player-format)))
    (yt-auth-run
     (yt-ytdlp-resolve-args format (yt-video-url video))
     :key key :force t :parse 'json
     :on-success
     (lambda (info _info)
       (if-let* ((streams (yt-ytdlp-parse-streams info)))
           (funcall callback streams info)
         (funcall on-error (list :type 'parse :class 'parse
                                 :message "yt-dlp found no stream to play"))))
     :on-error
     (lambda (err)
       (if (and (eq (plist-get err :class) 'format) (not (equal format "b")))
           (yt-player-resolve video callback on-error :format "b" :key key)
         (funcall on-error err))))))

(defun yt-player--when-available (streams fn &optional independent)
  "Call FN from a timer once YouTube releases STREAMS.
That is `yt-player-available-margin' seconds after their
:available-at time, or at once if they have none.  A new call
replaces a waiting one, unless either is INDEPENDENT."
  (let* ((at (plist-get streams :available-at))
         (delay (if at (max 0 (- (+ at yt-player-available-margin) (yt--now))) 0)))
    (when (> delay 3)
      (message "Waiting %d s for YouTube to release the stream..." (ceiling delay)))
    (if independent
        (run-at-time delay nil fn)
      (when (timerp yt-player--wait-timer)
        (cancel-timer yt-player--wait-timer))
      (setq yt-player--wait-timer
            (run-at-time delay nil (lambda ()
                                     (setq yt-player--wait-timer nil)
                                     (funcall fn)))))))

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

(defun yt-player--add-to-youtube-history (video)
  "Add VIDEO to the YouTube history, once per session.
Problems go to the player log, \[yt-player-show-log]."
  (let ((id (yt-video-id video)))
    (when (and yt-player-youtube-history id
               (not (gethash id yt-player--youtube-history-sent)))
      (puthash id t yt-player--youtube-history-sent)
      (let ((fail (lambda (why)
                    (remhash id yt-player--youtube-history-sent)
                    (yt-player-log "Could not add “%s” to the YouTube history: %s"
                                   (yt-player--title video) why))))
        (yt-auth-run
         (yt-ytdlp-mark-watched-args (yt-video-url video))
         :parse nil :key (cons 'yt-youtube-history id)
         :on-success
         (lambda (_output info)
           (when (string-match-p "Unable to mark" (or (plist-get info :stderr) ""))
             (funcall fail "YouTube did not accept it")))
         :on-error
         (lambda (err)
           (unless (eq (plist-get err :type) 'cancelled)
             (funcall fail (plist-get err :message)))))))))

(defun yt-player-started (video)
  "Note that a backend started to play VIDEO.
Add it to yt's history and, if `yt-player-youtube-history' is
non-nil, to the YouTube history, then run
`yt-player-file-started-functions'."
  (when (yt-video-id video)
    (yt-cache-add-history video))
  (yt-player--add-to-youtube-history video)
  (run-hook-with-args 'yt-player-file-started-functions video))

(defun yt-player--fill-video (video streams)
  "Fill in the title and duration of VIDEO from its resolved STREAMS."
  (unless (yt-video-title video)
    (setf (yt-video-title video) (plist-get streams :title)))
  (unless (yt-video-duration video)
    (setf (yt-video-duration video) (plist-get streams :duration))))

(defun yt-player--start (backend video &optional start)
  "Resolve VIDEO and play it with BACKEND from START seconds."
  (yt-player--load backend)
  (yt-player-display-environment)
  (message "Resolving “%s”..." (yt-player--title video))
  (yt-player-backend-prepare backend video)
  (yt-player-resolve
   video
   (lambda (streams _info)
     (yt-player--fill-video video streams)
     (yt-player--when-available
      streams
      (lambda ()
        (setq yt-player--current-backend backend)
        (yt-player-backend-play backend video streams :start start))))
   (lambda (err)
     (yt-player--failed err)
     (unless (eq (plist-get err :type) 'cancelled)
       (run-hook-with-args 'yt-player-resolve-failed-functions video)))))

;;;; Queueing

(defvar yt-player--queue nil
  "Videos waiting to be resolved and enqueued, as (BACKEND . VIDEO).")

(defvar yt-player--queue-busy nil
  "Non-nil while a video of `yt-player--queue' is being resolved.")

(defun yt-player--queue-next ()
  "Resolve the next video of `yt-player--queue' and enqueue it.
Videos are resolved one at a time, so they reach the player's
playlist in the order they were queued."
  (setq yt-player--queue-busy nil)
  (when-let* ((next (pop yt-player--queue)))
    (setq yt-player--queue-busy t)
    (let ((backend (car next))
          (video (cdr next)))
      (yt-player-backend-prepare backend video)
      (yt-player-resolve
       video
       (lambda (streams _info)
         (yt-player--fill-video video streams)
         (yt-player--when-available
          streams
          (lambda ()
            (unwind-protect
                (progn (setq yt-player--current-backend backend)
                       (yt-player-backend-enqueue backend video streams))
              (yt-player--queue-next)))
          t))
       (lambda (err)
         (yt-player--failed err)
         (run-hook-with-args 'yt-player-resolve-failed-functions video)
         (yt-player--queue-next))
       :key '(yt-player . enqueue)))))

(defun yt-player--enqueue (backend videos)
  "Resolve VIDEOS in order and add them to the playlist of BACKEND."
  (yt-player--load backend)
  (yt-player-display-environment)
  (setq yt-player--queue
        (append yt-player--queue (mapcar (lambda (video) (cons backend video)) videos)))
  (message "Queueing %d video%s..." (length videos) (if (cdr videos) "s" ""))
  (unless yt-player--queue-busy
    (yt-player--queue-next)))

;;;; Resuming

(defun yt-player--resume-position (video)
  "Return the position to resume VIDEO at, or nil to play from the start.
A position is used only if `yt-player-resume' is non-nil and it is
at least 30 s in and short of `yt-player-watched-threshold'."
  (let* ((cached (and yt-player-resume (yt-video-id video)
                      (yt-cache-get (yt-video-id video))))
         (position (and cached (yt-video-position cached)))
         (duration (or (yt-video-duration video) (and cached (yt-video-duration cached)))))
    (and position (>= position 30)
         (or (not duration) (< position (* yt-player-watched-threshold duration)))
         position)))

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
(defun yt-play (video &optional backend from-start)
  "Play VIDEO with BACKEND, which defaults to `yt-player-backend'.
Resume where you stopped watching, unless FROM-START is non-nil.
Interactively, play the video at point, or ask for a URL; a prefix
argument plays from the start."
  (interactive (list (yt-player--read-video) nil current-prefix-arg))
  (yt-player--shuffle-stop)
  (let ((start (and (not from-start) (yt-player--resume-position video))))
    (when start
      (message "Resuming at %s; %s plays from the start"
               (yt-video-format-duration start)
               (substitute-command-keys "\\[universal-argument] \\[yt-play]")))
    (yt-player--start (or backend (yt-player-backend)) video start)))

;;;###autoload
(defun yt-play-at (video start &optional backend)
  "Play VIDEO with BACKEND from START seconds."
  (yt-player--shuffle-stop)
  (yt-player--start (or backend (yt-player-backend)) video start))

;;;###autoload
(defun yt-play-vlc (video &optional from-start)
  "Play VIDEO in VLC, from the start if FROM-START is non-nil.
Interactively, play the video at point, or ask for a URL."
  (interactive (list (yt-player--read-video) current-prefix-arg))
  (yt-play video 'vlc from-start))

;;;###autoload
(defun yt-play-mpv (video &optional from-start)
  "Play VIDEO in mpv, from the start if FROM-START is non-nil.
Interactively, play the video at point, or ask for a URL."
  (interactive (list (yt-player--read-video) current-prefix-arg))
  (yt-play video 'mpv from-start))

(defun yt-player--selected-videos ()
  "Return the videos in the region or the video at point, or ask for a URL."
  (or (and (use-region-p) (yt-selected-videos))
      (list (yt-player--read-video))))

;;;###autoload
(defun yt-enqueue (videos)
  "Add VIDEOS to the player's playlist.
Interactively, add the video at point or the videos in the region,
or ask for a URL.  Only players with a playlist, such as mpv, can
queue videos."
  (interactive (list (yt-player--selected-videos)))
  (when (use-region-p)
    (deactivate-mark))
  (yt-player--enqueue (yt-player-backend) videos))

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
    (yt-player--shuffle-stop)
    (setq yt-player--wait-timer nil
          yt-player--queue nil)
    (yt-process-cancel '(yt-player . enqueue))
    (cond (yt-player--current-backend
           (yt-player-backend-stop yt-player--current-backend))
          ((not pending)
           (message "Nothing is playing")))))

;;;; Shuffling

(defvar yt-player-shuffle-ahead 2
  "Number of videos kept queued in mpv while shuffling.")

(defvar yt-player-shuffle-function #'yt-player--shuffled
  "Function returning a list in the order to shuffle it into.")

(cl-defstruct (yt-player--shuffle (:constructor yt-player--shuffle-create)
                                  (:copier nil))
  "A shuffle in progress.
NAME describes what is shuffled.  REST are the videos not queued
yet, in the order they will be.  PENDING maps the ids of the videos
queued or playing but not started yet to t."
  name rest (pending (make-hash-table :test #'equal)))

(defvar yt-player--shuffle nil
  "The shuffle in progress, or nil.")

(defun yt-player--shuffled (list)
  "Return a copy of LIST in random order."
  (let ((vector (vconcat list)))
    (cl-loop for i from (1- (length vector)) downto 1
             do (cl-rotatef (aref vector i) (aref vector (random (1+ i)))))
    (append vector nil)))

(defun yt-player--shuffle-stop ()
  "End the shuffle in progress, dropping the videos it still had to queue."
  (when-let* ((shuffle yt-player--shuffle))
    (setq yt-player--shuffle nil
          yt-player--queue
          (seq-remove (lambda (item)
                        (gethash (yt-video-id (cdr item))
                                 (yt-player--shuffle-pending shuffle)))
                      yt-player--queue))
    (remove-hook 'yt-player-file-started-functions #'yt-player--shuffle-advance)
    (remove-hook 'yt-player-resolve-failed-functions #'yt-player--shuffle-advance)))

(defun yt-player--shuffle-top-up ()
  "Queue videos of the shuffle until `yt-player-shuffle-ahead' wait.
End the shuffle once every video started."
  (when-let* ((shuffle yt-player--shuffle))
    (let ((pending (yt-player--shuffle-pending shuffle))
          (more nil))
      (while (and (yt-player--shuffle-rest shuffle)
                  (< (hash-table-count pending) yt-player-shuffle-ahead))
        (let ((video (pop (yt-player--shuffle-rest shuffle))))
          (puthash (yt-video-id video) t pending)
          (push video more)))
      (when more
        (yt-player--enqueue 'mpv (nreverse more)))
      (when (and (not (yt-player--shuffle-rest shuffle))
                 (zerop (hash-table-count pending)))
        (yt-player--shuffle-stop)))))

(defun yt-player--shuffle-advance (video)
  "Note that VIDEO of the shuffle started or failed, and queue more."
  (when-let* ((shuffle yt-player--shuffle)
              (id (yt-video-id video)))
    (when (gethash id (yt-player--shuffle-pending shuffle))
      (remhash id (yt-player--shuffle-pending shuffle))
      (yt-player--shuffle-top-up))))

(defun yt-player-shuffle (videos &optional name)
  "Play VIDEOS in random order in mpv; NAME describes them.
One video plays at once and `yt-player-shuffle-ahead' more wait in
mpv's playlist; each time one starts, the next is resolved, so a long
playlist does not send YouTube a request per video at once.  Upcoming
streams are left out.  Playing another video ends the shuffle."
  (yt-player--load 'mpv)
  (let* ((seen (make-hash-table :test #'equal))
         (videos (funcall yt-player-shuffle-function
                          (seq-filter (lambda (video)
                                        (and (yt-video-id video)
                                             (not (eq (yt-video-live-status video) 'is_upcoming))
                                             (not (gethash (yt-video-id video) seen))
                                             (puthash (yt-video-id video) t seen)))
                                      videos))))
    (unless videos
      (user-error "No videos to shuffle"))
    (yt-player--shuffle-stop)
    (let ((shuffle (yt-player--shuffle-create :name name :rest (cdr videos))))
      ;; The first video replaces mpv's playlist, so the next ones are
      ;; queued only once it started.
      (puthash (yt-video-id (car videos)) t (yt-player--shuffle-pending shuffle))
      (setq yt-player--shuffle shuffle)
      (add-hook 'yt-player-file-started-functions #'yt-player--shuffle-advance)
      (add-hook 'yt-player-resolve-failed-functions #'yt-player--shuffle-advance)
      (yt-player--start 'mpv (car videos) (yt-player--resume-position (car videos)))
      (message "Shuffling %d videos%s" (length videos)
               (if name (format " of “%s”" name) "")))))

;;;###autoload
(defun yt-player-shuffle-playlist ()
  "Shuffle the player's playlist."
  (interactive)
  (yt-player--command 'shuffle)
  (message "Shuffled the playlist"))

;;;; Player commands

(defun yt-player--command (command &rest args)
  "Send COMMAND with ARGS to the player that played last."
  (unless yt-player--current-backend
    (user-error "Nothing is playing"))
  (apply #'yt-player-backend-command yt-player--current-backend command args)
  (yt-player--repeat))

(defvar-keymap yt-player-repeat-map
  :doc "Keys that repeat player commands without their prefix."
  "SPC" #'yt-player-pause
  "<left>" #'yt-player-seek-backward
  "<right>" #'yt-player-seek-forward
  "<down>" #'yt-player-seek-backward-more
  "<up>" #'yt-player-seek-forward-more
  "[" #'yt-player-slower
  "]" #'yt-player-faster
  "n" #'yt-player-next
  "p" #'yt-player-previous)

(defun yt-player--repeat ()
  "Let the keys of `yt-player-repeat-map' repeat the last command.
Do nothing when `repeat-mode' is on, which handles this itself."
  (unless (bound-and-true-p repeat-mode)
    (set-transient-map yt-player-repeat-map)))

;;;###autoload
(defun yt-player-pause ()
  "Pause or resume playback."
  (interactive)
  (yt-player--command 'pause))

;;;###autoload
(defun yt-player-seek-forward (&optional seconds)
  "Seek SECONDS forward, 5 by default."
  (interactive "P")
  (yt-player--command 'seek (if seconds (prefix-numeric-value seconds) 5)))

;;;###autoload
(defun yt-player-seek-backward (&optional seconds)
  "Seek SECONDS backward, 5 by default."
  (interactive "P")
  (yt-player--command 'seek (- (if seconds (prefix-numeric-value seconds) 5))))

;;;###autoload
(defun yt-player-seek-forward-more ()
  "Seek a minute forward."
  (interactive)
  (yt-player--command 'seek 60))

;;;###autoload
(defun yt-player-seek-backward-more ()
  "Seek a minute backward."
  (interactive)
  (yt-player--command 'seek -60))

;;;###autoload
(defun yt-player-faster ()
  "Play 10% faster."
  (interactive)
  (yt-player--command 'speed 1.1))

;;;###autoload
(defun yt-player-slower ()
  "Play 10% slower."
  (interactive)
  (yt-player--command 'speed (/ 1 1.1)))

;;;###autoload
(defun yt-player-normal-speed ()
  "Play at normal speed."
  (interactive)
  (yt-player--command 'speed nil))

;;;###autoload
(defun yt-player-next ()
  "Play the next video of the playlist."
  (interactive)
  (yt-player--command 'next))

;;;###autoload
(defun yt-player-previous ()
  "Play the previous video of the playlist."
  (interactive)
  (yt-player--command 'previous))

;;;###autoload
(defun yt-player-unskip ()
  "Go back to the start of the segment mpv skipped last in this video.
It is not skipped again.  See `yt-sponsorblock-categories'."
  (interactive)
  (yt-player--command 'unskip))

;;;###autoload
(defun yt-player-toggle-skipping ()
  "Turn skipping SponsorBlock segments off or on, for this session."
  (interactive)
  (yt-player--command 'toggle-skipping))

;;;###autoload
(defun yt-player-quit ()
  "Close the player, keeping your position in the video."
  (interactive)
  (unless yt-player--current-backend
    (user-error "Nothing is playing"))
  (yt-player-backend-command yt-player--current-backend 'quit))

(dolist (command '(yt-player-pause yt-player-seek-forward yt-player-seek-backward
                   yt-player-seek-forward-more yt-player-seek-backward-more
                   yt-player-faster yt-player-slower yt-player-next yt-player-previous))
  (put command 'repeat-map 'yt-player-repeat-map))

;;;; Mode line

(defvar yt-player--mode-line ""
  "The now-playing text shown by `yt-player-mode'.")
(put 'yt-player--mode-line 'risky-local-variable t)

(defun yt-player--segment-string (state)
  "Return the now-playing text for the player STATE, a plist.
STATE has :title, :time-pos, :duration, :pause, :speed and :idle.
Return \"\" while the player is idle or has no title."
  (let ((title (plist-get state :title))
        (pos (plist-get state :time-pos))
        (duration (plist-get state :duration))
        (speed (plist-get state :speed)))
    (if (or (plist-get state :idle) (not title))
        ""
      (concat (if (plist-get state :pause) "⏸ " "▶ ")
              (truncate-string-to-width title 20 nil nil "…")
              (if pos
                  (concat " " (yt-video-format-duration pos)
                          (if duration (concat "/" (yt-video-format-duration duration)) ""))
                "")
              (if (and speed (> (abs (- speed 1.0)) 0.005))
                  (format " ×%.2f" speed)
                "")
              " "))))

(defun yt-player-update-mode-line (state)
  "Show the player STATE, a plist, in the mode line.
See `yt-player--segment-string' for STATE.  The mode lines are
redrawn only when the text changes."
  (let ((text (yt-player--segment-string state)))
    (unless (equal text yt-player--mode-line)
      (setq yt-player--mode-line text)
      (force-mode-line-update t))))

;;;###autoload
(define-minor-mode yt-player-mode
  "Show the video that is playing in the mode line.
It is turned on when mpv starts playing."
  :global t
  :group 'yt-player
  (setq global-mode-string (delq 'yt-player--mode-line (ensure-list global-mode-string)))
  (when yt-player-mode
    (setq global-mode-string (append global-mode-string '(yt-player--mode-line))))
  (force-mode-line-update t))

;;;; Commands on videos


(defun yt-selected-videos ()
  "Return the videos in the region, or the video at point.
This works in every yt buffer, through `yt-video-at-point'.
Signal a `user-error' if there is none."
  (or (if (use-region-p)
          (let ((end (region-end))
                videos)
            (save-excursion
              (goto-char (region-beginning))
              (while (and (< (point) end) (not (eobp)))
                (when-let* ((video (yt-video-at-point)))
                  (push video videos))
                (forward-line 1)))
            (nreverse videos))
        (ensure-list (yt-video-at-point)))
      (user-error "No video here")))

(defun yt-player--mark (unwatched)
  "Mark the selected videos as watched, or not if UNWATCHED is non-nil.
Without a region, move to the next row."
  (let* ((region (use-region-p))
         (videos (yt-selected-videos))
         (id (yt-video-id (car videos))))
    (yt-mark-watched videos unwatched)
    (if region
        (deactivate-mark)
      (let ((here (yt-video-at-point)))
        (when (and here (equal (yt-video-id here) id))
          (forward-line 1))))))

(defun yt-mark-video-watched ()
  "Mark the video at point, or the videos in the region, as watched."
  (interactive)
  (yt-player--mark nil))

(defun yt-mark-video-unwatched ()
  "Mark the video at point, or the videos in the region, as not watched."
  (interactive)
  (yt-player--mark t))

(defun yt-browse-video ()
  "Open the video at point in a web browser."
  (interactive)
  (browse-url (yt-video-url (car (yt-selected-videos)))))

(defun yt-copy-video-url ()
  "Copy the URL of the video at point to the kill ring."
  (interactive)
  (let ((url (yt-video-url (car (yt-selected-videos)))))
    (kill-new url)
    (message "Copied %s" url)))

(defun yt-copy-video-title-and-url ()
  "Copy \"Title — URL\" of the video at point to the kill ring."
  (interactive)
  (let* ((video (car (yt-selected-videos)))
         (text (format "%s — %s" (or (yt-video-title video) (yt-video-id video))
                       (yt-video-url video))))
    (kill-new text)
    (message "Copied %s" text)))

(declare-function yt-info "yt-info" (video))
(declare-function yt-feed-open-channel "yt-feed" (video))
(declare-function yt-channel-playlists "yt-playlists" (id url name))

(defvar-keymap yt-video-actions-map
  :doc "Keys acting on the video at point, shared by yt buffers."
  "RET" #'yt-play
  "v" #'yt-play-vlc
  "m" #'yt-play-mpv
  "a" #'yt-enqueue
  "i" #'yt-info
  "o" #'yt-feed-open-channel
  "O" #'yt-channel-playlists
  "P" yt-player-map
  "w" #'yt-mark-video-watched
  "u" #'yt-mark-video-unwatched
  "b" #'yt-browse-video
  "y" #'yt-copy-video-url
  "Y" #'yt-copy-video-title-and-url)

;;;; Playlist

(defconst yt-player-playlist-buffer "*yt-playlist*"
  "Name of the playlist buffer.")

(defvar-local yt-playlist--items nil
  "The playlist shown, as from `yt-player-backend-playlist'.")

(defun yt-playlist--entries ()
  "Return the tabulated-list entries of the playlist."
  (mapcar (lambda (item)
            (let ((video (plist-get item :video)))
              (list (plist-get item :id)
                    (vector (if (plist-get item :current) "▶" " ")
                            (number-to-string (1+ (plist-get item :index)))
                            (or (and video (yt-video-channel video)) "")
                            (or (plist-get item :title) "")
                            (yt-video-format-duration (and video (yt-video-duration video)))))))
          yt-playlist--items))

(defun yt-playlist--item ()
  "Return the playlist item at point, or signal a `user-error'."
  (let ((id (tabulated-list-get-id)))
    (or (and id (seq-find (lambda (item) (equal (plist-get item :id) id))
                          yt-playlist--items))
        (user-error "No playlist entry here"))))

(defun yt-playlist--video-at-point ()
  "Return the video of the playlist entry at point, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (plist-get (seq-find (lambda (item) (equal (plist-get item :id) id))
                         yt-playlist--items)
               :video)))

(defun yt-playlist-refresh ()
  "Show the player's playlist again."
  (interactive nil yt-playlist-mode)
  (unless yt-player--current-backend
    (user-error "Nothing is playing"))
  (let ((buffer (current-buffer)))
    (yt-player-backend-playlist
     yt-player--current-backend
     (lambda (items)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq yt-playlist--items items)
           (tabulated-list-print t)))))))

(defun yt-playlist--changed ()
  "Refresh the playlist buffer, if there is one."
  (when-let* ((buffer (get-buffer yt-player-playlist-buffer)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'yt-playlist-mode) yt-player--current-backend)
        (ignore-errors (yt-playlist-refresh))))))

(defun yt-playlist-play ()
  "Play the playlist entry at point."
  (interactive nil yt-playlist-mode)
  (yt-player-backend-command yt-player--current-backend 'play-index
                             (plist-get (yt-playlist--item) :index)))

(defun yt-playlist-remove ()
  "Remove the playlist entry at point."
  (interactive nil yt-playlist-mode)
  (yt-player-backend-command yt-player--current-backend 'remove
                             (plist-get (yt-playlist--item) :index))
  (yt-playlist-refresh))

(defvar-keymap yt-playlist-mode-map
  :doc "Keymap for `yt-playlist-mode'."
  :parent (make-composed-keymap yt-video-actions-map tabulated-list-mode-map)
  "RET" #'yt-playlist-play
  "d" #'yt-playlist-remove
  "g" #'yt-playlist-refresh)

(define-derived-mode yt-playlist-mode tabulated-list-mode "yt-playlist"
  "Major mode for the player's playlist.
\{yt-playlist-mode-map}"
  :group 'yt-player
  :interactive nil
  (setq tabulated-list-format [(" " 1 nil) ("#" 3 nil :right-align t)
                               ("Channel" 20 nil) ("Title" 70 nil)
                               ("Dur" 8 nil :right-align t)]
        tabulated-list-entries #'yt-playlist--entries)
  (setq-local yt-video-at-point-function #'yt-playlist--video-at-point)
  (setq-local revert-buffer-function (lambda (&rest _) (yt-playlist-refresh)))
  (add-hook 'yt-player-playlist-changed-hook #'yt-playlist--changed)
  (tabulated-list-init-header))

;;;###autoload
(defun yt-player-playlist ()
  "Show the player's playlist."
  (interactive)
  (unless yt-player--current-backend
    (user-error "Nothing is playing"))
  (let ((buffer (get-buffer-create yt-player-playlist-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'yt-playlist-mode)
        (yt-playlist-mode))
      (yt-playlist-refresh))
    (pop-to-buffer buffer)
    buffer))

(provide 'yt-player)
;;; yt-player.el ends here
