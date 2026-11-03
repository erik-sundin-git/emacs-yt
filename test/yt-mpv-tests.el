;;; yt-mpv-tests.el --- Tests for yt-mpv.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the mpv backend against a fake mpv: a local socket server
;; in this Emacs that answers IPC requests, and test/bin/fake-mpv (or a
;; "sleep") standing in for the mpv process.  They cover the message
;; framing, the pending queue, replies and errors, reconnecting,
;; following playlist entries, marking watched, resuming, retrying
;; after a playback error, the mode line and cleanup.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-player)
(require 'yt-mpv)

;;;; Fake mpv server

(cl-defstruct (yt-mpv-test--server (:constructor yt-mpv-test--server-create)
                                   (:copier nil))
  "A fake mpv IPC server.
RECEIVED holds the messages received, oldest first.  ERRORS maps
command names to the error to reply with; commands in SILENT get no
reply.  REPLIES maps command names to the data to reply with."
  process client (partial "") received (next-entry 1) errors silent replies)

(defun yt-mpv-test--command-name (message)
  "Return the command name of the IPC MESSAGE."
  (let ((command (plist-get message :command)))
    (if (keywordp (car command)) (plist-get command :name) (car command))))

(defun yt-mpv-test--reply (server message)
  "Answer MESSAGE as mpv would, through SERVER."
  (let* ((name (yt-mpv-test--command-name message))
         (error (or (cdr (assoc name (yt-mpv-test--server-errors server))) "success"))
         (data (and (equal error "success")
                    (if (equal name "loadfile")
                        (list :playlist_entry_id
                              (prog1 (yt-mpv-test--server-next-entry server)
                                (cl-incf (yt-mpv-test--server-next-entry server))))
                      (cdr (assoc name (yt-mpv-test--server-replies server)))))))
    (unless (member name (yt-mpv-test--server-silent server))
      (process-send-string
       (yt-mpv-test--server-client server)
       (concat (json-serialize (append (list :request_id (plist-get message :request_id)
                                             :error error)
                                       (and data (list :data data))))
               "\n")))))

(defun yt-mpv-test--server-input (server string)
  "Handle STRING sent to SERVER."
  (let ((lines (split-string (concat (yt-mpv-test--server-partial server) string) "\n")))
    (setf (yt-mpv-test--server-partial server) (car (last lines)))
    (dolist (line (butlast lines))
      (let ((message (json-parse-string line :object-type 'plist :array-type 'list)))
        (setf (yt-mpv-test--server-received server)
              (append (yt-mpv-test--server-received server) (list message)))
        (yt-mpv-test--reply server message)))))

(defun yt-mpv-test--serve (socket)
  "Start a fake mpv server on SOCKET and return it."
  (let ((server (yt-mpv-test--server-create)))
    (setf (yt-mpv-test--server-process server)
          (make-network-process
           :name "fake-mpv-server" :server t :family 'local :service socket
           :coding 'utf-8 :noquery t
           :log (lambda (_server client _message)
                  (setf (yt-mpv-test--server-client server) client
                        (yt-mpv-test--server-partial server) ""))
           :filter (lambda (_client string) (yt-mpv-test--server-input server string))
           :sentinel #'ignore))
    server))

(defun yt-mpv-test--emit (server &rest event)
  "Send the mpv EVENT, a plist, to the client of SERVER."
  (process-send-string (yt-mpv-test--server-client server)
                       (concat (json-serialize event) "\n")))

(defun yt-mpv-test--names (server)
  "Return the command names SERVER received, in order."
  (mapcar #'yt-mpv-test--command-name (yt-mpv-test--server-received server)))

(defun yt-mpv-test--wait-for (server name &optional count)
  "Wait until SERVER received COUNT (default 1) commands called NAME.
Return the last one."
  (yt-test-wait-until
   (lambda ()
     (let ((matching (seq-filter (lambda (m) (equal (yt-mpv-test--command-name m) name))
                                 (yt-mpv-test--server-received server))))
       (and (>= (length matching) (or count 1)) (car (last matching)))))
   name))

(defun yt-mpv-test--sleeper ()
  "Return a process that stands in for a running mpv."
  (make-process :name "fake-mpv-sleep" :command '("sleep" "1000") :noquery t
                :buffer nil))

(defmacro yt-mpv-test--with-mpv (dirs &rest body)
  "Run BODY in a scenario with cookies, the fake mpv and fresh mpv state.
DIRS is (YTDLP-DIR MPV-DIR), bound to the fake yt-dlp's scenario
directory and the fake mpv's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,(car dirs) _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let* ((,(cadr dirs) (expand-file-name "mpv" ,(car dirs)))
            (yt-player-backend 'mpv)
            (yt-mpv-program (expand-file-name "fake-mpv" yt-test-bin-dir))
            (yt-mpv-extra-args nil)
            (yt-mpv-connect-interval 0.05)
            (yt-player-available-margin 0.0)
            (yt-player-resume t)
            (yt-player-watched-threshold 0.9)
            (yt-mark-watched-when 'near-end)
            (yt-player--last-display nil)
            (yt-player--current-backend nil)
            (yt-player--mode-line "")
            (global-mode-string global-mode-string)
            (yt-mpv--instance 100)
            (yt-mpv--process nil)
            (yt-mpv--socket nil)
            (yt-mpv--connection nil)
            (yt-mpv--partial "")
            (yt-mpv--request-id 0)
            (yt-mpv--callbacks (make-hash-table))
            (yt-mpv--pending nil)
            (yt-mpv--reconnects 0)
            (yt-mpv--properties nil)
            (yt-mpv--entries (make-hash-table))
            (yt-mpv--current nil)
            (yt-mpv--log nil)
            (kill-emacs-hook kill-emacs-hook)
            (process-environment (append (list (concat "FAKE_MPV_DIR=" ,(cadr dirs))
                                               "WAYLAND_DISPLAY=wayland-test")
                                         process-environment)))
       (make-directory ,(cadr dirs) t)
       (unwind-protect
           (save-window-excursion ,@body)
         (dolist (process (process-list))
           (when (string-prefix-p "fake-mpv" (process-name process))
             (delete-process process)))
         (when (processp yt-mpv--connection)
           (delete-process yt-mpv--connection))
         (when (processp yt-mpv--process)
           (delete-process yt-mpv--process))
         (yt-mpv--delete-socket yt-mpv--socket)
         (yt-player-mode -1)))))

(defun yt-mpv-test--connect ()
  "Connect to a fake server as if mpv were running; return the server.
A sleeping process stands in for mpv."
  (let ((socket (yt-mpv--socket-name yt-mpv--instance)))
    (setq yt-mpv--process (yt-mpv-test--sleeper)
          yt-mpv--socket socket)
    (prog1 (yt-mpv-test--serve socket)
      (yt-mpv--connect socket))))

(defun yt-mpv-test--streams (&optional name)
  "Return the parsed streams of the fixture NAME."
  (yt-ytdlp-parse-streams
   (yt-process-parse-json (yt-test-fixture-string (or name "resolve-separate.json")))))

(defun yt-mpv-test--video (id &rest slots)
  "Return a cached video with ID and SLOTS."
  (car (yt-cache-put-videos
        (list (apply #'yt-video--make :id id
                     (append slots (list :title (concat "Title " id)
                                         :url (concat "https://www.youtube.com/watch?v=" id))))))))

(defun yt-mpv-test--entry-ids (video)
  "Return the playlist entry ids of VIDEO, in increasing order."
  (let (ids)
    (maphash (lambda (id entry)
               (when (eq (yt-mpv--entry-video entry) video)
                 (push id ids)))
             yt-mpv--entries)
    (sort ids #'<)))

(defun yt-mpv-test--load (server video &optional flags)
  "Load VIDEO through SERVER and return its new playlist entry id."
  (let ((before (length (yt-mpv-test--entry-ids video))))
    (yt-mpv--load video (yt-mpv-test--streams) (or flags "replace"))
    (ignore server)
    (yt-test-wait-until
     (lambda () (> (length (yt-mpv-test--entry-ids video)) before))
     "loadfile reply")
    (car (last (yt-mpv-test--entry-ids video)))))

(defun yt-mpv-test--play-through (server id &rest properties)
  "Start entry ID through SERVER, then set mpv PROPERTIES, a plist."
  (yt-mpv-test--emit server :event "start-file" :playlist_entry_id id)
  (while properties
    (yt-mpv-test--emit server :event "property-change"
                       :name (substring (symbol-name (pop properties)) 1)
                       :data (pop properties)))
  (yt-test-wait-until (lambda () (eql yt-mpv--current id)) "start-file"))

(defun yt-mpv-test--end (server id reason)
  "End entry ID through SERVER for REASON and wait for it."
  (yt-mpv-test--emit server :event "end-file" :playlist_entry_id id :reason reason)
  (yt-test-wait-until (lambda () (yt-mpv--entry-finalized (gethash id yt-mpv--entries)))
                      "end-file"))

;;;; Pure functions

(ert-deftest yt-mpv-args ()
  "mpv starts idle, without its yt-dlp hook, on the private socket."
  (let ((yt-mpv-extra-args '("--hwdec=auto-safe")))
    (should (equal (yt-mpv-args "/run/x/mpv.sock")
                   '("--idle=yes" "--force-window=yes" "--no-terminal" "--ytdl=no"
                     "--input-ipc-server=/run/x/mpv.sock" "--wayland-app-id=emacs-yt"
                     "--title=${media-title} — emacs-yt" "--hwdec=auto-safe")))))

(ert-deftest yt-mpv-encode-loadfile ()
  "loadfile is a named command whose options are strings, without nils."
  (let* ((streams (yt-mpv-test--streams))
         (line (yt-mpv--encode (yt-mpv-loadfile-command streams "replace" 90 "Tïtle") 7))
         (message (json-parse-string line :object-type 'plist :array-type 'list)))
    (should (string-suffix-p "\n" line))
    (should (= (plist-get message :request_id) 7))
    (let ((command (plist-get message :command)))
      (should (equal (plist-get command :name) "loadfile"))
      (should (equal (plist-get command :flags) "replace"))
      (should (equal (plist-get command :url) (plist-get streams :video)))
      (should (equal (plist-get command :options)
                     (list :audio-file (plist-get streams :audio)
                           :force-media-title "Tïtle"
                           :user-agent "FakeAgent/1.0"
                           :start "90")))))
  (let* ((streams (yt-mpv-test--streams "resolve-combined.json"))
         (command (plist-get (json-parse-string
                              (yt-mpv--encode (yt-mpv-loadfile-command streams "append-play") 1)
                              :object-type 'plist)
                             :command)))
    (should (equal (plist-get command :options)
                   '(:force-media-title "A past live stream" :user-agent "FakeAgent/2.0")))))

(ert-deftest yt-mpv-encode-positional ()
  "Positional commands become JSON arrays."
  (should (equal (yt-mpv--encode '("seek" -5 "relative") 3)
                 "{\"command\":[\"seek\",-5,\"relative\"],\"request_id\":3}\n")))

(ert-deftest yt-mpv-segment-string ()
  "The mode line shows the title, position, duration and speed."
  (should (equal (yt-player--segment-string
                  '(:title "A rather long video title here" :time-pos 754.6
                           :duration 2700 :speed 1.25))
                 "▶ A rather long video… 12:34/45:00 ×1.25 "))
  (should (equal (yt-player--segment-string '(:title "Short" :time-pos 5 :pause t :speed 1.0))
                 "⏸ Short 0:05 "))
  (should (equal (yt-player--segment-string '(:title "Idle" :idle t)) ""))
  (should (equal (yt-player--segment-string nil) "")))

;;;; Connection and messages

(ert-deftest yt-mpv-pending-queue-and-replies ()
  "Commands wait for the connection, and replies reach their callbacks."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let (paused failed)
      (yt-mpv-send '("cycle" "pause") (lambda (data error) (setq paused (list 'ok data error))))
      (should (= (length yt-mpv--pending) 1))
      (let ((server (yt-mpv-test--connect)))
        (setf (yt-mpv-test--server-errors server) '(("seek" . "error running command")))
        (yt-test-wait-until (lambda () paused) "pause reply")
        (should (equal paused '(ok nil nil)))
        ;; Observers first, then the queued command.
        (should (equal (seq-take (yt-mpv-test--names server) 9)
                       '("observe_property" "observe_property" "observe_property"
                         "observe_property" "observe_property" "observe_property"
                         "observe_property" "request_log_messages" "cycle")))
        (should (equal (mapcar (lambda (m) (nth 2 (plist-get m :command)))
                               (seq-take (yt-mpv-test--server-received server) 7))
                       yt-mpv--observed))
        (yt-mpv-send '("seek" 5 "relative") (lambda (_data error) (setq failed error)))
        (yt-test-wait-until (lambda () failed) "seek reply")
        (should (equal failed "error running command"))
        (should-not yt-mpv--pending)))))

(ert-deftest yt-mpv-framing-split-and-merged ()
  "Messages split across reads, or several in one read, all arrive."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let ((instance yt-mpv--instance)
          (seen nil))
      (puthash 1 (lambda (data _error) (push data seen)) yt-mpv--callbacks)
      (puthash 2 (lambda (data _error) (push data seen)) yt-mpv--callbacks)
      (yt-mpv--filter instance nil "{\"request_id\":1,\"error\":\"success\",\"data\":\"ü")
      (should-not seen)
      (yt-mpv--filter instance nil "nï\"}\n\n{\"request_id\":2,\"error\":\"success\",\"data\":2}\n{\"event\":\"start-file\",")
      (should (equal seen '(2 "ünï")))
      (yt-mpv--filter instance nil "\"playlist_entry_id\":4}\n")
      (should (eql yt-mpv--current 4))
      ;; An older instance is ignored.
      (yt-mpv--filter (1- instance) nil "{\"event\":\"start-file\",\"playlist_entry_id\":9}\n")
      (should (eql yt-mpv--current 4)))))

(ert-deftest yt-mpv-reconnects-and-observes-again ()
  "When the socket closes under a running mpv, callbacks fail and yt reconnects."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let ((server (yt-mpv-test--connect))
          failed)
      (yt-mpv-test--wait-for server "request_log_messages")
      (setf (yt-mpv-test--server-silent server) '("get_property"))
      (yt-mpv-send '("get_property" "playlist") (lambda (_data error) (setq failed error)))
      (yt-mpv-test--wait-for server "get_property")
      (delete-process (yt-mpv-test--server-client server))
      (yt-test-wait-until (lambda () failed) "disconnect")
      (should (equal failed "disconnected from mpv"))
      (yt-mpv-test--wait-for server "observe_property" 14)
      (should (= yt-mpv--reconnects 1))
      (should (process-live-p yt-mpv--connection)))))

;;;; Following playlist entries

(ert-deftest yt-mpv-marks-watched-near-the-end ()
  "A video stopped past the threshold is watched; one stopped early resumes."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (near (yt-mpv-test--video "videonear01"))
           (early (yt-mpv-test--video "videoearly1")))
      (let ((id (yt-mpv-test--load server near)))
        (yt-mpv-test--play-through server id :duration 100 :time-pos 95)
        (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 95))
                            "time-pos")
        (yt-mpv-test--end server id "stop"))
      (should (yt-video-watched (yt-cache-get "videonear01")))
      (let ((id (yt-mpv-test--load server early)))
        (yt-mpv-test--play-through server id :duration 600 :time-pos 120.5)
        (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 120.5))
                            "time-pos")
        (yt-mpv-test--end server id "quit"))
      (should-not (yt-video-watched (yt-cache-get "videoearly1")))
      (should (= (yt-video-position (yt-cache-get "videoearly1")) 120.5)))))

(ert-deftest yt-mpv-eof-is-watched-and-error-is-not ()
  "Playing to the end marks a video watched; an error never does."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (done (yt-mpv-test--video "videodone01"))
           (broken (yt-mpv-test--video "videobroke1")))
      (let ((id (yt-mpv-test--load server done)))
        (yt-mpv-test--play-through server id)
        (yt-mpv-test--end server id "eof"))
      (should (yt-video-watched (yt-cache-get "videodone01")))
      ;; An error after nearly all of it played: retried, but not watched.
      (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-combined.json"))
      (let ((id (yt-mpv-test--load server broken)))
        (yt-mpv-test--play-through server id :duration 100 :time-pos 99)
        (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 99))
                            "time-pos")
        (yt-mpv-test--end server id "error"))
      (should-not (yt-video-watched (yt-cache-get "videobroke1")))
      ;; Let the retry finish before the scenario is removed.
      (yt-mpv-test--wait-for server "loadfile" 3))))

(ert-deftest yt-mpv-error-retries-once ()
  "A playback error resolves the video again once and resumes there."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videoretry1")))
      (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-combined.json"))
      (let ((id (yt-mpv-test--load server video)))
        (yt-mpv-test--play-through server id :time-pos 61.7)
        (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 61.7))
                            "time-pos")
        ;; mpv moved on to the next entry, 7, which was queued.
        (push (cons "get_property" (vector (list :id 7 :current t) (list :id id)))
              (yt-mpv-test--server-replies server))
        (yt-mpv-test--emit server :event "end-file" :playlist_entry_id id
                           :reason "error" :file_error "loading failed"))
      (let* ((retry (yt-mpv-test--wait-for server "loadfile" 2))
             (command (plist-get retry :command)))
        (should (string-match-p "itag=18" (plist-get command :url)))
        (should (equal (plist-get (plist-get command :options) :start) "61"))
        ;; In its place, keeping the queue: never "replace".
        (should (equal (plist-get command :flags) "insert-at"))
        (should (equal (plist-get command :index) 1)))
      (should (equal (plist-get (yt-mpv-test--wait-for server "playlist-play-index") :command)
                     '("playlist-play-index" 1)))
      (should (equal (seq-drop (yt-mpv-test--names server)
                               (cl-position "get_property" (yt-mpv-test--names server)
                                            :test #'equal :from-end t))
                     '("get_property" "playlist-remove" "loadfile" "playlist-play-index")))
      (should (member '("playlist-remove" 1)
                      (mapcar (lambda (m) (plist-get m :command))
                              (yt-mpv-test--server-received server))))
      (yt-test-wait-until (lambda () (gethash 2 yt-mpv--entries)) "retry entry")
      (yt-test-wait-until (lambda () (yt-mpv--entry-video (gethash 2 yt-mpv--entries)))
                          "retry reply")
      (should (yt-mpv--entry-retried (gethash 2 yt-mpv--entries)))
      ;; A second error is not retried again.
      (yt-mpv-test--play-through server 2)
      (yt-mpv-test--end server 2 "error")
      (yt-test-sleep 0.2)
      (should (= (yt-test-calls ytdlp) 1))
      (should (= (length (seq-filter (lambda (n) (equal n "loadfile"))
                                     (yt-mpv-test--names server)))
                 2))
      (with-current-buffer yt-player-log-buffer
        (should (string-match-p "loading failed" (buffer-string)))))))

(ert-deftest yt-mpv-live-streams-keep-no-position ()
  "A live stream saves no position, and its retry starts at the live edge."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videolive01" :live-status 'is_live))
           (streams (plist-put (copy-sequence (yt-mpv-test--streams)) :live t)))
      (yt-cache-set-position "videolive01" 300.0)
      (should-not (yt-player--resume-position video))
      (yt-mpv--load video streams "replace")
      (yt-test-wait-until (lambda () (yt-mpv-test--entry-ids video)) "loadfile reply")
      (let ((id (car (yt-mpv-test--entry-ids video))))
        (yt-mpv-test--play-through server id :time-pos 500.0)
        (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 500.0))
                            "time-pos")
        (yt-cache-set-position "videolive01" nil)
        (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-combined.json"))
        (yt-mpv-test--emit server :event "end-file" :playlist_entry_id id
                           :reason "error" :file_error "manifest expired"))
      (let ((retry (plist-get (yt-mpv-test--wait-for server "loadfile" 2) :command)))
        (should-not (plist-get (plist-get retry :options) :start)))
      (should-not (yt-video-position (yt-cache-get "videolive01"))))))

(ert-deftest yt-mpv-entries-are-tracked-by-id ()
  "The same video queued twice is followed as two entries."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videotwice1"))
           (first (yt-mpv-test--load server video))
           (second (yt-mpv-test--load server video "append-play")))
      (should-not (eql first second))
      (yt-mpv-test--play-through server first :duration 100 :time-pos 40)
      (yt-test-wait-until (lambda () (equal (plist-get yt-mpv--properties :time-pos) 40))
                          "time-pos")
      (yt-mpv-test--end server first "stop")
      (should-not (yt-mpv--entry-finalized (gethash second yt-mpv--entries)))
      (should (= (yt-video-position (yt-cache-get "videotwice1")) 40)))))

