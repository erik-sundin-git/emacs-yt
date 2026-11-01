;;; yt-mpv.el --- Play YouTube videos in mpv -*- lexical-binding: t; -*-

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

;; The mpv backend.  One idle mpv is started when it is first needed
;; and controlled over its JSON IPC socket, which lives in yt's private
;; runtime directory (mpv runs any command sent to it).  mpv gets only
;; stream URLs that yt resolved (see yt-player.el); its own yt-dlp hook
;; is off, because it fetches streams before YouTube releases them.
;;
;; Each file mpv loads has a playlist entry id, which the reply to
;; "loadfile" reports.  yt follows the entries by id, so that when one
;; ends (or mpv exits) it can mark the video watched, if enough of it
;; was played, or remember the position to resume from.
;;
;; Every spawn of mpv gets a new instance number; timers, filters and
;; sentinels of an older instance do nothing.
;;
;; Prior art: empv and mpv.el, whose IPC handling informed this file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yt)
(require 'yt-video)
(require 'yt-process)
(require 'yt-cache)
(require 'yt-player)

(defvar yt-mpv-connect-attempts 50
  "How often to try connecting to a new mpv's socket.")

(defvar yt-mpv-connect-interval 0.1
  "Seconds between attempts to connect to mpv's socket.")

(defvar yt-mpv-reconnect-attempts 3
  "How often to reconnect when mpv's socket closes while mpv runs.")

(defvar yt-mpv-log-size 20
  "Number of mpv warnings kept for `yt-player-show-log'.")

(defconst yt-mpv--observed
  '("pause" "time-pos" "duration" "media-title" "playlist-pos" "speed" "idle-active")
  "The mpv properties yt observes.")

(cl-defstruct (yt-mpv--entry (:constructor yt-mpv--entry-create)
                             (:copier nil))
  "A file in mpv's playlist.
VIDEO is the `yt-video' and STREAMS its resolved streams.  DURATION,
POS and MAX-POS are in seconds.  FINALIZED is non-nil once the entry
was marked watched or its position saved; RETRIED once it was
resolved again after a playback error."
  video streams duration pos (max-pos 0) finalized retried)

(defvar yt-mpv--instance 0
  "Number of the current mpv instance, incremented at each spawn.")

(defvar yt-mpv--process nil
  "The mpv process, or nil.")

(defvar yt-mpv--socket nil
  "File name of the current mpv's IPC socket.")

(defvar yt-mpv--connection nil
  "The IPC connection to mpv, or nil.")

(defvar yt-mpv--partial ""
  "An incomplete line received from mpv.")

(defvar yt-mpv--request-id 0
  "The last request id sent to mpv.")

(defvar yt-mpv--callbacks (make-hash-table)
  "Callbacks waiting for mpv's reply, by request id.")

(defvar yt-mpv--pending nil
  "Lines to send to mpv once connected, in order.")

(defvar yt-mpv--reconnects 0
  "Number of reconnects to the current mpv.")

(defvar yt-mpv--properties nil
  "Plist of the observed mpv properties, such as :time-pos.")

(defvar yt-mpv--entries (make-hash-table)
  "The `yt-mpv--entry' of each playlist entry id.")

(defvar yt-mpv--current nil
  "The playlist entry id of the file playing, or nil.")

(defvar yt-mpv--log nil
  "The latest warnings from mpv, newest first.")

(defun yt-mpv--reset ()
  "Forget the state of the current mpv, but not its instance number."
  (setq yt-mpv--connection nil
        yt-mpv--partial ""
        yt-mpv--callbacks (make-hash-table)
        yt-mpv--pending nil
        yt-mpv--reconnects 0
        yt-mpv--properties nil
        yt-mpv--entries (make-hash-table)
        yt-mpv--current nil))

(defun yt-mpv--current-p (instance)
  "Return non-nil if INSTANCE is the current mpv instance."
  (eql instance yt-mpv--instance))

;;;; Starting mpv

(defun yt-mpv--socket-name (instance)
  "Return the IPC socket file name of mpv INSTANCE."
  (expand-file-name (format "mpv-%d-%d.sock" (emacs-pid) instance)
                    (yt-ensure-runtime-directory)))

(defun yt-mpv-args (socket)
  "Return the arguments that start an idle mpv listening on SOCKET."
  (append (list "--idle=yes" "--force-window=yes" "--no-terminal" "--ytdl=no"
                (concat "--input-ipc-server=" socket)
                "--wayland-app-id=emacs-yt"
                "--title=${media-title} — emacs-yt")
          yt-mpv-extra-args))

(defun yt-mpv--delete-socket (socket)
  "Delete SOCKET, or a symbolic link in its place, if it exists."
  (when (and socket (or (file-exists-p socket) (file-symlink-p socket)))
    (ignore-errors (delete-file socket))))

(defun yt-mpv--process-alive-p ()
  "Return non-nil if mpv is running."
  (process-live-p yt-mpv--process))

(defun yt-mpv--start ()
  "Start a new idle mpv and connect to it."
  (yt-mpv--reset)
  (let* ((instance (cl-incf yt-mpv--instance))
         (socket (yt-mpv--socket-name instance))
         (args (yt-mpv-args socket))
         (process-environment (append (yt-player-display-environment)
                                      process-environment)))
    (yt-mpv--delete-socket socket)
    (setq yt-mpv--socket socket)
    (yt-process-log "%s %s" yt-mpv-program (string-join args " "))
    (setq yt-mpv--process
          (make-process :name "yt-mpv" :buffer (generate-new-buffer " *yt-mpv*")
                        :command (cons yt-mpv-program args)
                        :connection-type 'pipe :noquery t
                        :sentinel (lambda (process event)
                                    (yt-mpv--process-sentinel instance process event))))
    (add-hook 'kill-emacs-hook #'yt-mpv--shutdown)
    (yt-mpv--connect socket instance)))

(defun yt-mpv--ensure ()
  "Start mpv unless it is running."
  (unless (yt-mpv--process-alive-p)
    (yt-mpv--start)))

;;;; Connection

(defun yt-mpv--connect (socket &optional instance attempts)
  "Connect to mpv's SOCKET, trying ATTEMPTS times.
INSTANCE defaults to the current instance, and ATTEMPTS to
`yt-mpv-connect-attempts'.  Each further attempt runs from a timer,
so this never blocks."
  (let ((instance (or instance yt-mpv--instance))
        (attempts (or attempts yt-mpv-connect-attempts)))
    (when (yt-mpv--current-p instance)
      (condition-case nil
          (progn
            (setq yt-mpv--connection
                  (make-network-process
                   :name "yt-mpv-ipc" :family 'local :service socket
                   :coding 'utf-8 :noquery t
                   :filter (lambda (process string)
                             (yt-mpv--filter instance process string))
                   :sentinel (lambda (process event)
                               (yt-mpv--connection-sentinel instance process event))))
            (setq yt-mpv--partial "")
            (yt-mpv--on-connect))
        (file-error
         (if (and (> attempts 1)
                  (or (null yt-mpv--process) (yt-mpv--process-alive-p)))
             (run-at-time yt-mpv-connect-interval nil
                          #'yt-mpv--connect socket instance (1- attempts))
           (yt-mpv--connect-failed)))))))

(defun yt-mpv--send-line (line)
  "Send LINE to mpv, or keep it until yt is connected."
  (if (process-live-p yt-mpv--connection)
      (process-send-string yt-mpv--connection line)
    (setq yt-mpv--pending (append yt-mpv--pending (list line)))))

(defun yt-mpv--on-connect ()
  "Observe mpv's properties and send the commands kept until now."
  (let ((pending yt-mpv--pending))
    (setq yt-mpv--pending nil)
    (cl-loop for property in yt-mpv--observed
             for id from 1
             do (yt-mpv-send (list "observe_property" id property)))
    (yt-mpv-send '("request_log_messages" "warn"))
    (mapc #'yt-mpv--send-line pending)))

(defun yt-mpv--fail-callbacks (message)
  "Call every waiting callback with the error MESSAGE."
  (let ((callbacks yt-mpv--callbacks))
    (setq yt-mpv--callbacks (make-hash-table))
    (maphash (lambda (_id callback) (funcall callback nil message)) callbacks)))

(defun yt-mpv--connect-failed ()
  "Give up connecting: fail the waiting commands and stop mpv."
  (yt-mpv--fail-callbacks "could not connect to mpv")
  (setq yt-mpv--pending nil)
  (when (yt-mpv--process-alive-p)
    (delete-process yt-mpv--process))
  (message "Could not connect to mpv; %s shows details"
           (substitute-command-keys "\\[yt-player-show-log]")))

(defun yt-mpv--connection-sentinel (instance process _event)
  "Handle the closing of the IPC connection PROCESS of mpv INSTANCE."
  (when (and (yt-mpv--current-p instance)
             (eq process yt-mpv--connection)
             (not (process-live-p process)))
    (setq yt-mpv--connection nil)
    (yt-mpv--fail-callbacks "disconnected from mpv")
    (when (and (yt-mpv--process-alive-p)
               (< yt-mpv--reconnects yt-mpv-reconnect-attempts))
      (cl-incf yt-mpv--reconnects)
      (run-at-time (* 0.2 (expt 2 (1- yt-mpv--reconnects))) nil
                   #'yt-mpv--connect yt-mpv--socket instance 10))))

;;;; Messages

(defun yt-mpv--prune (plist)
  "Return PLIST without its nil values, pruning nested plists too."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (when (and (consp value) (keywordp (car value)))
          (setq value (yt-mpv--prune value)))
        (when value
          (setq result (cons value (cons key result))))))
    (nreverse result)))

(defun yt-mpv--encode (command id)
  "Return the JSON line for COMMAND with request ID.
COMMAND is a list of positional arguments, or a plist of named ones
starting with :name.  Nil values of a plist are left out, since JSON
has no use for them."
  (concat (json-serialize
           (list :command (if (keywordp (car-safe command))
                              (yt-mpv--prune command)
                            (vconcat command))
                 :request_id id))
          "\n"))

(defun yt-mpv-send (command &optional callback)
  "Send COMMAND to mpv; see `yt-mpv--encode'.
CALLBACK, if non-nil, is called with the reply's data and nil, or
with nil and an error message.  Return the request id."
  (let ((id (cl-incf yt-mpv--request-id)))
    (when callback
      (puthash id callback yt-mpv--callbacks))
    (yt-mpv--send-line (yt-mpv--encode command id))
    id))

(defun yt-mpv--filter (instance _process string)
  "Handle STRING received from mpv INSTANCE, one JSON message per line."
  (when (yt-mpv--current-p instance)
    (let ((lines (split-string (concat yt-mpv--partial string) "\n")))
      (setq yt-mpv--partial (car (last lines)))
      (dolist (line (butlast lines))
        (unless (string-blank-p line)
          (condition-case err
              (yt-mpv--dispatch (json-parse-string line :object-type 'plist
                                                   :array-type 'list
                                                   :null-object nil
                                                   :false-object nil))
            (json-error (yt-process-log "mpv sent unparsable JSON"))
            (error (yt-process-log "Error handling an mpv message: %S" err))))))))

(defun yt-mpv--dispatch (message)
  "Handle MESSAGE from mpv: a reply or an event."
  (if-let* ((event (plist-get message :event)))
      (yt-mpv--event event message)
    (when-let* ((id (plist-get message :request_id))
                (callback (gethash id yt-mpv--callbacks)))
      (remhash id yt-mpv--callbacks)
      (let ((error (plist-get message :error)))
        (funcall callback (plist-get message :data)
                 (and error (not (equal error "success")) error))))))

;;;; Events

(defun yt-mpv--state ()
  "Return the player state for `yt-player-update-mode-line'."
  (let ((entry (and yt-mpv--current (gethash yt-mpv--current yt-mpv--entries))))
    (list :title (or (and entry (yt-mpv--entry-video entry)
                          (yt-video-title (yt-mpv--entry-video entry)))
                     (plist-get yt-mpv--properties :media-title))
          :time-pos (plist-get yt-mpv--properties :time-pos)
          :duration (plist-get yt-mpv--properties :duration)
          :pause (plist-get yt-mpv--properties :pause)
          :speed (plist-get yt-mpv--properties :speed)
          :idle (plist-get yt-mpv--properties :idle-active))))

(defun yt-mpv--entry (id)
  "Return the entry of playlist entry ID, creating it if needed."
  (or (gethash id yt-mpv--entries)
      (puthash id (yt-mpv--entry-create) yt-mpv--entries)))

(defun yt-mpv--property (name value)
  "Record that the mpv property NAME, a string, changed to VALUE."
  (setq yt-mpv--properties
        (plist-put yt-mpv--properties (intern (concat ":" name)) value))
  (when-let* ((entry (and yt-mpv--current (gethash yt-mpv--current yt-mpv--entries))))
    (pcase name
      ("time-pos" (when (numberp value)
                    (setf (yt-mpv--entry-pos entry) value)
                    (when (> value (yt-mpv--entry-max-pos entry))
                      (setf (yt-mpv--entry-max-pos entry) value))))
      ("duration" (when (numberp value)
                    (setf (yt-mpv--entry-duration entry) value)))))
  (yt-player-update-mode-line (yt-mpv--state)))

(defun yt-mpv--mark-started (entry)
  "Mark the video of ENTRY watched if videos count when they start."
  (when-let* ((video (yt-mpv--entry-video entry)))
    (when (and (eq yt-mark-watched-when 'start) (yt-video-id video))
      (yt-mark-watched video))))

(defun yt-mpv--start-file (id)
  "Handle the start of playlist entry ID."
  (setq yt-mpv--current id)
  (let ((entry (yt-mpv--entry id)))
    (setf (yt-mpv--entry-max-pos entry) 0
          (yt-mpv--entry-pos entry) nil)
    (yt-mpv--mark-started entry)))

(defun yt-mpv--finalize (id reason)
  "Mark the video of entry ID watched, or save its position.
REASON is how it ended, as mpv's end-file reports it.  The video is
watched if it played to the end, or up to
`yt-player-watched-threshold', but never after an error.  This runs
once per entry."
  (when-let* ((entry (gethash id yt-mpv--entries)))
    (unless (yt-mpv--entry-finalized entry)
      (setf (yt-mpv--entry-finalized entry) t)
      (when-let* ((video (yt-mpv--entry-video entry))
                  (video-id (yt-video-id video)))
        (let* ((duration (or (yt-mpv--entry-duration entry) (yt-video-duration video)))
               (pos (yt-mpv--entry-pos entry))
               (watched (and (not (equal reason "error"))
                             (or (equal reason "eof")
                                 (and duration (> duration 0)
                                      (>= (/ (float (yt-mpv--entry-max-pos entry)) duration)
                                          yt-player-watched-threshold))))))
          (cond
           (watched
            (yt-cache-set-position video-id nil)
            (unless (and (eq yt-mark-watched-when 'start) (yt-video-watched video))
              (yt-mark-watched video)))
           ((and pos (>= pos 30))
            (yt-cache-set-position video-id pos))))))))

(defun yt-mpv--log-message (message)
  "Keep the mpv log MESSAGE, without stream URLs."
  (push (yt-player--redact (format "%s: %s" (plist-get message :prefix)
                                   (string-trim-right (or (plist-get message :text) ""))))
        yt-mpv--log)
  (when (nthcdr yt-mpv-log-size yt-mpv--log)
    (setcdr (nthcdr (1- yt-mpv-log-size) yt-mpv--log) nil)))

(defun yt-mpv--retry (entry)
  "Resolve the video of ENTRY again and play it from where it failed.
Stream URLs expire after some hours, which breaks queued entries."
  (let ((video (yt-mpv--entry-video entry))
        (pos (yt-mpv--entry-pos entry))
        (instance yt-mpv--instance))
    (message "Playing “%s” failed; resolving it again..." (yt-player--title video))
    (yt-player-resolve
     video
     (lambda (streams _info)
       (yt-player--when-available
        streams
        (lambda ()
          (when (yt-mpv--current-p instance)
            (yt-mpv--load video streams "replace" (and pos (floor pos)) t)))))
     #'yt-player--failed
     :key '(yt-mpv . retry))))

(defun yt-mpv--end-file (id reason file-error)
  "Handle the end of playlist entry ID for REASON, with FILE-ERROR."
  (let ((entry (gethash id yt-mpv--entries)))
    (when (eql id yt-mpv--current)
      (setq yt-mpv--current nil))
    (cond
     ((equal reason "redirect"))
     ((equal reason "error")
      (yt-player-log "mpv could not play %s: %s"
                     (if-let* ((video (and entry (yt-mpv--entry-video entry))))
                         (format "“%s”" (yt-player--title video))
                       (format "entry %s" id))
                     (or file-error "unknown error"))
      (dolist (line (reverse yt-mpv--log))
        (yt-player-log "  %s" line))
      (if (and entry (yt-mpv--entry-video entry) (not (yt-mpv--entry-retried entry)))
          (progn (setf (yt-mpv--entry-retried entry) t)
                 (yt-mpv--finalize id reason)
                 (yt-mpv--retry entry))
        (yt-mpv--finalize id reason)
        (message "%s" (substitute-command-keys
                       (format "mpv could not play the video (%s); \\[yt-player-show-log] shows details"
                               (or file-error "unknown error"))))))
     (t (yt-mpv--finalize id reason)))))

(defun yt-mpv--event (event message)
  "Handle the mpv EVENT, a string, described by MESSAGE."
  (pcase event
    ("property-change" (yt-mpv--property (plist-get message :name)
                                         (plist-get message :data)))
    ("start-file" (yt-mpv--start-file (plist-get message :playlist_entry_id)))
    ("end-file" (yt-mpv--end-file (plist-get message :playlist_entry_id)
                                  (plist-get message :reason)
                                  (plist-get message :file_error)))
    ("log-message" (yt-mpv--log-message message))))

;;;; Process lifetime

(defun yt-mpv--process-sentinel (instance process _event)
  "Clean up after mpv INSTANCE, whose PROCESS exited."
  (when (and (yt-mpv--current-p instance) (not (process-live-p process)))
    (when yt-mpv--current
      (yt-mpv--finalize yt-mpv--current "quit"))
    (yt-mpv--fail-callbacks "mpv exited")
    (when (processp yt-mpv--connection)
      (delete-process yt-mpv--connection))
    (yt-mpv--delete-socket yt-mpv--socket)
    (let ((buffer (process-buffer process)))
      (when (and (eq (process-status process) 'exit)
                 (/= (process-exit-status process) 0))
        (yt-player-log "mpv exited with status %d%s" (process-exit-status process)
                       (if (buffer-live-p buffer)
                           (concat ":\n" (with-current-buffer buffer (buffer-string)))
                         "")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (yt-mpv--reset)
    (setq yt-mpv--process nil
          yt-mpv--socket nil)
    (when (eq yt-player--current-backend 'mpv)
      (setq yt-player--current-backend nil))
    (yt-player-update-mode-line nil)
    (message "mpv exited")))

(defun yt-mpv--shutdown ()
  "Save the position of the playing video and quit mpv, for `kill-emacs-hook'."
  (when (yt-mpv--process-alive-p)
    (when yt-mpv--current
      (yt-mpv--finalize yt-mpv--current "quit"))
    (when (process-live-p yt-mpv--connection)
      (ignore-errors
        (process-send-string yt-mpv--connection "{\"command\":[\"quit\"]}\n")))
    (let ((deadline (+ (float-time) 0.3)))
      (while (and (yt-mpv--process-alive-p) (< (float-time) deadline))
        (accept-process-output yt-mpv--process 0.05)))
    (when (processp yt-mpv--process)
      (delete-process yt-mpv--process))
    (yt-mpv--delete-socket yt-mpv--socket)))

;;;; Backend

(defun yt-mpv-loadfile-command (streams flags &optional start title)
  "Return the loadfile command that plays STREAMS with FLAGS.
FLAGS is \"replace\" or \"append-play\".  START is in seconds.
TITLE, defaulting to the streams' title, is shown by mpv.  mpv
needs every option value as a string."
  (list :name "loadfile" :url (plist-get streams :video) :flags flags
        :options (list :audio-file (plist-get streams :audio)
                       :force-media-title (or title (plist-get streams :title))
                       :user-agent (cdr (assoc-string "User-Agent"
                                                      (plist-get streams :headers) t))
                       :start (and start (> start 0) (format "%d" start)))))

(defun yt-mpv--load (video streams flags &optional start retried)
  "Load VIDEO with its STREAMS into mpv with FLAGS, from START.
RETRIED non-nil means this is a second try after an error."
  (yt-mpv--ensure)
  (unless yt-player-mode
    (yt-player-mode 1))
  (when (yt-video-id video)
    (yt-cache-put-videos (list video)))
  (let ((instance yt-mpv--instance)
        (title (yt-player--title video)))
    (yt-mpv-send
     (yt-mpv-loadfile-command streams flags start title)
     (lambda (data error)
       (when (yt-mpv--current-p instance)
         (if error
             (message "mpv could not load “%s”: %s" title error)
           (when-let* ((id (plist-get data :playlist_entry_id)))
             (let ((entry (yt-mpv--entry id)))
               (setf (yt-mpv--entry-video entry) video
                     (yt-mpv--entry-streams entry) streams
                     (yt-mpv--entry-retried entry) retried)
               ;; The file may have started before this reply arrived.
               (when (eql id yt-mpv--current)
                 (yt-mpv--mark-started entry))))))))
    (message (if (equal flags "replace") "Playing “%s” in mpv" "Queued “%s” in mpv")
             title)))

(cl-defmethod yt-player-backend-check ((_backend (eql 'mpv)))
  "Signal a `user-error' if mpv is not installed."
  (unless (executable-find yt-mpv-program)
    (user-error "The mpv program was not found: enable the yt flake's home-manager module (or `nix profile install ~/dev/emacs-yt#runtime'), or use `v' for VLC")))

(cl-defmethod yt-player-backend-play ((_backend (eql 'mpv)) video streams &key start)
  "Play VIDEO with the resolved STREAMS in mpv now, from START."
  (yt-mpv--load video streams "replace" start))

(cl-defmethod yt-player-backend-enqueue ((_backend (eql 'mpv)) video streams)
  "Add VIDEO with the resolved STREAMS to mpv's playlist."
  (yt-mpv--load video streams "append-play"))

(cl-defmethod yt-player-backend-stop ((_backend (eql 'mpv)))
  "Stop mpv's playback, keeping its playlist."
  (if (yt-mpv--process-alive-p)
      (progn (yt-mpv-send '("stop" "keep-playlist"))
             (message "Stopped mpv"))
    (message "mpv is not running")))

(defun yt-mpv--report (_data error)
  "Show the ERROR of a command, if any."
  (when error
    (message "mpv: %s" error)))

(cl-defmethod yt-player-backend-command ((_backend (eql 'mpv)) command &rest args)
  "Send the player COMMAND with ARGS to mpv."
  (unless (yt-mpv--process-alive-p)
    (user-error "The mpv player is not running"))
  (pcase command
    ('pause (yt-mpv-send '("cycle" "pause") #'yt-mpv--report))
    ('seek (yt-mpv-send (list "seek" (car args) "relative") #'yt-mpv--report))
    ('speed (yt-mpv-send (if (car args)
                             (list "multiply" "speed" (car args))
                           '("set_property" "speed" 1.0))
                         #'yt-mpv--report))
    ;; mpv reports an error at either end of the playlist; ignore it.
    ('next (yt-mpv-send '("playlist-next" "weak")))
    ('previous (yt-mpv-send '("playlist-prev" "weak")))
    ('quit (yt-mpv-send '("quit")))
    (_ (cl-call-next-method))))

(provide 'yt-mpv)
;;; yt-mpv.el ends here
