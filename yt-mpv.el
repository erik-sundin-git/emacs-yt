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
;; is off, because the hook fetches streams before YouTube releases
;; them.
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
(require 'yt-sponsorblock)

(defvar yt-mpv-connect-attempts 50
  "How often to try connecting to a new mpv's socket.")

(defvar yt-mpv-connect-interval 0.1
  "Seconds between attempts to connect to mpv's socket.")

(defvar yt-mpv-reconnect-attempts 3
  "How often to reconnect when mpv's socket closes while mpv runs.")

(defvar yt-mpv-log-size 20
  "Number of mpv warnings kept for `yt-player-show-log'.")

(defconst yt-mpv--observed
  '("pause" "time-pos" "duration" "media-title" "playlist-pos" "playlist-count"
    "chapter" "speed" "idle-active")
  "The mpv properties yt observes.")

(cl-defstruct (yt-mpv--entry (:constructor yt-mpv--entry-create)
                             (:copier nil))
  "A file in mpv's playlist.
VIDEO is the `yt-video' and STREAMS its resolved streams.  DURATION,
POS and MAX-POS are in seconds.  FINALIZED is non-nil once the entry
was marked watched or its position saved; RETRIED once it was
resolved again after a playback error.  CONTINUED is non-nil for an
entry that took the place of one playing the same video, which does
not count as starting it again.  SKIPPED lists the SponsorBlock
segments skipped, which are not skipped again, and LAST-SKIP is the
latest of them."
  video streams duration pos (max-pos 0) finalized retried continued
  skipped last-skip)

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
  "Number of reconnects to the current mpv in a row.
It starts again from 0 once a connection lasted a while.")

(defvar yt-mpv--connected-at nil
  "When the current connection to mpv was made, or nil.")

(defvar yt-mpv--connecting nil
  "Non-nil while yt tries to connect to mpv.")

(defvar yt-mpv--properties nil
  "Plist of the observed mpv properties, such as :time-pos.")

(defvar yt-mpv--entries (make-hash-table)
  "The `yt-mpv--entry' of each playlist entry id.")

(defvar yt-mpv--current nil
  "The playlist entry id of the file playing, or nil.")

(defvar yt-mpv--loaded nil
  "The playlist entry id of the file mpv loaded last, or nil.")

(defvar yt-mpv--log nil
  "The latest warnings from mpv, newest first.")

(defvar yt-mpv--skipping t
  "Non-nil means mpv skips SponsorBlock segments; see `yt-sponsorblock-categories'.")

(defun yt-mpv--reset ()
  "Forget the state of the current mpv, but not its instance number."
  (setq yt-mpv--connection nil
        yt-mpv--partial ""
        yt-mpv--callbacks (make-hash-table)
        yt-mpv--pending nil
        yt-mpv--reconnects 0
        yt-mpv--connected-at nil
        yt-mpv--connecting nil
        yt-mpv--properties nil
        yt-mpv--entries (make-hash-table)
        yt-mpv--current nil
        yt-mpv--loaded nil))

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
  "Start mpv unless it is running and yt is connected to it.
An mpv yt lost the connection to is quit first, so that two never
play at once."
  (when (and (yt-mpv--process-alive-p)
             (not (process-live-p yt-mpv--connection))
             (not yt-mpv--connecting))
    (when yt-mpv--current
      (yt-mpv--finalize yt-mpv--current "quit"))
    (delete-process yt-mpv--process))
  (unless (yt-mpv--process-alive-p)
    (yt-mpv--start)))

;;;; Connection

