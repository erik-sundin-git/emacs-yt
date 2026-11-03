;;; yt-player-tests.el --- Tests for yt-player.el and yt-vlc.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for stream parsing, resolving through the fake yt-dlp (with
;; the format retry), waiting for the release time, the VLC arguments,
;; and playing in the fake VLC from the feed.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-player)
(require 'yt-vlc)

(defun yt-player-test--json (name)
  "Return the parsed JSON fixture NAME."
  (yt-process-parse-json (yt-test-fixture-string name)))

(defmacro yt-player-test--with-vlc (dirs &rest body)
  "Run BODY in a scenario with login cookies and the fake VLC.
DIRS is (YTDLP-DIR VLC-DIR), variables bound to the scenario
directory of the fake yt-dlp and to the fake VLC's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,(car dirs) _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let* ((,(cadr dirs) (expand-file-name "vlc" ,(car dirs)))
            (yt-player-backend 'vlc)
            (yt-vlc-program (expand-file-name "fake-vlc" yt-test-bin-dir))
            (yt-vlc-extra-args nil)
            (yt-player-format "bv*[height<=1080]+ba/b")
            (yt-player-available-margin 0.0)
            (yt-player--last-display nil)
            (yt-player--current-backend nil)
            (process-environment (append (list (concat "FAKE_VLC_DIR=" ,(cadr dirs))
                                               "WAYLAND_DISPLAY=wayland-test")
                                         process-environment)))
       (make-directory ,(cadr dirs) t)
       (unwind-protect
           (save-window-excursion ,@body)
         (yt-vlc--kill)
         (when (timerp yt-player--wait-timer)
           (cancel-timer yt-player--wait-timer))))))

(defun yt-player-test--vlc-argv (dir)
  "Wait for the fake VLC in DIR to start and return its arguments."
  (let ((file (expand-file-name "argv" dir)))
    (yt-test-wait-until (lambda () (file-exists-p file)) "VLC start")
    (split-string (yt-test-file-string file) "\n" t)))

;;;; Parsing

(ert-deftest yt-player-parse-separate-streams ()
  "Separate video and audio formats give both URLs and the latest release."
  (let ((streams (yt-ytdlp-parse-streams (yt-player-test--json "resolve-separate.json"))))
    (should (string-match-p "itag=137" (plist-get streams :video)))
    (should (string-match-p "itag=140" (plist-get streams :audio)))
    (should (= (plist-get streams :available-at) 1793500005))
    (should (equal (plist-get streams :headers)
                   '(("User-Agent" . "FakeAgent/1.0") ("Accept" . "*/*")
                     ("Sec-Fetch-Mode" . "navigate"))))
    (should (equal (plist-get streams :title) "A normal video with ünïcode"))
    (should (= (plist-get streams :duration) 754))))

