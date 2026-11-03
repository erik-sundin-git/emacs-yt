;;; yt-feed-tests.el --- Tests for yt-feed.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the feed buffer: filters as pure functions, rendering,
;; refreshing through the fake yt-dlp (cache first, incremental stop,
;; errors, first-run sign-in), point restore, and watched marks.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-feed)

(defconst yt-feed-test--now 1793500000
  "The fixed current time of the feed tests: 2026-11-01 03:46 UTC.")

(defun yt-feed-test--entry (id &optional title)
  "Return a feed NDJSON line for a normal video ID with TITLE."
  (concat (json-serialize
           (list :_type "url" :id id
                 :url (concat "https://www.youtube.com/watch?v=" id)
                 :title (or title (concat "Video " id))
                 :channel "Fake Channel Three"
                 :channel_id "UCfakechannel00000000003"
                 :duration 60 :timestamp (- yt-feed-test--now 600)))
          "\n"))

(defmacro yt-feed-test--with-feed (ytdlp &rest body)
  "Run BODY in a scenario with login cookies and a fixed clock.
YTDLP is bound to the scenario directory of the fake yt-dlp."
  (declare (indent 1))
  `(yt-test-with-scenario (,ytdlp _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let ((yt--now-function (lambda () yt-feed-test--now))
           (yt-feed-stop-after-known 10)
           (yt-feed-refresh-interval 900)
           (yt-feed-hide-watched nil)
           (yt-feed-hide-shorts nil)
           (yt-feed-hide-upcoming nil))
       (save-window-excursion
         ,@body))))

(defun yt-feed-test--wait (buffer)
  "Wait until the feed BUFFER is not refreshing, and return it."
  (yt-test-wait-until
   (lambda () (not (buffer-local-value 'yt-feed--refreshing buffer)))
   "feed refresh")
  buffer)

(defun yt-feed-test--open ()
  "Run \\[yt] and wait for its refresh; return the feed buffer."
  (yt-feed-test--wait (yt)))

(defun yt-feed-test--last-message ()
  "Return the last line logged in *Messages*."
  (with-current-buffer (messages-buffer)
    (save-excursion
      (goto-char (point-max))
      (skip-chars-backward "\n")
      (buffer-substring-no-properties (line-beginning-position) (point)))))

(defun yt-feed-test--ids (&optional buffer)
  "Return the ids of the rows printed in BUFFER, in order."
  (with-current-buffer (or buffer (current-buffer))
    (yt-feed--printed-ids)))

(defun yt-feed-test--goto (id)
  "Move point to the row of ID."
  (goto-char (gethash id (yt-feed--row-positions))))

(defconst yt-feed-test--fixture-ids
  '("fakevideo01" "fakevideo02" "fakevideo03" "fakeshort04")
  "The ids of the feed fixture, in order.")

;;;; Pure functions

(ert-deftest yt-feed-parse-query ()
  "Queries split into lower-cased terms of three kinds."
  (should (equal (yt-feed--parse-query "Emacs  @Prot !Live @ !")
                 '((any . "emacs") (channel . "prot") (not . "live"))))
  (should-not (yt-feed--parse-query "  "))
  (should-not (yt-feed--parse-query nil)))

(ert-deftest yt-feed-match-p ()
  "Filters match on title, channel, exclusions and hidden kinds."
  (let ((video (yt-video--make :id "a" :title "Org mode tips" :channel "Prot"
                               :channel-id "UC1"))
        (short (yt-video--make :id "s" :title "Quick" :short-p t))
        (live (yt-video--make :id "l" :title "Stream" :live-status 'is_upcoming)))
    (cl-flet ((match (query &optional filter video*)
                (yt-feed--match-p (or video* video) (yt-feed--parse-query query)
                                  filter)))
      (should (match "org TIPS"))
      (should (match "prot"))
      (should (match "@prot org"))
      (should-not (match "@org"))
      (should-not (match "org !tips"))
      (should-not (match "org vim"))
      (should (match nil '(:channel ("UC1" . "Prot"))))
      (should-not (match nil '(:channel ("UC2" . "Other"))))
      (should (match nil '(:channel (nil . "Prot"))))
      (should-not (match nil '(:hide-shorts t) short))
      (should (match nil '(:hide-upcoming t) short))
      (should-not (match nil '(:hide-upcoming t) live))
      (setf (yt-video-watched video) t)
      (should-not (match nil '(:hide-watched t))))))

(ert-deftest yt-feed-find-row-nearest ()
  "A vanished row is replaced by the next surviving one, else the previous."
  (let ((rows (make-hash-table :test #'equal)))
    (puthash "a" 1 rows)
    (puthash "d" 4 rows)
    (should (= (yt-feed--find-row "a" '("a" "b" "c" "d") rows) 1))
    (should (= (yt-feed--find-row "b" '("a" "b" "c" "d") rows) 4))
    (should (= (yt-feed--find-row "e" '("a" "d" "e") rows) 4))
    (should-not (yt-feed--find-row "x" nil (make-hash-table)))))

;;;; Rendering and refreshing

(ert-deftest yt-feed-first-refresh-renders-feed ()
  "\\[yt] fetches the feed and shows it in feed order with its columns."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :mode "stream" :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (should (equal (buffer-name) "*yt: Subscriptions*"))
      (should (eq major-mode 'yt-feed-mode))
      (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
      (let ((text (buffer-string)))
        (should (string-match-p "Channel +Title +Age +Dur" text))
        (should (string-match-p "● Fake Channel One +A normal video with ünïcode +5h +12:34"
                                text))
        (should (string-match-p "Fake Channel Two +\\[SOON\\] An upcoming premiere +SOON"
                                text))
        (should (string-match-p "Fake Channel One +A past live stream +1d +1:30:32" text))
        ;; The Short has no time of its own and inherits the one before it.
        (should (string-match-p "\\[S\\] A short +1d" text)))
      (let ((header (yt-feed--header-line)))
        (should (string-match-p "updated just now" header))
        (should (string-match-p "4 videos" header)))
      (should (= (yt-cache-meta "refreshed:subscriptions") yt-feed-test--now))
      (should (member ":ytsubs" (yt-test-argv ytdlp 1))))))

(ert-deftest yt-feed-shows-cache-at-once-after-restart ()
  "After a restart the cached feed shows at once, and \\[yt] does not block."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (kill-buffer (yt-feed-test--open))
    ;; Simulate a restart, long enough ago for the feed to be stale.
    (yt-cache-close)
    (setq yt-feed--fully-refreshed nil)
    (yt-test-step ytdlp 2 :mode "hang")
    (let* ((yt--now-function (lambda () (+ yt-feed-test--now 3600)))
           (start (float-time))
           (buffer (yt))
           (elapsed (- (float-time) start)))
      (with-current-buffer buffer
        (should (< elapsed 0.2))
        (should yt-feed--refreshing)
        (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
        (should (string-match-p "updated 1h ago"
                                (yt-feed--header-line)))
        (should (equal (eval (cadr mode-line-process) t) " Refreshing…")))
      (yt-test-wait-until (lambda () (= (yt-test-calls ytdlp) 2)) "second fetch")
      ;; Killing the buffer cancels the hanging refresh.
      (kill-buffer buffer)
      (yt-test-wait-until (lambda () (not (yt-process-busy-p '(yt-feed . subscriptions))))
                          "cancelled refresh"))))

(ert-deftest yt-feed-fresh-feed-is-not-refetched ()
  "\\[yt] within `yt-feed-refresh-interval' shows the feed without fetching."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-feed-test--open)
    (yt-feed-test--open)
    (should (= (yt-test-calls ytdlp) 1))))