(defun yt-mpv--connect (socket &optional instance attempts reconnect)
  "Connect to mpv's SOCKET, trying ATTEMPTS times.
INSTANCE defaults to the current instance, and ATTEMPTS to
`yt-mpv-connect-attempts'.  Each further attempt runs from a timer,
so this never blocks.  RECONNECT non-nil means mpv was connected
before."
  (let ((instance (or instance yt-mpv--instance))
        (attempts (or attempts yt-mpv-connect-attempts)))
    (when (yt-mpv--current-p instance)
      (setq yt-mpv--connecting t)
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
            (setq yt-mpv--partial ""
                  yt-mpv--connecting nil
                  yt-mpv--connected-at (yt--now))
            (yt-mpv--on-connect))
        (file-error
         (if (and (> attempts 1)
                  (or (null yt-mpv--process) (yt-mpv--process-alive-p)))
             (run-at-time yt-mpv-connect-interval nil
                          #'yt-mpv--connect socket instance (1- attempts) reconnect)
           (setq yt-mpv--connecting nil)
           (yt-mpv--connect-failed reconnect)))))))

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

(defun yt-mpv--connect-failed (&optional reconnect)
  "Give up connecting: fail the waiting commands.
A new mpv that never answered is stopped.  One that yt lost the
connection to, when RECONNECT is non-nil, is left playing: the next
video yt plays replaces it."
  (yt-mpv--fail-callbacks "could not connect to mpv")
  (setq yt-mpv--pending nil)
  (cond
   (reconnect
    (yt-player-log "Lost the connection to mpv")
    (message "Lost the connection to mpv: q in its window quits it, and the next video starts a new one"))
   (t
    (when (yt-mpv--process-alive-p)
      (delete-process yt-mpv--process))
    (message "Could not connect to mpv; %s shows details"
             (substitute-command-keys "\\[yt-player-show-log]")))))

(defun yt-mpv--connection-sentinel (instance process _event)
  "Handle the closing of the IPC connection PROCESS of mpv INSTANCE."
  (when (and (yt-mpv--current-p instance)
             (eq process yt-mpv--connection)
             (not (process-live-p process)))
    (setq yt-mpv--connection nil)
    (yt-mpv--fail-callbacks "disconnected from mpv")
    ;; Count only disconnects in quick succession.
    (when (and yt-mpv--connected-at (>= (- (yt--now) yt-mpv--connected-at) 30))
      (setq yt-mpv--reconnects 0))
    (setq yt-mpv--connected-at nil)
    (when (yt-mpv--process-alive-p)
      (if (< yt-mpv--reconnects yt-mpv-reconnect-attempts)
          (progn
            (cl-incf yt-mpv--reconnects)
            (setq yt-mpv--connecting t)
            (run-at-time (* 0.2 (expt 2 (1- yt-mpv--reconnects))) nil
                         #'yt-mpv--connect yt-mpv--socket instance 10 t))
        (yt-mpv--connect-failed t)))))

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
  (let* ((entry (and yt-mpv--current (gethash yt-mpv--current yt-mpv--entries)))
         (streams (and entry (yt-mpv--entry-streams entry)))
         (chapter (plist-get yt-mpv--properties :chapter)))
    (list :title (or (and entry (yt-mpv--entry-video entry)
                          (yt-video-title (yt-mpv--entry-video entry)))
                     (plist-get yt-mpv--properties :media-title))
          :time-pos (plist-get yt-mpv--properties :time-pos)
          :duration (plist-get yt-mpv--properties :duration)
          :pause (plist-get yt-mpv--properties :pause)
          :speed (plist-get yt-mpv--properties :speed)
          :idle (plist-get yt-mpv--properties :idle-active)
          ;; -1 before the first chapter.
          :chapter (and (natnump chapter)
                        (plist-get (nth chapter (plist-get streams :chapters)) :title))
          :playlist-pos (plist-get yt-mpv--properties :playlist-pos)
          :playlist-count (plist-get yt-mpv--properties :playlist-count)
          :audio-only (plist-get streams :audio-only)
          :live (plist-get streams :live)
          :skipping-off (not yt-mpv--skipping))))

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
                      (setf (yt-mpv--entry-max-pos entry) value))
                    (yt-mpv--maybe-skip entry value)))
      ("duration" (when (numberp value)
                    (setf (yt-mpv--entry-duration entry) value)))))
  (yt-player-update-mode-line (yt-mpv--state)))

;;;; SponsorBlock

(defun yt-mpv--segment-at (entry pos)
  "Return the segment of ENTRY's video to skip at POS, or nil.
A segment is skipped once, and not in its last half second, where
seeking to its end would gain nothing."
  (when-let* ((video (yt-mpv--entry-video entry)))
    (seq-find (lambda (segment)
                (and (<= (plist-get segment :start) pos)
                     (< pos (- (plist-get segment :end) 0.5))
                     (not (memq segment (yt-mpv--entry-skipped entry)))))
              (yt-sponsorblock-skippable
               (yt-sponsorblock-segments (yt-video-id video))
               (or (yt-mpv--entry-duration entry) (yt-video-duration video))))))

(defun yt-mpv--maybe-skip (entry pos)
  "Skip the SponsorBlock segment of ENTRY that POS is in, if any."
  (when-let* ((yt-mpv--skipping)
              (segment (yt-mpv--segment-at entry pos)))
    (push segment (yt-mpv--entry-skipped entry))
    (setf (yt-mpv--entry-last-skip entry) segment)
    (yt-mpv-send (list "seek" (plist-get segment :end) "absolute") #'yt-mpv--report)
    (message "Skipped %s (%d s); %s goes back"
             (yt-sponsorblock-category-name (plist-get segment :category))
             (round (- (plist-get segment :end) (plist-get segment :start)))
             (substitute-command-keys "\\[yt-player-unskip]"))))

(defun yt-mpv--unskip ()
  "Seek back to the start of the segment skipped last in the current video."
  (let* ((entry (and yt-mpv--current (gethash yt-mpv--current yt-mpv--entries)))
         (segment (and entry (yt-mpv--entry-last-skip entry))))
    (unless segment
      (user-error "Nothing was skipped in this video"))
    (setf (yt-mpv--entry-last-skip entry) nil)
    (yt-mpv-send (list "seek" (plist-get segment :start) "absolute") #'yt-mpv--report)
    (message "Back to the %s" (yt-sponsorblock-category-name (plist-get segment :category)))))

(defun yt-mpv--set-chapters (id)
  "Give mpv the chapters of entry ID, which mpv does not get itself.
mpv runs with --ytdl=no, so the chapters come from yt-dlp's JSON."
  (when-let* ((entry (and id (gethash id yt-mpv--entries)))
              (chapters (plist-get (yt-mpv--entry-streams entry) :chapters)))
    (yt-mpv-send (list "set_property" "chapter-list" (vconcat chapters))
                 #'yt-mpv--report)))

(defun yt-mpv--mark-started (entry)
  "Note that the video of ENTRY started.
Mark it watched if videos count when they start; see
`yt-player-started'."
  (when-let* ((video (yt-mpv--entry-video entry))
              ((not (yt-mpv--entry-continued entry))))
    (when (and (eq yt-mark-watched-when 'start) (yt-video-id video))
      (yt-mark-watched video))
    (yt-player-started video)))

(defun yt-mpv--start-file (id)
  "Handle the start of playlist entry ID."
  (setq yt-mpv--current id)
  (run-hooks 'yt-player-playlist-changed-hook)
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
           ;; A live stream has no position to come back to.
           ((and pos (>= pos 30) (not (yt-mpv--entry-live-p entry)))
            (yt-cache-set-position video-id pos))))))))