(ert-deftest yt-mpv-finalize-runs-once ()
  "end-file twice and mpv exiting mark a video watched only once."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videoonce01"))
           (marks 0))
      (add-hook 'yt-watched-changed-functions (lambda (&rest _) (cl-incf marks)))
      (let ((id (yt-mpv-test--load server video)))
        (yt-mpv-test--play-through server id)
        (yt-mpv-test--end server id "eof")
        (yt-mpv--end-file id "eof" nil)
        (setq yt-mpv--current id)
        (delete-process yt-mpv--process)
        (yt-mpv--process-sentinel yt-mpv--instance yt-mpv--process "killed"))
      (should (= marks 1)))))

(ert-deftest yt-mpv-mark-at-start ()
  "With `yt-mark-watched-when' `start', a video counts when it starts."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((yt-mark-watched-when 'start)
           (server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videostart1")))
      (yt-mpv-test--play-through server (yt-mpv-test--load server video))
      (yt-test-wait-until (lambda () (yt-video-watched (yt-cache-get "videostart1")))
                          "watched at start"))))

(ert-deftest yt-mpv-start-adds-to-history ()
  "A video that starts in mpv goes into yt's history."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (video (yt-mpv-test--video "videohist01")))
      (yt-mpv-test--play-through server (yt-mpv-test--load server video))
      (yt-test-wait-until (lambda () (yt-cache-history)) "history")
      (should (equal (yt-video-id (car (car (yt-cache-history)))) "videohist01")))))