(ert-deftest yt-feed-refresh-keeps-point-on-video ()
  "A refresh that adds videos on top keeps each window on the same video."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :out (concat (yt-feed-test--entry "newvideo01")
                                       (yt-feed-test--entry "newvideo02")
                                       (yt-test-fixture-string "feed.ndjson")))
    (let ((buffer (yt-feed-test--open))
          (window (selected-window)))
      (with-current-buffer buffer
        (set-window-buffer window buffer)
        (yt-feed-test--goto "fakevideo03")
        (set-window-point window (point))
        (yt-feed-refresh)
        (yt-feed-test--wait buffer)
        (should (equal (yt-feed-test--ids)
                       (append '("newvideo01" "newvideo02") yt-feed-test--fixture-ids)))
        (should (equal (tabulated-list-get-id) "fakevideo03"))
        (should (equal (save-excursion (goto-char (window-point window))
                                       (tabulated-list-get-id))
                       "fakevideo03"))
        (should (equal (yt-feed-test--last-message) "yt: 2 new videos"))))))

(ert-deftest yt-feed-refresh-stops-after-known-videos ()
  "A later refresh stops after `yt-feed-stop-after-known' cached videos."
  (yt-feed-test--with-feed ytdlp
    (let ((yt-feed-stop-after-known 2))
      ;; The first refresh of a session reads everything.
      (yt-test-step ytdlp 1 :mode "stream"
                    :out (yt-test-fixture-string "feed.ndjson"))
      (with-current-buffer (yt-feed-test--open)
        (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
        (yt-test-step ytdlp 2 :mode "stream-hang"
                      :out (concat (yt-feed-test--entry "newvideo01")
                                   (yt-test-fixture-string "feed.ndjson")))
        (yt-feed-refresh)
        (yt-feed-test--wait (current-buffer))
        (should (equal (yt-feed-test--ids)
                       (cons "newvideo01" yt-feed-test--fixture-ids)))
        (should-not yt-feed--error)))))

(ert-deftest yt-feed-refresh-ends-when-showing-fails ()
  "An error while showing a refresh ends it, so that \\[yt-feed-refresh] works again."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer
        (cl-letf (((symbol-function 'yt-cache-put-feed)
                   (lambda (&rest _) (error "Database is locked"))))
          (yt-feed-test--open))
      (should-not yt-feed--refreshing)
      (should (string-match-p "Refreshing failed: Database is locked" yt-feed--error))
      (yt-feed-refresh)
      (yt-feed-test--wait (current-buffer))
      (should (= (yt-test-calls ytdlp) 2))
      (should-not yt-feed--error)
      (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids)))))

