;;; yt-cache-tests.el --- Tests for yt-cache.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the SQLite cache: opening and the schema, storing and
;; merging videos, feed order, reopening (a restart), and watched state.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-cache)

(defun yt-cache-test--video (id &rest slots)
  "Return a `yt-video' with ID and the SLOTS given as keyword arguments."
  (apply #'yt-video--make :id id
         (append slots (list :title (concat "Title " id)
                             :url (concat "https://www.youtube.com/watch?v=" id)))))

(defun yt-cache-test--fixture-videos ()
  "Return the videos of the feed fixture, in order."
  (mapcar (lambda (line)
            (yt-video-from-json (yt-process-parse-json line) t))
          (split-string (yt-test-fixture-string "feed.ndjson") "\n" t)))

(defun yt-cache-test--watched-p (id)
  "Return non-nil if the cached video ID is marked watched."
  (yt-video-watched (yt-cache-get id)))

(defun yt-cache-test--ids (videos)
  "Return the ids of VIDEOS."
  (mapcar #'yt-video-id videos))

(ert-deftest yt-cache-open-creates-private-wal-database ()
  "The cache file is mode 0600, in WAL mode, with a busy timeout and schema."
  (yt-test-with-scenario (_ _)
    (let ((db (yt-cache-db))
          (file (yt-cache-file-name)))
      (should (yt-test-under-root-p file))
      (should (equal (file-name-nondirectory file) "yt.sqlite"))
      (should (= (file-modes file) #o600))
      (should (= (file-modes (file-name-directory file)) #o700))
      (should (equal (caar (sqlite-select db "PRAGMA journal_mode")) "wal"))
      (should (= (caar (sqlite-select db "PRAGMA busy_timeout")) 3000))
      (should (= (caar (sqlite-select db "PRAGMA user_version"))
                 yt-cache--schema-version))
      (should (member '("videos") (sqlite-select
                                   db "SELECT name FROM sqlite_master WHERE type = 'table'"))))))

(ert-deftest yt-cache-refuses-newer-schema ()
  "A newer cache that needs a newer yt is refused rather than changed."
  (yt-test-with-scenario (_ _)
    (yt-cache-db)
    (sqlite-execute (yt-cache-db) "PRAGMA user_version = 99")
    (sqlite-execute (yt-cache-db) "UPDATE meta SET value = 99 WHERE key = 'min_reader'")
    (yt-cache-close)
    (should-error (yt-cache-db) :type 'user-error)
    (should-not yt-cache--db)))

(ert-deftest yt-cache-opens-newer-additive-schema ()
  "After a rollback, a newer cache that only added tables still opens."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-videos (list (yt-video--make :id "aaaaaaaaaaa" :title "Kept")))
    (sqlite-execute (yt-cache-db) "CREATE TABLE future (x)")
    (sqlite-execute (yt-cache-db) "PRAGMA user_version = 5")
    (yt-cache-close)
    (should (equal (yt-video-title (yt-cache-get "aaaaaaaaaaa")) "Kept"))
    ;; Left as the newer yt wrote it.
    (should (= (caar (sqlite-select (yt-cache-db) "PRAGMA user_version")) 5))))

(ert-deftest yt-cache-migrates-old-schemas-with-a-backup ()
  "A cache of an older schema is copied first, and keeps its data."
  (yt-test-with-scenario (_ _)
    (let ((file (yt-cache-file-name)))
      ;; A version 3 cache: no history table, no min_reader.
      (yt-ensure-state-directory)
      (let ((db (sqlite-open file)))
        (dolist (sql '("CREATE TABLE videos (id TEXT PRIMARY KEY, data TEXT NOT NULL,
                         fetched_at INTEGER, watched INTEGER NOT NULL DEFAULT 0, position REAL)"
                       "CREATE TABLE feed (source TEXT NOT NULL, id TEXT NOT NULL,
                         pos INTEGER NOT NULL, PRIMARY KEY (source, id))"
                       "CREATE TABLE meta (key TEXT PRIMARY KEY, value)"
                       "CREATE TABLE channels (id TEXT PRIMARY KEY, pos INTEGER NOT NULL, data TEXT NOT NULL)"
                       "CREATE TABLE playlists (id TEXT PRIMARY KEY, saved_at INTEGER NOT NULL, data TEXT NOT NULL)"
                       "INSERT INTO videos VALUES ('aaaaaaaaaaa', '{\"id\":\"aaaaaaaaaaa\"}', 1, 1, 61.5)"
                       "INSERT INTO playlists VALUES ('PLfake', 1, '{\"id\":\"PLfake\",\"title\":\"T\"}')"
                       "PRAGMA user_version = 3"))
          (sqlite-execute db sql))
        (sqlite-close db))
      (set-file-modes file #o600)
      (let ((video (yt-cache-get "aaaaaaaaaaa")))
        (should (yt-video-watched video))
        (should (= (yt-video-position video) 61.5)))
      (should (yt-cache-playlist-saved-p "PLfake"))
      (should (= (caar (sqlite-select (yt-cache-db) "PRAGMA user_version"))
                 yt-cache--schema-version))
      (should (equal (yt-cache-meta "min_reader") yt-cache--min-reader-version))
      (yt-cache-add-history (yt-video--make :id "aaaaaaaaaaa"))
      (let ((backups (yt-cache--backup-files file)))
        (should (= (length backups) 1))
        (should (= (file-modes (car backups)) #o600))
        ;; The backup is the version 3 cache, as it was.
        (let ((db (sqlite-open (car backups))))
          (unwind-protect
              (should (= (caar (sqlite-select db "PRAGMA user_version")) 3))
            (sqlite-close db)))))))

(ert-deftest yt-cache-backup-keeps-a-few ()
  "`yt-cache-backup' writes a private copy and keeps the newest ones."
  (yt-test-with-scenario (_ _)
    (let ((yt-cache-backups 2)
          (n 0))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (&rest _) (format "2026110%d-000000" (cl-incf n)))))
        (dotimes (_ 3) (yt-cache-backup)))
      (should (equal (mapcar (lambda (f) (substring f -15)) (yt-cache--backup-files (yt-cache-file-name)))
                     '("20261103-000000" "20261102-000000"))))))

(ert-deftest yt-cache-round-trip-and-reopen ()
  "Videos survive closing and reopening the cache, as after a restart."
  (yt-test-with-scenario (_ _)
    (let ((videos (yt-cache-test--fixture-videos)))
      (yt-cache-put-feed "subscriptions" videos)
      (yt-cache-close)
      (let ((cached (yt-cache-feed "subscriptions")))
        (should (equal (yt-cache-test--ids cached)
                       '("fakevideo01" "fakevideo02" "fakevideo03" "fakeshort04")))
        (should (equal (mapcar #'yt-video-feed-index cached) '(0 1 2 3)))
        (let ((first (car cached)))
          (should (equal (yt-video-title first) "A normal video with ünïcode"))
          (should (equal (yt-video-channel-id first) "UCfakechannel00000000001"))
          (should (= (yt-video-duration first) 754))
          (should (= (yt-video-timestamp first) 1793480400))
          (should (eq (yt-video-timestamp-approx-p first) t))
          (should (integerp (yt-video-fetched-at first)))
          (should-not (yt-video-watched first)))
        (should (eq (yt-video-live-status (nth 1 cached)) 'is_upcoming))
        (should (yt-video-short-p (nth 3 cached)))))))

(ert-deftest yt-cache-stores-only-allowlisted-fields ()
  "The stored data holds the allowlisted fields and nothing else."
  (yt-test-with-scenario (_ _)
    (let ((video (yt-cache-test--video "a" :watched t :position 12.0
                                       :feed-index 5 :fetched-at 1)))
      (yt-cache-put-videos (list video))
      (let* ((data (caar (sqlite-select (yt-cache-db)
                                        "SELECT data FROM videos WHERE id = 'a'")))
             (keys (map-keys (json-parse-string data :object-type 'alist))))
        (should (seq-every-p (lambda (key) (memq key yt-cache--fields))
                             keys))
        (should-not (yt-cache-test--watched-p "a"))))))

(ert-deftest yt-cache-merge-keeps-local-state-and-exact-times ()
  "A refetch keeps the watched state, position and a more exact time."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-videos (list (yt-cache-test--video "a" :timestamp 1000
                                                     :duration 60)))
    (yt-mark-watched "a")
    (yt-cache-set-position "a" 42.5)
    (let ((merged (car (yt-cache-put-videos
                        (list (yt-cache-test--video "a" :title "New title"
                                                    :timestamp 1200
                                                    :timestamp-approx-p t))))))
      (should (equal (yt-video-title merged) "New title"))
      (should (= (yt-video-timestamp merged) 1000))
      (should-not (yt-video-timestamp-approx-p merged))
      (should (= (yt-video-duration merged) 60)))
    (let ((cached (yt-cache-get "a")))
      (should (yt-video-watched cached))
      (should (= (yt-video-position cached) 42.5))
      (should (= (yt-video-timestamp cached) 1000)))
    ;; An exact time replaces an approximate one.
    (yt-cache-put-videos (list (yt-cache-test--video "b" :timestamp 500
                                                     :timestamp-approx-p t)))
    (yt-cache-put-videos (list (yt-cache-test--video "b" :timestamp 510)))
    (should (= (yt-video-timestamp (yt-cache-get "b")) 510))))

(ert-deftest yt-cache-shorts-inherit-timestamps ()
  "Videos without a time borrow the one of the video before them."
  (yt-test-with-scenario (_ _)
    (let ((feed (yt-cache-put-feed
                 "subscriptions"
                 (list (yt-cache-test--video "s0" :short-p t)
                       (yt-cache-test--video "a" :timestamp 3000 :timestamp-approx-p t)
                       (yt-cache-test--video "s1" :short-p t)
                       (yt-cache-test--video "b" :timestamp 2000 :timestamp-approx-p t)))))
      (should (equal (mapcar #'yt-video-timestamp feed) '(3000 3000 3000 2000)))
      (should (eq (yt-video-timestamp-approx-p (nth 2 feed)) 'inherited))
      ;; The inherited time is kept on a later fetch, even next to other videos.
      (yt-cache-put-feed "subscriptions"
                         (list (yt-cache-test--video "c" :timestamp 9000
                                                     :timestamp-approx-p t)
                               (yt-cache-test--video "s1" :short-p t)))
      (should (= (yt-video-timestamp (yt-cache-get "s1")) 3000)))))

(ert-deftest yt-cache-feed-order-merges-new-videos-on-top ()
  "Fetched videos come first, then the older cached ones in their order."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-feed "subscriptions"
                       (mapcar #'yt-cache-test--video '("a" "b" "c" "d")))
    (should (equal (yt-cache-test--ids
                    (yt-cache-put-feed "subscriptions"
                                       (mapcar #'yt-cache-test--video '("x" "a" "b"))))
                   '("x" "a" "b" "c" "d")))
    (should (equal (yt-cache-test--ids (yt-cache-feed "subscriptions"))
                   '("x" "a" "b" "c" "d")))
    (should (equal (yt-cache-test--ids (yt-cache-feed "subscriptions" 2))
                   '("x" "a")))
    ;; Feeds are separate.
    (should-not (yt-cache-feed "other"))))

(ert-deftest yt-cache-feed-is-capped ()
  "A feed remembers at most `yt-cache-feed-max' videos."
  (yt-test-with-scenario (_ _)
    (let ((yt-cache-feed-max 3))
      (yt-cache-put-feed "subscriptions"
                         (mapcar #'yt-cache-test--video '("a" "b" "c")))
      (yt-cache-put-feed "subscriptions"
                         (mapcar #'yt-cache-test--video '("x" "y")))
      (should (equal (yt-cache-test--ids (yt-cache-feed "subscriptions"))
                     '("x" "y" "a")))
      ;; The dropped videos keep their rows.
      (should (yt-cache-get "c")))))

(ert-deftest yt-cache-mark-watched-runs-hook ()
  "`yt-mark-watched' stores the state and runs the hook once."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-videos (list (yt-cache-test--video "a")))
    (let ((calls nil))
      (add-hook 'yt-watched-changed-functions
                (lambda (ids watched) (push (list ids watched) calls)))
      (yt-mark-watched (list (yt-cache-get "a") "unknown"))
      (should (equal calls '((("a" "unknown") t))))
      (should (yt-cache-test--watched-p "a"))
      (should (yt-cache-test--watched-p "unknown"))
      (should (equal (yt-video-title (yt-cache-get "a")) "Title a"))
      (yt-mark-watched "a" t)
      (should (equal (car calls) '(("a") nil)))
      (should-not (yt-cache-test--watched-p "a")))))

(ert-deftest yt-cache-forget-history ()
  "`yt-forget-history' clears watched marks and positions."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-videos (list (yt-cache-test--video "a")))
    (yt-mark-watched "a")
    (yt-cache-set-position "a" 10.0)
    (let ((calls nil))
      (add-hook 'yt-watched-changed-functions
                (lambda (ids watched) (push (list ids watched) calls)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (yt-forget-history))
      (should (equal calls '((("a") nil)))))
    (should-not (yt-cache-test--watched-p "a"))
    (should-not (yt-video-position (yt-cache-get "a")))))

(ert-deftest yt-cache-meta ()
  "Meta values are stored and replaced."
  (yt-test-with-scenario (_ _)
    (should-not (yt-cache-meta "k"))
    (yt-cache-set-meta "k" 1)
    (yt-cache-set-meta "k" 2)
    (should (= (yt-cache-meta "k") 2))))

(provide 'yt-cache-tests)
;;; yt-cache-tests.el ends here