;;;; The whole path

(ert-deftest yt-mpv-play-starts-mpv-and-cleans-up ()
  "\\[yt-play] starts mpv on the display, plays, shows it, and cleans up."
  (yt-mpv-test--with-mpv (ytdlp mpv)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-separate.json"))
    (let* ((video (yt-mpv-test--video "fakevideo01" :duration 754))
           (socket (yt-mpv--socket-name (1+ yt-mpv--instance))))
      ;; A stale socket file from a crashed mpv.
      (yt-test-write socket "stale")
      (yt-play video)
      (let* ((argv-file (expand-file-name "argv" mpv))
             (argv (progn (yt-test-wait-until (lambda () (file-exists-p argv-file)) "mpv start")
                          (split-string (yt-test-file-string argv-file) "\n" t))))
        (should (member "--ytdl=no" argv))
        (should (member (concat "--input-ipc-server=" socket) argv))
        (should-not (file-exists-p socket))
        (should (equal (string-trim (yt-test-file-string (expand-file-name "display" mpv)))
                       "wayland-test")))
      (let* ((server (yt-mpv-test--serve socket))
             (load (plist-get (yt-mpv-test--wait-for server "loadfile") :command)))
        (should (string-match-p "itag=137" (plist-get load :url)))
        (should (string-match-p "itag=140" (plist-get (plist-get load :options) :audio-file)))
        (should yt-player-mode)
        (should (memq 'yt-player--mode-line global-mode-string))
        (yt-test-wait-until (lambda () (gethash 1 yt-mpv--entries)) "entry")
        (yt-mpv-test--play-through server 1 :duration 754 :time-pos 200.2 :speed 1.0)
        (yt-test-wait-until (lambda () (string-match-p "3:20/12:34" yt-player--mode-line))
                            "mode line")
        (should (string-prefix-p "▶ Title fakevideo01" yt-player--mode-line))
        ;; Player commands.
        (setf (yt-mpv-test--server-errors server) '(("playlist-next" . "error running command")))
        (yt-player-pause)
        (should (equal (plist-get (yt-mpv-test--wait-for server "cycle") :command)
                       '("cycle" "pause")))
        (yt-player-seek-backward)
        (should (equal (plist-get (yt-mpv-test--wait-for server "seek") :command)
                       '("seek" -5 "relative")))
        (yt-player-next)
        (yt-mpv-test--wait-for server "playlist-next")
        ;; mpv exits: the position is saved and the socket removed.
        (let ((process yt-mpv--process))
          (delete-process process)
          (yt-test-wait-until (lambda () (null yt-mpv--process)) "mpv exit"))
        (should (= (yt-video-position (yt-cache-get "fakevideo01")) 200.2))
        (should-not (yt-video-watched (yt-cache-get "fakevideo01")))
        (should-not (file-exists-p socket))
        (should (equal yt-player--mode-line ""))
        (delete-process (yt-mpv-test--server-process server))))))

(ert-deftest yt-mpv-play-resumes ()
  "A saved position is resumed, and a prefix argument plays from the start."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-separate.json"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-separate.json"))
    (let ((server (yt-mpv-test--connect))
          (video (yt-mpv-test--video "fakevideo01" :duration 754)))
      (yt-cache-set-position "fakevideo01" 125.0)
      (yt-play video)
      (should (equal (plist-get (plist-get (plist-get (yt-mpv-test--wait-for server "loadfile")
                                                      :command)
                                           :options)
                                :start)
                     "125"))
      (yt-play video nil t)
      (should-not (plist-get (plist-get (plist-get (yt-mpv-test--wait-for server "loadfile" 2)
                                                   :command)
                                        :options)
                             :start)))))

(ert-deftest yt-mpv-enqueue-keeps-order ()
  "Queued videos reach mpv's playlist in the order they were queued."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (yt-test-step ytdlp 1 :mode "stream" :out (yt-test-fixture-string "resolve-separate.json"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-combined.json"))
    (let ((server (yt-mpv-test--connect)))
      (yt-enqueue (list (yt-mpv-test--video "videoqueue1") (yt-mpv-test--video "videoqueue2")))
      (yt-mpv-test--wait-for server "loadfile" 2)
      (let ((loads (seq-filter (lambda (m) (equal (yt-mpv-test--command-name m) "loadfile"))
                               (yt-mpv-test--server-received server))))
        (should (equal (mapcar (lambda (m) (plist-get (plist-get m :command) :flags)) loads)
                       '("append-play" "append-play")))
        (should (string-match-p "itag=137" (plist-get (plist-get (car loads) :command) :url)))
        (should (string-match-p "itag=18" (plist-get (plist-get (cadr loads) :command) :url)))))))

(ert-deftest yt-mpv-playlist-buffer ()
  "The playlist buffer lists mpv's entries and plays or removes them."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (first (yt-mpv-test--video "videolist01" :channel "Fake Channel One"
                                      :duration 60))
           (second (yt-mpv-test--video "videolist02"))
           (id1 (yt-mpv-test--load server first))
           (id2 (yt-mpv-test--load server second "append-play")))
      (setq yt-player--current-backend 'mpv)
      (setf (yt-mpv-test--server-replies server)
            `(("get_property" . [(:id ,id1 :filename "a" :current t :playing t)
                                 (:id ,id2 :filename "b")])))
      (with-current-buffer (yt-player-playlist)
        (yt-test-wait-until (lambda () yt-playlist--items) "playlist")
        (let ((text (buffer-string)))
          (should (string-match-p "▶ +1 Fake Channel One +Title videolist01 +1:00" text))
          (should (string-match-p "  +2 +Title videolist02" text)))
        (goto-char (point-min))
        (search-forward "videolist02")
        (should (eq (yt-video-at-point) second))
        (yt-playlist-play)
        (should (equal (plist-get (yt-mpv-test--wait-for server "playlist-play-index") :command)
                       '("playlist-play-index" 1)))
        (yt-playlist-remove)
        (should (equal (plist-get (yt-mpv-test--wait-for server "playlist-remove") :command)
                       '("playlist-remove" 1)))
        (kill-buffer)))))

;;;; Shuffling

(defun yt-mpv-test--loads (server)
  "Return the loadfile commands SERVER received, oldest first."
  (mapcar (lambda (m) (plist-get m :command))
          (seq-filter (lambda (m) (equal (yt-mpv-test--command-name m) "loadfile"))
                      (yt-mpv-test--server-received server))))

(defun yt-mpv-test--start-entry (server id)
  "Wait until entry ID has its video, then start it through SERVER."
  (yt-test-wait-until (lambda () (and (gethash id yt-mpv--entries)
                                      (yt-mpv--entry-video (gethash id yt-mpv--entries))))
                      "entry video")
  (yt-mpv-test--play-through server id))

(ert-deftest yt-mpv-shuffle-queues-a-few-at-a-time ()
  "A shuffle plays one video and keeps two queued, refilling as they start."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (yt-player-shuffle-function #'identity)
           (yt-player-shuffle-ahead 2)
           (yt-player--shuffle nil)
           (yt-player--queue nil)
           (yt-player--queue-busy nil)
           (yt-player-file-started-functions nil)
           (yt-player-resolve-failed-functions nil)
           (videos (mapcar (lambda (n) (yt-mpv-test--video (format "videoshuf%02d" n)))
                           (number-sequence 1 5)))
           (url (lambda (n) (car (last (yt-test-argv ytdlp n))))))
      (dotimes (n 4)
        (yt-test-step ytdlp (1+ n) :out (yt-test-fixture-string "resolve-combined.json")))
      (yt-test-step ytdlp 5 :exit 1 :err "ERROR: [youtube] videoshuf05: Unable to extract something\n")
      (yt-player-shuffle videos "Five")
      ;; The first video alone: queuing more now would be wiped by its
      ;; loadfile replace.
      (yt-mpv-test--wait-for server "loadfile")
      (yt-test-sleep 0.2)
      (should (= (yt-test-calls ytdlp) 1))
      (should (equal (plist-get (car (yt-mpv-test--loads server)) :flags) "replace"))
      (should (string-suffix-p "videoshuf01" (funcall url 1)))
      ;; Once it started, two more are queued, in order.
      (yt-mpv-test--start-entry server 1)
      (yt-mpv-test--wait-for server "loadfile" 3)
      (should (equal (mapcar (lambda (c) (plist-get c :flags)) (cdr (yt-mpv-test--loads server)))
                     '("append-play" "append-play")))
      (should (string-suffix-p "videoshuf02" (funcall url 2)))
      (should (string-suffix-p "videoshuf03" (funcall url 3)))
      (yt-test-sleep 0.2)
      (should (= (yt-test-calls ytdlp) 3))
      ;; Each start queues one more.
      (yt-mpv-test--start-entry server 2)
      (yt-mpv-test--wait-for server "loadfile" 4)
      (should (string-suffix-p "videoshuf04" (funcall url 4)))
      ;; The last one fails to resolve; the shuffle carries on without it.
      (yt-mpv-test--start-entry server 3)
      (yt-test-wait-until (lambda () (= (yt-test-calls ytdlp) 5)) "fifth resolve")
      (yt-test-wait-until (lambda () (null (yt-player--shuffle-rest yt-player--shuffle)))
                          "rest used up")
      (should yt-player--shuffle)
      (yt-mpv-test--start-entry server 4)
      (yt-test-wait-until (lambda () (null yt-player--shuffle)) "shuffle done")
      (should (= (length (yt-mpv-test--loads server)) 4)))))

(ert-deftest yt-mpv-shuffle-ends-when-playing-something-else ()
  "Playing another video ends the shuffle and drops its queued videos."
  (yt-mpv-test--with-mpv (ytdlp _mpv)
    (let* ((server (yt-mpv-test--connect))
           (yt-player-shuffle-function #'identity)
           (yt-player--shuffle nil)
           (yt-player--queue nil)
           (yt-player--queue-busy nil)
           (yt-player-file-started-functions nil)
           (yt-player-resolve-failed-functions nil)
           (videos (mapcar (lambda (n) (yt-mpv-test--video (format "videostop%02d" n)))
                           (number-sequence 1 4))))
      (dotimes (n 3)
        (yt-test-step ytdlp (1+ n) :out (yt-test-fixture-string "resolve-combined.json")))
      (yt-player-shuffle videos)
      (yt-mpv-test--wait-for server "loadfile")
      (should yt-player--shuffle)
      (yt-play (yt-mpv-test--video "videoother1"))
      (should-not yt-player--shuffle)
      (should-not yt-player-file-started-functions)
      (yt-mpv-test--wait-for server "loadfile" 2)
      (yt-mpv-test--start-entry server 1)
      (yt-test-sleep 0.3)
      ;; Nothing more of the shuffle was queued.
      (should (= (yt-test-calls ytdlp) 2)))))

(ert-deftest yt-mpv-shuffle-playlist-command ()
  "\[yt-player-shuffle-playlist] asks mpv to shuffle its playlist."
  (yt-mpv-test--with-mpv (_ytdlp _mpv)
    (let ((server (yt-mpv-test--connect)))
      (setq yt-player--current-backend 'mpv)
      (should (eq (keymap-lookup yt-map "z") #'yt-player-shuffle-playlist))
      (yt-player-shuffle-playlist)
      (should (equal (plist-get (yt-mpv-test--wait-for server "playlist-shuffle") :command)
                     '("playlist-shuffle"))))))

(ert-deftest yt-mpv-shuffled-is-a-permutation ()
  "The default shuffle keeps every element."
  (let ((list (number-sequence 1 50)))
    (should (equal (sort (yt-player--shuffled list) #'<) list))
    (should-not (yt-player--shuffled nil))))

(ert-deftest yt-mpv-check-reports-missing-mpv ()
  "Without mpv, playing explains how to install it."
  (let ((yt-mpv-program "no-such-mpv-program"))
    (should-error (yt-player-backend-check 'mpv) :type 'user-error)))

(provide 'yt-mpv-tests)
;;; yt-mpv-tests.el ends here