(defun yt-mpv--entry-live-p (entry)
  "Return non-nil if ENTRY plays a stream that is live."
  (plist-get (yt-mpv--entry-streams entry) :live))

(defun yt-mpv--log-message (message)
  "Keep the mpv log MESSAGE, without stream URLs."
  (push (yt-player-redact (format "%s: %s" (plist-get message :prefix)
                                   (string-trim-right (or (plist-get message :text) ""))))
        yt-mpv--log)
  (when (nthcdr yt-mpv-log-size yt-mpv--log)
    (setcdr (nthcdr (1- yt-mpv-log-size) yt-mpv--log) nil)))

(defun yt-mpv--retry (id entry)
  "Resolve the video of ENTRY, playlist entry ID, again and play it.
It plays from where it failed, in its place in the playlist.  Stream
URLs expire after some hours, which breaks queued entries."
  (let ((video (yt-mpv--entry-video entry))
        (pos (and (not (yt-mpv--entry-live-p entry)) (yt-mpv--entry-pos entry)))
        (instance yt-mpv--instance))
    (message "Playing “%s” failed; resolving it again..." (yt-player-title video))
    ;; Its kept streams may be the ones that failed.
    (yt-player-forget-streams video)
    (yt-player-resolve
     video
     (lambda (streams _info)
       (yt-player-when-available
        streams
        (lambda ()
          (when (yt-mpv--current-p instance)
            (yt-mpv--reload-in-place id video streams (and pos (floor pos)) t)))))
     #'yt-player-report-failure
     :audio-only (plist-get (yt-mpv--entry-streams entry) :audio-only)
     :key '(yt-mpv . retry))))

(defun yt-mpv--end-file (id reason file-error)
  "Handle the end of playlist entry ID for REASON, with FILE-ERROR."
  (let ((entry (gethash id yt-mpv--entries)))
    (when (eql id yt-mpv--current)
      (setq yt-mpv--current nil))
    (run-hooks 'yt-player-playlist-changed-hook)
    (cond
     ((equal reason "redirect"))
     ((equal reason "error")
      (yt-player-log "mpv could not play %s: %s"
                     (if-let* ((video (and entry (yt-mpv--entry-video entry))))
                         (format "“%s”" (yt-player-title video))
                       (format "entry %s" id))
                     (or file-error "unknown error"))
      (dolist (line (reverse yt-mpv--log))
        (yt-player-log "  %s" line))
      (if (and entry (yt-mpv--entry-video entry) (not (yt-mpv--entry-retried entry)))
          (progn (setf (yt-mpv--entry-retried entry) t)
                 (yt-mpv--finalize id reason)
                 (yt-mpv--retry id entry))
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
    ;; file-loaded names no entry: it is the one that started last.
    ("file-loaded" (setq yt-mpv--loaded yt-mpv--current)
                   (yt-mpv--set-chapters yt-mpv--current))
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
      (when (or (eq (process-status process) 'signal)
                (/= (process-exit-status process) 0))
        (yt-player-log "mpv %s %d%s"
                       (if (eq (process-status process) 'signal)
                           "was killed by signal"
                         "exited with status")
                       (process-exit-status process)
                       (if (buffer-live-p buffer)
                           (concat ":\n" (with-current-buffer buffer (buffer-string)))
                         "")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (yt-mpv--reset)
    (yt-player-backend-exited 'mpv)
    (setq yt-mpv--process nil
          yt-mpv--socket nil)
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

(defun yt-mpv-loadfile-command (streams flags &optional start title index)
  "Return the loadfile command that plays STREAMS with FLAGS.
FLAGS is \"replace\", \"append-play\" or \"insert-at\", which puts
the file at INDEX of the playlist.  START is in seconds.  TITLE,
defaulting to the streams' title, is shown by mpv.  mpv needs every
option value as a string."
  (list :name "loadfile" :url (plist-get streams :video) :flags flags :index index
        :options (list :audio-file (plist-get streams :audio)
                       :vid (and (plist-get streams :audio-only) "no")
                       :force-media-title (or title (plist-get streams :title))
                       :user-agent (cdr (assoc-string "User-Agent"
                                                      (plist-get streams :headers) t))
                       :start (and start (> start 0) (format "%d" start)))))

(defun yt-mpv--load (video streams flags &optional start retried index continued)
  "Load VIDEO with its STREAMS into mpv with FLAGS, from START.
RETRIED non-nil means this is a second try after an error.  INDEX is
the playlist index for the flags \"insert-at\".  CONTINUED is as in
`yt-mpv--entry'."
  (yt-mpv--ensure)
  (unless yt-player-mode
    (yt-player-mode 1))
  (when (yt-video-id video)
    (yt-cache-put-videos (list video)))
  (let ((instance yt-mpv--instance)
        (title (yt-player-title video)))
    (yt-mpv-send
     (yt-mpv-loadfile-command streams flags start title index)
     (lambda (data error)
       (when (yt-mpv--current-p instance)
         (if error
             (message "mpv could not load “%s”: %s" title error)
           (when-let* ((id (plist-get data :playlist_entry_id)))
             (let ((entry (yt-mpv--entry id)))
               (setf (yt-mpv--entry-video entry) video
                     (yt-mpv--entry-streams entry) streams
                     (yt-mpv--entry-retried entry) retried
                     (yt-mpv--entry-continued entry) continued)
               ;; The file may have started, or even loaded, before
               ;; this reply arrived.
               (when (eql id yt-mpv--current)
                 (yt-mpv--mark-started entry))
               (when (eql id yt-mpv--loaded)
                 (yt-mpv--set-chapters id))))))))
    (message (if (equal flags "append-play") "Queued “%s” in mpv" "Playing “%s” in mpv")
             title)))

(defun yt-mpv--reload-in-place (id video streams &optional start retried)
  "Put VIDEO with STREAMS in place of playlist entry ID and play it.
Start at START seconds.  The rest of the playlist stays as it is:
`replace' would empty it.  The new entry plays before the old one is
removed, so that mpv does not move on to the next one meanwhile.
RETRIED is as for `yt-mpv--load'."
  (let ((instance yt-mpv--instance))
    (yt-mpv-send
     '("get_property" "playlist")
     (lambda (data error)
       (when (yt-mpv--current-p instance)
         (let ((index (and (not error)
                           (cl-position id data :key (lambda (item) (plist-get item :id))))))
           (if (not index)
               ;; The entry is gone: play the video next instead.
               (yt-mpv--load video streams "insert-next-play" start retried nil t)
             (yt-mpv--load video streams "insert-at" start retried index t)
             (yt-mpv-send (list "playlist-play-index" index) #'yt-mpv--report)
             (yt-mpv-send (list "playlist-remove" (1+ index))))))))))

(defun yt-mpv--toggle-audio ()
  "Play the current video as audio only, or with its picture again.
It goes on from where it is, in its place in the playlist."
  (let* ((id yt-mpv--current)
         (entry (and id (gethash id yt-mpv--entries)))
         (video (and entry (yt-mpv--entry-video entry))))
    (unless video
      (user-error "Nothing is playing"))
    (let ((audio-only (not (plist-get (yt-mpv--entry-streams entry) :audio-only)))
          (pos (and (not (yt-mpv--entry-live-p entry)) (yt-mpv--entry-pos entry)))
          (instance yt-mpv--instance))
      (message "%s “%s”..." (if audio-only "Audio only:" "With the picture:")
               (yt-player-title video))
      (yt-player-resolve
       video
       (lambda (streams _info)
         ;; Unless another video started meanwhile.
         (when (and (yt-mpv--current-p instance) (eql id yt-mpv--current))
           (yt-mpv--reload-in-place id video streams (and pos (floor pos))
                                    (yt-mpv--entry-retried entry))))
       #'yt-player-report-failure
       :audio-only audio-only :key '(yt-mpv . toggle-audio) :cache t))))

(cl-defmethod yt-player-backend-check ((_backend (eql 'mpv)))
  "Signal a `user-error' if mpv is not installed."
  (unless (executable-find yt-mpv-program)
    (user-error "The mpv program was not found: enable the yt flake's home-manager module (or `nix profile install ~/dev/emacs-yt#runtime'), or use `v' for VLC")))

(cl-defmethod yt-player-backend-prepare ((_backend (eql 'mpv)) video)
  "Fetch the SponsorBlock segments of VIDEO, to skip them."
  (yt-sponsorblock-fetch (yt-video-id video)))

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
    ('shuffle (yt-mpv-send '("playlist-shuffle") #'yt-mpv--report))
    ('play-index (yt-mpv-send (list "playlist-play-index" (car args)) #'yt-mpv--report))
    ('remove (yt-mpv-send (list "playlist-remove" (car args)) #'yt-mpv--report))
    ('chapter (yt-mpv-send (list "add" "chapter" (car args)) #'yt-mpv--report))
    ('unskip (yt-mpv--unskip))
    ('toggle-audio (yt-mpv--toggle-audio))
    ('toggle-skipping
     (setq yt-mpv--skipping (not yt-mpv--skipping))
     (yt-player-update-mode-line (yt-mpv--state))
     (message "Skipping SponsorBlock segments: %s" (if yt-mpv--skipping "on" "off")))
    (_ (cl-call-next-method))))

(cl-defmethod yt-player-backend-now-playing ((_backend (eql 'mpv)))
  "Return (VIDEO . POSITION) of what mpv plays, or nil."
  (when-let* ((entry (and yt-mpv--current (gethash yt-mpv--current yt-mpv--entries)))
              (video (yt-mpv--entry-video entry)))
    (cons video (yt-mpv--entry-pos entry))))

(cl-defmethod yt-player-backend-playlist ((_backend (eql 'mpv)) callback)
  "Call CALLBACK with mpv's playlist."
  (unless (yt-mpv--process-alive-p)
    (user-error "The mpv player is not running"))
  (yt-mpv-send
   '("get_property" "playlist")
   (lambda (data error)
     (if error
         (message "mpv: %s" error)
       (funcall callback
                (cl-loop for item in data
                         for index from 0
                         collect
                         (let* ((entry (gethash (plist-get item :id) yt-mpv--entries))
                                (video (and entry (yt-mpv--entry-video entry))))
                           (list :index index :id (plist-get item :id)
                                 :current (and (plist-get item :current) t)
                                 :title (or (and video (yt-player-title video))
                                            (plist-get item :title) "…")
                                 :video video))))))))

(provide 'yt-mpv)
;;; yt-mpv.el ends here