(ert-deftest yt-feed-refresh-keeps-partial-results ()
  "Videos received before a refresh timed out are kept."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (yt-test-step ytdlp 2 :mode "stream-hang"
                    :out (concat (yt-feed-test--entry "newvideo01")
                                 (yt-feed-test--entry "newvideo02")))
      (let ((yt-process-timeout 1))
        (yt-feed-refresh)
        (yt-feed-test--wait (current-buffer)))
      (should (equal (seq-take (yt-feed-test--ids) 2) '("newvideo01" "newvideo02")))
      (should (equal (mapcar #'yt-video-id (seq-take (yt-cache-feed "subscriptions") 2))
                     '("newvideo01" "newvideo02")))
      (should yt-feed--error))))

(ert-deftest yt-feed-full-refresh-cancels-running-one ()
  "\\[yt-feed-refresh-all] cancels a running refresh and fetches everything."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (yt-test-step ytdlp 2 :mode "hang")
      (yt-test-step ytdlp 3 :out (concat (yt-feed-test--entry "newvideo01")
                                         (yt-test-fixture-string "feed.ndjson")))
      (yt-feed-refresh)
      (yt-test-wait-until (lambda () (= (yt-test-calls ytdlp) 2)) "hanging fetch")
      (yt-feed-refresh)
      (should (string-match-p "already refreshing" (yt-feed-test--last-message)))
      (yt-feed-refresh-all)
      (yt-feed-test--wait (current-buffer))
      (should (equal (car (yt-feed-test--ids)) "newvideo01"))
      (should-not yt-feed--error))))

(ert-deftest yt-feed-failed-refresh-keeps-cached-rows ()
  "A failed refresh leaves the rows and shows the problem in the header."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (yt-test-step ytdlp 2 :exit 1
                  :err "ERROR: [youtube:tab] ytsubs: <urlopen error [Errno -3] Temporary failure in name resolution>\n")
    (with-current-buffer (yt-feed-test--open)
      (yt-feed-refresh)
      (yt-feed-test--wait (current-buffer))
      (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
      (should (string-match-p "Offline: showing the cached feed"
                              (yt-feed--header-line))))))

(ert-deftest yt-feed-first-run-signs-in ()
  "Without cookies, \\[yt] exports them from the chosen profile, then fetches."
  (yt-test-with-scenario (ytdlp export)
    (let ((yt--now-function (lambda () yt-feed-test--now)))
      (yt-state-put 'cookie-profile "Profile 1")
      (yt-test-step export 1 :out (yt-test-export-summary)
                    :cookies (yt-test-cookies))
      (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
      (save-window-excursion
        (let ((buffer (yt)))
          (with-current-buffer buffer
            (should (string-match-p "Signing in via Chromium profile"
                                    (buffer-string)))
            (yt-feed-test--wait buffer)
            (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
            (should (= (yt-test-calls export) 1))
            (should (file-exists-p (yt-auth-cookie-file)))))))))

(ert-deftest yt-feed-sign-in-failure-is-shown ()
  "When signing in fails, the empty feed explains why."
  (yt-test-with-scenario (_ytdlp export)
    (yt-state-put 'cookie-profile "Profile 1")
    (yt-test-step export 1 :exit 2
                  :out (yt-test-export-summary :ok :false :has_login_info :false
                                               :count 0))
    (save-window-excursion
      (with-current-buffer (yt-feed-test--wait (yt))
        (should (string-match-p "not signed in to YouTube" (buffer-string)))))))

;;;; Filters and marks in the buffer

(ert-deftest yt-feed-filters-hide-rows ()
  "Filters and toggles change the rows without refetching."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (yt-feed-filter "live")
      (should (equal (yt-feed-test--ids) '("fakevideo03")))
      (should (string-match-p "filter “live”.*1 of 4 videos"
                              (yt-feed--header-line)))
      (yt-feed-clear-filters)
      (yt-feed-toggle-hide-shorts)
      (yt-feed-toggle-hide-upcoming)
      (should (equal (yt-feed-test--ids) '("fakevideo01" "fakevideo03")))
      (yt-feed-toggle-hide-shorts)
      (yt-feed-toggle-hide-upcoming)
      (yt-feed-filter-channel '("UCfakechannel00000000002" . "Fake Channel Two"))
      (should (equal (yt-feed-test--ids) '("fakevideo02")))
      (yt-feed-filter "nothing-matches")
      (should (string-match-p
               (concat "All 4 videos are hidden by the filter “nothing-matches” (C clears it); "
                       "the channel filter Fake Channel Two (C clears it)\\.")
               (buffer-string)))
      (yt-feed-clear-filters)
      (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
      (should (= (yt-test-calls ytdlp) 1)))))

(ert-deftest yt-feed-empty-messages ()
  "An empty feed says which filters hide it and the keys that show it."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (yt-mark-watched (mapcar #'yt-cache-get yt-feed-test--fixture-ids))
      (yt-feed-toggle-hide-watched)
      (should-not (yt-feed-test--ids))
      (let ((text (buffer-string)))
        (should (string-match-p
                 "All 4 videos are hidden by hiding watched videos (t w shows them)\\." text))
        ;; C would not help here, so it is not offered.
        (should-not (string-match-p "C clears" text)))))
  (with-temp-buffer
    (yt-feed-mode)
    (setq yt-feed--source '(search "no such thing"))
    (yt-feed--redisplay)
    (should (string-match-p "No results for “no such thing”\\." (buffer-string)))))

(ert-deftest yt-feed-live-filter-restores-on-quit ()
  "Quitting the query prompt restores the filter from before it."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (yt-feed-filter "video")
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _)
                   ;; What the debounced live update does while typing.
                   (yt-feed--set-filter :query "short")
                   (should (equal (yt-feed-test--ids) '("fakeshort04")))
                   (signal 'quit nil))))
        (should (eq (condition-case nil
                        (progn (yt-feed--read-query) 'returned)
                      (quit 'quit))
                    'quit)))
      (should (equal (plist-get yt-feed--filter :query) "video"))
      (should (equal (yt-feed-test--ids) '("fakevideo01"))))))

(ert-deftest yt-feed-watched-mark-redraws-one-row ()
  "Marking a video watched redraws its row only, and \\`w' moves on."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (let ((prints 0))
        (cl-letf* ((print (symbol-function 'tabulated-list-print))
                   ((symbol-function 'tabulated-list-print)
                    (lambda (&rest args) (cl-incf prints) (apply print args))))
          (yt-feed-test--goto "fakevideo01")
          (yt-mark-video-watched)
          (should (= prints 0)))
        (should (equal (tabulated-list-get-id) "fakevideo02"))
        (should (yt-video-watched (yt-cache-get "fakevideo01")))
        (yt-feed-test--goto "fakevideo01")
        (should-not (looking-at-p "●"))
        (should (eq (get-text-property (prop-match-beginning
                                        (text-property-search-forward
                                         'tabulated-list-column-name "Title" t))
                                       'face)
                    'yt-feed-title-watched))
        (should (equal (yt-feed-test--ids) yt-feed-test--fixture-ids))
        ;; Hiding watched videos removes the row.
        (yt-feed-toggle-hide-watched)
        (should (equal (yt-feed-test--ids) (cdr yt-feed-test--fixture-ids)))
        (yt-feed-toggle-hide-watched)
        (yt-feed-test--goto "fakevideo01")
        (yt-mark-video-unwatched)
        (yt-feed-test--goto "fakevideo01")
        (should (looking-at-p "●"))))))

(ert-deftest yt-feed-marks-region ()
  "With an active region, \\`w' marks every video in it."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (let ((transient-mark-mode t))
        (yt-feed-test--goto "fakevideo02")
        (push-mark (point) t t)
        (yt-feed-test--goto "fakeshort04")
        (yt-mark-video-watched)
        (should-not (region-active-p))
        (should (equal (seq-filter (lambda (id) (yt-video-watched (yt-cache-get id)))
                                   yt-feed-test--fixture-ids)
                       '("fakevideo02" "fakevideo03")))))))

(ert-deftest yt-feed-copy-url ()
  "\\`y' and \\`Y' copy the URL, and the title with the URL."
  (yt-feed-test--with-feed ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt-feed-test--open)
      (let ((kill-ring nil))
        (yt-feed-test--goto "fakeshort04")
        (yt-copy-video-url)
        (should (equal (car kill-ring) "https://www.youtube.com/shorts/fakeshort04"))
        (yt-copy-video-title-and-url)
        (should (equal (car kill-ring)
                       "A short — https://www.youtube.com/shorts/fakeshort04"))))))

(ert-deftest yt-feed-keys ()
  "The feed keys are bound as documented."
  (should (eq (keymap-lookup yt-feed-mode-map "g") #'yt-feed-refresh))
  (should (eq (keymap-lookup yt-feed-mode-map "G") #'yt-feed-refresh-all))
  (should (eq (keymap-lookup yt-feed-mode-map "w") #'yt-mark-video-watched))
  (should (eq (keymap-lookup yt-feed-mode-map "t s") #'yt-feed-toggle-hide-shorts))
  (should (eq (keymap-lookup yt-feed-mode-map "/") #'yt-feed-filter))
  (should (eq (keymap-lookup yt-feed-mode-map "n") #'next-line)))

(provide 'yt-feed-tests)
;;; yt-feed-tests.el ends here
