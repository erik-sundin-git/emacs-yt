;;; yt-browse-tests.el --- Tests for channels, uploads, search and info -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the M5 views: the channels list, a channel's uploads,
;; search results and the info buffer, plus the parsers, the cache
;; migration and the queue they rely on.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-channels)
(require 'yt-info)

(defconst yt-browse-test--now 1793500000
  "The fixed current time of these tests.")

(defmacro yt-browse-test--with (ytdlp &rest body)
  "Run BODY in a scenario with cookies and a fixed clock.
YTDLP is bound to the fake yt-dlp's scenario directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,ytdlp _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let ((yt--now-function (lambda () yt-browse-test--now))
           (yt-feed-refresh-interval 900))
       (unwind-protect
           (save-window-excursion ,@body)
         (dolist (name (list yt-channels-buffer yt-info-buffer))
           (when (get-buffer name)
             (kill-buffer name)))))))

(defun yt-browse-test--wait-feed (buffer)
  "Wait until the feed BUFFER is not refreshing; return it."
  (yt-test-wait-until (lambda () (not (buffer-local-value 'yt-feed--refreshing buffer)))
                      "feed")
  buffer)

;;;; Parsers, queue and cache

(ert-deftest yt-browse-upload-entries-name-their-channel ()
  "Uploads entries take the channel from the playlist fields."
  (let ((video (yt-video-from-json
                (yt-process-parse-json
                 (car (split-string (yt-test-fixture-string "uploads.ndjson") "\n" t)))
                t)))
    (should (equal (yt-video-channel video) "Fake Channel Two"))
    (should (equal (yt-video-channel-id video) "UCfakechannel00000000002"))))

(ert-deftest yt-browse-args ()
  "The channel, search and info arguments end with -- and the target."
  (should (equal (last (yt-ytdlp-channel-args "https://www.youtube.com/channel/UC1/" 50) 4)
                 '("youtubetab:approximate_date" "-j" "--"
                   "https://www.youtube.com/channel/UC1/videos")))
  (should (member "1:50" (yt-ytdlp-channel-args "https://x" 50)))
  (should (equal (last (yt-ytdlp-search-args "org mode" 20) 2)
                 '("--" "ytsearch20:org mode")))
  (should (equal (yt-ytdlp-info-args "https://www.youtube.com/watch?v=x")
                 '("-J" "--no-playlist" "--ignore-no-formats-error" "--"
                   "https://www.youtube.com/watch?v=x"))))

(ert-deftest yt-browse-queue-limit ()
  "A queue runs at most its limit of jobs at once, in order."
  (let ((queue (yt-process-queue-create 2))
        (started nil)
        (dones nil))
    (dotimes (i 3)
      (yt-process-queue-run queue (lambda (done)
                                    (push i started)
                                    (push done dones))))
    (should (equal started '(1 0)))
    (should (= (yt-process-queue-running queue) 2))
    ;; Finishing a job starts the next; finishing twice counts once.
    (funcall (car (last dones)))
    (funcall (car (last dones)))
    (should (equal started '(2 1 0)))
    (should (= (yt-process-queue-running queue) 2))
    (mapc #'funcall dones)
    (should (= (yt-process-queue-running queue) 0))))

(ert-deftest yt-browse-cache-migrates-to-channels-table ()
  "A version 1 cache gains the channels table and keeps its videos."
  (yt-test-with-scenario (_ _)
    (let ((file (yt-cache-file-name)))
      (make-directory (file-name-directory file) t)
      (set-file-modes (file-name-directory file) #o700)
      (let ((db (sqlite-open file)))
        (sqlite-execute db "CREATE TABLE videos (id TEXT PRIMARY KEY, data TEXT NOT NULL,
                             fetched_at INTEGER, watched INTEGER NOT NULL DEFAULT 0, position REAL)")
        (sqlite-execute db "CREATE TABLE feed (source TEXT NOT NULL, id TEXT NOT NULL,
                             pos INTEGER NOT NULL, PRIMARY KEY (source, id))")
        (sqlite-execute db "CREATE TABLE meta (key TEXT PRIMARY KEY, value)")
        (sqlite-execute db "INSERT INTO videos (id, data, watched) VALUES ('old', '{\"id\":\"old\"}', 1)")
        (sqlite-execute db "PRAGMA user_version = 1")
        (sqlite-close db))
      (set-file-modes file #o600)
      (should (yt-video-watched (yt-cache-get "old")))
      (should (= (caar (sqlite-select (yt-cache-db) "PRAGMA user_version"))
                 yt-cache--schema-version))
      (should (sqlite-select (yt-cache-db)
                             "SELECT name FROM sqlite_master WHERE name = 'playlists'"))
      (yt-cache-put-channels '((:id "UC1" :name "One" :url "https://x" :followers 3 :extra "no")))
      (should (equal (yt-cache-channels)
                     '((:id "UC1" :name "One" :url "https://x" :followers 3)))))))

;;;; Channels

(ert-deftest yt-browse-channels-list ()
  "The channels list shows each channel with its unwatched count."
  (yt-browse-test--with ytdlp
    (yt-cache-put-feed "subscriptions"
                       (mapcar (lambda (line) (yt-video-from-json (yt-process-parse-json line) t))
                               (split-string (yt-test-fixture-string "feed.ndjson") "\n" t)))
    (yt-mark-watched "fakevideo03")
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "channels.json"))
    (with-current-buffer (yt-channels)
      (yt-test-wait-until (lambda () (not yt-list--refreshing)) "channels")
      (should (equal (yt-feed--printed-ids)
                     '("UCfakechannel00000000001" "UCfakechannel00000000002"
                       "UCfakechannel00000000009")))
      (let ((text (buffer-string)))
        (should (string-match-p "Fake Channel One +1 +5h" text))
        (should (string-match-p "Fake Channel Two +1 *$" text))
        (should (string-match-p "Quiet Fake Channel *$" text)))
      (should (string-match-p "3 channels" (yt-list-header-line)))
      (should (member "https://www.youtube.com/feed/channels" (yt-test-argv ytdlp 1)))
      (yt-list-filter "quiet")
      (should (equal (yt-feed--printed-ids) '("UCfakechannel00000000009")))
      (yt-list-filter ""))
    ;; A second visit uses the cached list.
    (kill-buffer yt-channels-buffer)
    (yt-channels)
    (should (= (yt-test-calls ytdlp) 1))
    (with-current-buffer yt-channels-buffer
      (should (= (length (yt-feed--printed-ids)) 3)))))

(ert-deftest yt-browse-channel-uploads ()
  "RET on a channel shows its uploads, fetched from its videos tab."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "channels.json"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "uploads.ndjson"))
    (with-current-buffer (yt-channels)
      (yt-test-wait-until (lambda () (not yt-list--refreshing)) "channels")
      (goto-char (point-min))
      (search-forward "Fake Channel Two")
      (call-interactively #'yt-channels-open))
    (let ((buffer (yt-browse-test--wait-feed (get-buffer "*yt: Fake Channel Two*"))))
      (with-current-buffer buffer
        (should (equal (yt-feed-test-ids) '("fakeupload1" "fakeupload2")))
        (should (equal yt-feed--source
                       '(channel "UCfakechannel00000000002"
                                 "https://www.youtube.com/channel/UCfakechannel00000000002"
                                 "Fake Channel Two"))))
      (should (equal (car (last (yt-test-argv ytdlp 2)))
                     "https://www.youtube.com/channel/UCfakechannel00000000002/videos"))
      (should (equal (yt-test-ids (yt-cache-feed "channel:UCfakechannel00000000002"))
                     '("fakeupload1" "fakeupload2"))))))

(defun yt-feed-test-ids ()
  "Return the ids of the rows printed in the current buffer."
  (yt-feed--printed-ids))

(defun yt-test-ids (videos)
  "Return the ids of VIDEOS."
  (mapcar #'yt-video-id videos))

(ert-deftest yt-browse-open-channel-of-video ()
  "\\`o' on a feed video shows the uploads of its channel."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "uploads.ndjson"))
    (with-current-buffer (yt-browse-test--wait-feed (yt))
      (goto-char (gethash "fakevideo02" (yt-feed--row-positions)))
      (should (eq (keymap-lookup yt-feed-mode-map "o") #'yt-feed-open-channel))
      (call-interactively #'yt-feed-open-channel))
    (with-current-buffer (yt-browse-test--wait-feed (get-buffer "*yt: Fake Channel Two*"))
      (should (equal (yt-feed-test-ids) '("fakeupload1" "fakeupload2"))))
    ;; A Short without a known channel cannot be opened.
    (with-current-buffer "*yt: Subscriptions*"
      (goto-char (gethash "fakeshort04" (yt-feed--row-positions)))
      (should-error (call-interactively #'yt-feed-open-channel) :type 'user-error))))

;;;; A channel's past live streams

(defconst yt-browse-test--stream
  (concat "{\"_type\": \"url\", \"ie_key\": \"Youtube\", \"id\": \"fakestream1\", "
          "\"url\": \"https://www.youtube.com/watch?v=fakestream1\", \"title\": \"A past stream\", "
          "\"duration\": 7200, \"timestamp\": 1793200000, \"live_status\": \"was_live\", "
          "\"playlist_channel\": \"Fake Channel Two\", "
          "\"playlist_channel_id\": \"UCfakechannel00000000002\"}\n")
  "A line of a channel's streams tab.")

(defun yt-browse-test--channel ()
  "Show the uploads of Fake Channel Two and return the buffer once fetched."
  (yt-browse-test--wait-feed
   (yt-feed-channel "UCfakechannel00000000002"
                    "https://www.youtube.com/channel/UCfakechannel00000000002"
                    "Fake Channel Two")))

(ert-deftest yt-browse-channel-streams ()
  "\\`T' switches a channel between its videos and its past streams."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "uploads.ndjson"))
    (yt-test-step ytdlp 2 :out yt-browse-test--stream)
    (with-current-buffer (yt-browse-test--channel)
      (should (eq (keymap-lookup yt-feed-mode-map "T") #'yt-feed-toggle-streams))
      (yt-feed-toggle-streams)
      (yt-browse-test--wait-feed (current-buffer))
      (should (equal (yt-feed-test-ids) '("fakestream1")))
      (should (equal (car (last (yt-test-argv ytdlp 2)))
                     "https://www.youtube.com/channel/UCfakechannel00000000002/streams"))
      (should (string-match-p "past live streams" (yt-feed--header-line)))
      ;; Each tab has its own place in the cache.
      (should (equal (yt-test-ids (yt-cache-feed "channel:UCfakechannel00000000002:streams"))
                     '("fakestream1")))
      (should (equal (yt-test-ids (yt-cache-feed "channel:UCfakechannel00000000002"))
                     '("fakeupload1" "fakeupload2")))
      ;; Back to the videos, fresh in the cache: nothing is fetched.
      (yt-feed-toggle-streams)
      (should-not yt-feed--refreshing)
      (should (equal (yt-feed-test-ids) '("fakeupload1" "fakeupload2")))
      (should (= (yt-test-calls ytdlp) 2))
      (should-not (string-match-p "past live streams" (yt-feed--header-line))))))

(ert-deftest yt-browse-channel-without-streams ()
  "A channel without a streams tab has no past streams, and no error."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "uploads.ndjson"))
    (yt-test-step ytdlp 2 :exit 1
                  :err "ERROR: [youtube:tab] UCfakechannel00000000002: This channel does not have a streams tab\n")
    (with-current-buffer (yt-browse-test--channel)
      (yt-feed-toggle-streams)
      (yt-browse-test--wait-feed (current-buffer))
      (should-not yt-feed--error)
      (should-not (yt-feed-test-ids))
      (should (string-match-p "This channel has no past live streams" (buffer-string))))))

(ert-deftest yt-browse-streams-only-in-channels ()
  "\\`T' outside a channel's buffer says why it does nothing."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-browse-test--wait-feed (yt))
      (should-error (yt-feed-toggle-streams) :type 'user-error))))

;;;; Search

(ert-deftest yt-browse-search ()
  "Search results show in their own buffer and keep the query out of logs."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "uploads.ndjson"))
    (with-current-buffer (get-buffer-create "*yt-log*")
      (let ((inhibit-read-only t)) (erase-buffer)))
    (let ((buffer (yt-browse-test--wait-feed (yt-search "secret query"))))
      (with-current-buffer buffer
        (should (equal (buffer-name) "*yt: Search: secret query*"))
        (should (equal (yt-feed-test-ids) '("fakeupload1" "fakeupload2"))))
      (should (equal (car (last (yt-test-argv ytdlp 1))) "ytsearch20:secret query"))
      (with-current-buffer "*yt-log*"
        (should (string-match-p "-- REDACTED" (buffer-string)))
        (should-not (string-match-p "secret" (buffer-string))))
      ;; The results are cached as videos, but not as a feed.
      (should (yt-cache-get "fakeupload1"))
      (should-not (sqlite-select (yt-cache-db) "SELECT * FROM feed WHERE source LIKE '%search%'"))
      (kill-buffer buffer))))

;;;; Info

(ert-deftest yt-browse-info-buffer ()
  "\\`i' shows the video at once, then its details and chapters."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :mode "stream" :out (yt-test-fixture-string "info.json"))
    (with-current-buffer (yt-browse-test--wait-feed (yt))
      (goto-char (gethash "fakevideo01" (yt-feed--row-positions)))
      (should (eq (keymap-lookup yt-feed-mode-map "i") #'yt-info))
      (call-interactively #'yt-info))
    (with-current-buffer yt-info-buffer
      (should (string-match-p "A normal video with ünïcode" (buffer-string)))
      (should (string-match-p "Fetching details" (buffer-string)))
      (should (string-match-p "Published  about 2026-10-31 (5h ago)" (buffer-string)))
      (yt-test-wait-until (lambda () (not yt-info--status)) "details")
      (let ((text (buffer-string)))
        (should (string-match-p "Views +1,234,567" text))
        (should (string-match-p "Likes +8,901" text))
        (should (string-match-p "Tags +fake, emacs" text))
        (should (string-match-p "Chapters\n +0:00  Intro\n +2:00  The main part" text))
        (should (string-match-p "A fake description" text))
        ;; The exact upload time replaced the approximate one.
        (should (string-match-p "Published  2026-10-31 [0-9:]+ (5h ago)" text)))
      (should (= (yt-video-timestamp (yt-cache-get "fakevideo01")) 1793481234))
      (should-not (yt-video-timestamp-approx-p (yt-cache-get "fakevideo01")))
      ;; A chapter plays from its start.
      (let (played)
        (cl-letf (((symbol-function 'yt-play-at)
                   (lambda (video start &rest _) (setq played (list (yt-video-id video) start)))))
          (goto-char (point-min))
          (search-forward "2:00  The main part")
          (goto-char (match-beginning 0))
          (yt-info-ret))
        (should (equal played '("fakevideo01" 120.0))))
      (should (eq (yt-video-at-point) yt-info--video)))))

(ert-deftest yt-browse-info-error ()
  "A failed details fetch is shown, and the basic fields stay."
  (yt-browse-test--with ytdlp
    (yt-test-step ytdlp 1 :exit 1
                  :err "ERROR: [youtube] fakevideo01: Join this channel to get access to members-only content\n")
    (with-current-buffer (yt-info (yt-video-from-url "fakevideo01"))
      (yt-test-wait-until (lambda () (stringp yt-info--status)) "error")
      (should (string-match-p "for channel members only" (buffer-string)))
      (should (string-match-p "URL +https://www.youtube.com/watch\\?v=fakevideo01"
                              (buffer-string))))))

(provide 'yt-browse-tests)
;;; yt-browse-tests.el ends here