(ert-deftest yt-player-parse-combined-stream ()
  "A combined format gives one URL, no audio and no release time."
  (let ((streams (yt-ytdlp-parse-streams (yt-player-test--json "resolve-combined.json"))))
    (should (string-match-p "itag=18" (plist-get streams :video)))
    (should-not (plist-get streams :audio))
    (should-not (plist-get streams :available-at))
    (should (equal (plist-get streams :headers) '(("User-Agent" . "FakeAgent/2.0"))))))

(ert-deftest yt-player-parse-no-stream ()
  "JSON without a stream URL gives nil."
  (should-not (yt-ytdlp-parse-streams '(:id "x" :title "No formats"))))

(ert-deftest yt-player-video-from-url ()
  "Video ids are found in the usual YouTube URL forms."
  (dolist (url '("https://www.youtube.com/watch?v=abcdefghijk"
                 "https://www.youtube.com/watch?list=PL1&v=abcdefghijk&t=10"
                 "https://youtu.be/abcdefghijk?si=x"
                 "https://m.youtube.com/watch?v=abcdefghijk"
                 "abcdefghijk"))
    (should (equal (yt-video-id (yt-video-from-url url)) "abcdefghijk")))
  (let ((short (yt-video-from-url "https://www.youtube.com/shorts/abcdefghijk")))
    (should (yt-video-short-p short))
    (should (equal (yt-video-url short) "https://www.youtube.com/shorts/abcdefghijk")))
  (should-not (yt-video-from-url "https://example.com/watch?v=abcdefghijk"))
  (should-not (yt-video-from-url "https://www.youtube.com/watch?v=short")))

(ert-deftest yt-player-vlc-args ()
  "VLC gets the title, user agent, start time and both streams."
  (let ((yt-vlc-extra-args '("--fullscreen"))
        (streams (yt-ytdlp-parse-streams (yt-player-test--json "resolve-separate.json"))))
    (should (equal (yt-vlc-args streams 90)
                   (list "--fullscreen" "--no-video-title-show" "--play-and-exit"
                         "--meta-title=A normal video with ünïcode"
                         "--http-user-agent=FakeAgent/1.0"
                         "--start-time=90"
                         (concat "--input-slave=" (plist-get streams :audio))
                         (plist-get streams :video)))))
  (let ((yt-vlc-extra-args nil)
        (streams (yt-ytdlp-parse-streams (yt-player-test--json "resolve-combined.json"))))
    (should-not (seq-find (lambda (arg) (string-prefix-p "--input-slave" arg))
                          (yt-vlc-args streams)))))

(ert-deftest yt-player-redacts-stream-urls ()
  "Stream URLs never reach the player log."
  (should (equal (yt-player-redact
                  "vlc https://rr1---x.googlevideo.com/videoplayback?a=1&b=2 done")
                 "vlc <stream URL> done"))
  ;; VLC also prints locations without the scheme, in quotes.
  (should (equal (yt-player-redact
                  "demux: location='rr4---x.googlevideo.com/videoplayback?expire=1&ip=2'")
                 "demux: location='<stream URL>'")))

;;;; Resolving and waiting

(ert-deftest yt-player-resolve-uses-format-and-cookies ()
  "Resolving runs yt-dlp with the format, -j and the video URL after --."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-separate.json"))
    (let ((yt-player-format "18") result)
      (yt-player-resolve (yt-video-from-url "fakevideo01")
                         (lambda (streams _info) (setq result streams))
                         (lambda (err) (setq result err)))
      (yt-test-wait-until (lambda () result) "resolve")
      (should (plist-get result :video))
      (let ((argv (yt-test-argv ytdlp 1)))
        (should (equal (last argv 6)
                       '("--no-playlist" "-f" "18" "-j" "--"
                         "https://www.youtube.com/watch?v=fakevideo01")))
        (should (member "--cookies" argv)))
      (should-not (yt-test-cookie-copies)))))

(ert-deftest yt-player-resolve-retries-with-best-format ()
  "An unavailable format is retried once with \"b\"."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1
                  :err "ERROR: [youtube] fakevideo01: Requested format is not available. Use --list-formats for a list of available formats\n")
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-combined.json"))
    (let (result)
      (yt-player-resolve (yt-video-from-url "fakevideo01")
                         (lambda (streams _info) (setq result streams))
                         (lambda (err) (setq result err)))
      (yt-test-wait-until (lambda () result) "resolve")
      (should (string-match-p "itag=18" (plist-get result :video)))
      (should (equal (cadr (member "-f" (yt-test-argv ytdlp 2))) "b")))))

(ert-deftest yt-player-resolve-reports-age-restriction ()
  "A classified problem reaches the error callback with its message."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1
                  :err "ERROR: [youtube] fakevideo01: Sign in to confirm your age. This video may be inappropriate for some users.\n")
    (let (result)
      (yt-player-resolve (yt-video-from-url "fakevideo01")
                         (lambda (streams _info) (setq result streams))
                         (lambda (err) (setq result err)))
      (yt-test-wait-until (lambda () result) "resolve")
      (should (eq (plist-get result :class) 'age))
      (should (equal (plist-get result :message) "This video is age-restricted"))
      (should (= (yt-test-calls ytdlp) 1)))))

(defun yt-player-test--resolve-json (expires &rest overrides)
  "Return a resolve JSON whose stream URL expires at EXPIRES, with OVERRIDES."
  (let ((info (yt-process-parse-json (yt-test-fixture-string "resolve-combined.json"))))
    (setq info (plist-put info :url (format "https://rr1---fake.googlevideo.com/videoplayback?itag=18&%s=%d"
                                            "expire" expires)))
    (while overrides
      (setq info (plist-put info (pop overrides) (pop overrides))))
    (json-serialize info)))

(defun yt-player-test--resolve (video &optional cache)
  "Resolve VIDEO with CACHE and wait; return the streams."
  (let (result)
    (yt-player-resolve video (lambda (streams _info) (setq result streams))
                       (lambda (err) (setq result (list :error err)))
                       :cache cache)
    (yt-test-wait-until (lambda () result) "resolve")
    result))

(ert-deftest yt-player-keeps-streams-until-they-expire ()
  "Resolved streams are reused until shortly before they expire."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (let* ((now 1793500000.0)
           (yt--now-function (lambda () now))
           (video (yt-video--make :id "fakevideo03"
                                  :url "https://www.youtube.com/watch?v=fakevideo03")))
      (dotimes (n 4)
        (yt-test-step ytdlp (1+ n) :out (yt-player-test--resolve-json (+ now 21600))))
      (let ((first (yt-player-test--resolve video t)))
        (should (equal (yt-player-test--resolve video t) first))
        (should (= (yt-test-calls ytdlp) 1))
        ;; Without :cache, as for VLC, yt-dlp runs again.
        (yt-player-test--resolve video)
        (should (= (yt-test-calls ytdlp) 2))
        ;; Close to the expiry: resolved again.
        (setq now (+ now 21600 (- yt-player-stream-cache-margin) 1))
        (yt-player-test--resolve video t)
        (should (= (yt-test-calls ytdlp) 3))
        ;; New cookies: resolved again.
        (cl-incf yt-auth--generation)
        (yt-player-test--resolve video t)
        (should (= (yt-test-calls ytdlp) 4))
        ;; Forgotten, as after a failure.
        (yt-player-forget-streams video)
        (should-not (yt-player--kept-streams video yt-player-format))))))

(ert-deftest yt-player-keeps-no-live-streams ()
  "Live streams and URLs without an expiry are never kept."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (let ((video (yt-video--make :id "fakevideo03"
                                 :url "https://www.youtube.com/watch?v=fakevideo03")))
      (yt-test-step ytdlp 1 :out (yt-player-test--resolve-json (+ (float-time) 21600)
                                                               :live_status "is_live"))
      (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-combined.json"))
      (yt-test-step ytdlp 3 :out (yt-test-fixture-string "resolve-combined.json"))
      (yt-player-test--resolve video t)
      (yt-player-test--resolve video t)
      (yt-player-test--resolve video t)
      (should (= (yt-test-calls ytdlp) 3))
      (should (zerop (hash-table-count yt-player--streams))))))

(ert-deftest yt-player-waits-for-release ()
  "The player starts only after the streams' release time."
  (let ((yt-player-available-margin 0.0)
        (start (float-time))
        called)
    (yt-player-when-available (list :available-at (+ start 0.4))
                               (lambda () (setq called (float-time))))
    ;; Not at once; and whenever it runs, not before the release time
    ;; (a sleep here would fail on a busy machine).
    (should-not called)
    (yt-test-wait-until (lambda () called) "release")
    (should (>= (- called start) 0.4))
    ;; Without a release time, or with one in the past, at once.
    (setq called nil)
    (yt-player-when-available (list :available-at (- start 100))
                               (lambda () (setq called t)))
    (yt-test-wait-until (lambda () called) "past release")))

;;;; VLC

(ert-deftest yt-player-play-in-vlc-from-feed ()
  "RET in the feed plays the video at point in VLC and marks it watched."
  (yt-player-test--with-vlc (ytdlp vlc)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-separate.json"))
    (with-current-buffer (yt)
      (yt-test-wait-until (lambda () (not yt-feed--refreshing)) "feed")
      (goto-char (gethash "fakevideo01" (yt-feed--row-positions)))
      (should (eq (keymap-lookup yt-feed-mode-map "RET") #'yt-play))
      (call-interactively #'yt-play)
      (let ((argv (yt-player-test--vlc-argv vlc)))
        (should (member "--play-and-exit" argv))
        (should (string-match-p "itag=137" (car (last argv))))
        (should (seq-find (lambda (arg) (string-match-p "\\`--input-slave=.*itag=140" arg))
                          argv)))
      (should (equal (string-trim (yt-test-file-string (expand-file-name "display" vlc)))
                     "wayland-test"))
      (should (process-live-p yt-vlc--process))
      (should (yt-video-watched (yt-cache-get "fakevideo01")))
      ;; The row shows the video as watched.
      (goto-char (gethash "fakevideo01" (yt-feed--row-positions)))
      (should-not (looking-at-p "●"))
      ;; Stopping closes VLC.
      (let ((process yt-vlc--process))
        (yt-player-stop)
        (should-not (process-live-p process))))))

(ert-deftest yt-player-new-video-replaces-vlc ()
  "Playing another video closes the running VLC first."
  (yt-player-test--with-vlc (ytdlp vlc)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-combined.json"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "resolve-separate.json"))
    (yt-play (yt-video-from-url "fakevideo03"))
    (yt-player-test--vlc-argv vlc)
    (let ((first yt-vlc--process))
      (delete-file (expand-file-name "argv" vlc))
      (yt-play (yt-video-from-url "fakevideo01"))
      (should (string-match-p "itag=137" (car (last (yt-player-test--vlc-argv vlc)))))
      (should-not (process-live-p first))
      (should (process-live-p yt-vlc--process)))))

(ert-deftest yt-player-vlc-failure-is-logged ()
  "When VLC fails, its output goes to the player log without stream URLs."
  (yt-player-test--with-vlc (ytdlp vlc)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "resolve-combined.json"))
    (yt-test-write (expand-file-name "exit" vlc) "1")
    (yt-test-write (expand-file-name "out" vlc)
                   "access error: https://rr1---x.googlevideo.com/videoplayback?itag=18 403\n")
    (when (get-buffer yt-player-log-buffer)
      (kill-buffer yt-player-log-buffer))
    (yt-play (yt-video-from-url "fakevideo03"))
    (yt-test-wait-until (lambda () (get-buffer yt-player-log-buffer)) "log")
    (with-current-buffer yt-player-log-buffer
      (should (string-match-p "VLC exited with status 1" (buffer-string)))
      (should (string-match-p "access error: <stream URL> 403" (buffer-string)))
      (should-not (string-match-p "googlevideo" (buffer-string))))))

(ert-deftest yt-player-needs-display-and-vlc ()
  "Playing without a display or without VLC fails before resolving."
  (yt-player-test--with-vlc (ytdlp _vlc)
    (let ((process-environment (append '("WAYLAND_DISPLAY" "DISPLAY")
                                       process-environment)))
      (should-error (yt-play (yt-video-from-url "fakevideo01")) :type 'user-error))
    (let ((yt-vlc-program "no-such-vlc-program"))
      (should-error (yt-play (yt-video-from-url "fakevideo01")) :type 'user-error))
    (should (= (yt-test-calls ytdlp) 0))))

(ert-deftest yt-player-auto-backend ()
  "`auto' picks mpv only when it and yt's mpv backend are installed."
  (let ((yt-player-backend 'auto))
    (cl-letf (((symbol-function 'yt-player--mpv-available-p) #'ignore))
      (should (eq (yt-player-backend) 'vlc)))
    (cl-letf (((symbol-function 'yt-player--mpv-available-p) (lambda () t)))
      (should (eq (yt-player-backend) 'mpv))))
  (let ((yt-player-backend 'vlc))
    (should (eq (yt-player-backend) 'vlc))))

(provide 'yt-player-tests)
;;; yt-player-tests.el ends here
