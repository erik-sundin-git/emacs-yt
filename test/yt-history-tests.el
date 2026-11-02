;;; yt-history-tests.el --- Tests for the watch history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the list of played videos: the cache table and its
;; migration, recording a video when it starts, the history buffer,
;; and adding played videos to the YouTube history with the fake
;; yt-dlp.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-history)

(defmacro yt-history-test--with (ytdlp &rest body)
  "Run BODY in a scenario with cookies; YTDLP is the fake yt-dlp's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,ytdlp _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let ((now 1793500000)
           (yt-history-changed-hook nil)
           (yt-player-file-started-functions nil)
           (yt-player-youtube-history nil)
           (yt-player--youtube-history-sent (make-hash-table :test #'equal)))
       (let ((yt--now-function (lambda () now)))
         (ignore now)
         (unwind-protect
             (save-window-excursion ,@body)
           (when-let* ((buffer (get-buffer yt-history-buffer)))
             (kill-buffer buffer)))))))

(defun yt-history-test--video (id &rest slots)
  "Return a video with ID and SLOTS."
  (apply #'yt-video--make :id id :title (concat "Title " id) :channel "Fake Channel"
         :url (concat "https://www.youtube.com/watch?v=" id) slots))

(defun yt-history-test--ids ()
  "Return the ids in the history, the most recent first."
  (mapcar (lambda (item) (yt-video-id (car item))) (yt-cache-history)))

(ert-deftest yt-history-cache ()
  "Playing again moves a video to the top; videos can be removed."
  (yt-history-test--with _ytdlp
    (let (changes)
      (add-hook 'yt-history-changed-hook (lambda () (cl-incf changes 1)))
      (setq changes 0)
      (yt-cache-add-history (yt-history-test--video "historyvid1"))
      (setq now (+ now 60))
      (yt-cache-add-history (yt-history-test--video "historyvid2"))
      (setq now (+ now 60))
      (yt-cache-add-history (yt-history-test--video "historyvid1"))
      (should (= changes 3))
      (should (equal (yt-history-test--ids) '("historyvid1" "historyvid2")))
      (should (equal (cdr (car (yt-cache-history))) 1793500120))
      ;; The video was cached along the way.
      (should (equal (yt-video-title (yt-cache-get "historyvid2")) "Title historyvid2"))
      (yt-cache-remove-history '("historyvid1"))
      (should (equal (yt-history-test--ids) '("historyvid2")))
      ;; Forgetting the watch history clears the played videos too.
      (yt-mark-watched (yt-cache-get "historyvid2"))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (yt-forget-history))
      (should-not (yt-cache-history))
      (should-not (yt-video-watched (yt-cache-get "historyvid2"))))))

(ert-deftest yt-history-cache-migrates ()
  "A version 3 cache gets the history table."
  (yt-history-test--with _ytdlp
    (yt-cache-db)
    (sqlite-execute (yt-cache-db) "DROP TABLE history")
    (sqlite-execute (yt-cache-db) "PRAGMA user_version = 3")
    (yt-cache-close)
    (yt-cache-add-history (yt-history-test--video "historyvid1"))
    (should (equal (yt-history-test--ids) '("historyvid1")))
    (should (= (caar (sqlite-select (yt-cache-db) "PRAGMA user_version")) 4))))

(ert-deftest yt-history-started-records-and-sends ()
  "A started video goes into the history, and once to YouTube if asked."
  (yt-history-test--with ytdlp
    (let ((video (yt-history-test--video "historyvid1"))
          started)
      (add-hook 'yt-player-file-started-functions (lambda (v) (push v started)))
      (yt-player-started video)
      (should (equal started (list video)))
      (should (equal (yt-history-test--ids) '("historyvid1")))
      (should (= (yt-test-calls ytdlp) 0))
      (let ((yt-player-youtube-history t))
        (yt-test-step ytdlp 1 :out "")
        (yt-player-started video)
        (yt-test-wait-until (lambda () (not (yt-process-busy-p '(yt-youtube-history . "historyvid1"))))
                            "mark watched")
        (should (equal (last (yt-test-argv ytdlp 1) 6)
                       '("--no-playlist" "--mark-watched" "--simulate"
                         "--ignore-no-formats-error" "--"
                         "https://www.youtube.com/watch?v=historyvid1")))
        ;; Once per session.
        (yt-player-started video)
        (should (= (yt-test-calls ytdlp) 1))
        ;; A refusal is logged, and tried again next time.
        (let ((other (yt-history-test--video "historyvid2")))
          (yt-test-step ytdlp 2 :out "" :err "WARNING: [youtube] historyvid2: Unable to mark watched\n")
          (yt-player-started other)
          (yt-test-wait-until (lambda () (not (gethash "historyvid2" yt-player--youtube-history-sent)))
                              "refusal")
          (should (string-match-p "Could not add “Title historyvid2” to the YouTube history"
                                  (with-current-buffer yt-player-log-buffer (buffer-string))))
          (yt-test-step ytdlp 3 :out "")
          (yt-player-started other)
          (yt-test-wait-until (lambda () (= (yt-test-calls ytdlp) 3)) "second try"))))))

(ert-deftest yt-history-buffer ()
  "The history lists played videos with their progress, and edits the list."
  (yt-history-test--with _ytdlp
    (yt-cache-add-history (yt-history-test--video "historyvid1" :duration 600))
    (setq now (+ now 7200))
    (yt-cache-add-history (yt-history-test--video "historyvid2" :duration 3000))
    (yt-cache-set-position "historyvid2" 754)
    (setq now (+ now 60))
    (yt-cache-add-history (yt-history-test--video "historyvid3"))
    (yt-mark-watched (yt-cache-get "historyvid3"))
    (should (eq (keymap-lookup yt-map "h") #'yt-history))
    (with-current-buffer (yt-history)
      (should (eq major-mode 'yt-history-mode))
      (should (equal (yt-feed--printed-ids) '("historyvid3" "historyvid2" "historyvid1")))
      (let ((text (buffer-string)))
        (should (string-match-p "Channel +Title +Played +Progress +Dur" text))
        (should (string-match-p "Title historyvid3 +now +watched" text))
        (should (string-match-p "Title historyvid2 +1m +12:34/50:00 +50:00" text))
        (should (string-match-p "Title historyvid1 +2h +10:00" text)))
      (should (string-match-p "3 videos played" (yt-history--header-line)))
      ;; The video keys work on the row.
      (goto-char (point-min))
      (forward-line 2)
      (should (equal (yt-video-id (yt-video-at-point)) "historyvid2"))
      (should (eq (keymap-lookup yt-history-mode-map "RET") #'yt-play))
      ;; A new play shows at once.
      (yt-cache-add-history (yt-history-test--video "historyvid4"))
      (should (equal (car (yt-feed--printed-ids)) "historyvid4"))
      (yt-history-filter "vid2")
      (should (equal (yt-feed--printed-ids) '("historyvid2")))
      (yt-history-filter "")
      (goto-char (point-min))
      (while (not (equal (tabulated-list-get-id) "historyvid1"))
        (forward-line 1))
      (call-interactively #'yt-history-remove)
      (should (equal (yt-feed--printed-ids) '("historyvid4" "historyvid3" "historyvid2")))
      ;; Removing keeps the watched mark.
      (should (yt-video-watched (yt-cache-get "historyvid3")))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (yt-history-clear))
      (should-not (yt-feed--printed-ids))
      (should (string-match-p "No videos played yet" (buffer-string)))
      (should (yt-video-watched (yt-cache-get "historyvid3"))))))

(provide 'yt-history-tests)
;;; yt-history-tests.el ends here
