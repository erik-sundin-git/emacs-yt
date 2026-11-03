;;; yt-snapshot-tests.el --- How yt's buffers look -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each yt list buffer, with a fixed clock and window width, compared
;; with its snapshot in test/fixtures/snapshots.  They pin down the
;; columns, the header lines and the empty messages, so that moving
;; code between the list modes changes nothing unnoticed.  Regenerate
;; with YT_UPDATE_SNAPSHOTS=1 make test SELECTOR='"yt-snapshot-"', then
;; read the git diff.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-channels)
(require 'yt-playlists)
(require 'yt-history)

(defconst yt-snapshot-test--now 1793500000
  "The fixed clock of the snapshots.")

(defmacro yt-snapshot-test--with (ytdlp &rest body)
  "Run BODY in a scenario with cookies, a fixed clock and 100 columns.
YTDLP is bound to the fake yt-dlp's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,ytdlp _export)
     (ignore _export)
     (yt-test-install-cookies)
     (cl-letf (((symbol-function 'yt-list--window-width) (lambda () 100)))
       (let ((yt--now-function (lambda () yt-snapshot-test--now))
             (yt-feed-refresh-interval 900)
             (yt-channels-refresh-interval 86400))
         (save-window-excursion
           ,@body)))))

(defun yt-snapshot-test--channels ()
  "Cache two subscribed channels."
  (yt-cache-put-channels
   (list (list :id "UCfakechannel00000000001" :name "Fake Channel One"
               :url "https://www.youtube.com/channel/UCfakechannel00000000001")
         (list :id "UCfakechannel00000000002" :name "Fake Channel Two"
               :url "https://www.youtube.com/channel/UCfakechannel00000000002")))
  (yt-cache-set-meta "refreshed:channels" yt-snapshot-test--now))

(ert-deftest yt-snapshot-feed ()
  "The subscription feed, then hidden by a filter, then empty."
  (yt-snapshot-test--with ytdlp
    (yt-snapshot-test--channels)
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "feed.ndjson"))
    (with-current-buffer (yt)
      (yt-test-wait-until (lambda () (not yt-feed--refreshing)) "feed")
      (yt-mark-watched "fakevideo03")
      (yt-test-snapshot "feed")
      (yt-feed-toggle-hide-watched)
      (yt-feed-filter "nothing-matches")
      (yt-test-snapshot "feed-hidden"))
    (with-temp-buffer
      (yt-feed-mode)
      (setq yt-feed--source '(search "no such thing"))
      (yt-feed--redisplay)
      (yt-test-snapshot "feed-no-results"))))

(ert-deftest yt-snapshot-channels ()
  "The channels list, and its filtered state."
  (yt-snapshot-test--with _ytdlp
    (yt-snapshot-test--channels)
    (with-current-buffer (yt-channels)
      (yt-test-snapshot "channels")
      (yt-channels-filter "two")
      (yt-test-snapshot "channels-filtered"))))

(ert-deftest yt-snapshot-playlists ()
  "The saved playlists, then none."
  (yt-snapshot-test--with _ytdlp
    (yt-cache-save-playlist '(:id "PLfakeplaylist000000000001" :title "Fake series one"
                                  :channel "Fake Channel Two"
                                  :url "https://www.youtube.com/playlist?list=PLfakeplaylist000000000001"))
    (with-current-buffer (yt-saved-playlists)
      (yt-test-snapshot "playlists-saved")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (goto-char (point-min))
        (while (not (tabulated-list-get-id)) (forward-line 1))
        (call-interactively #'yt-playlists-forget))
      (yt-test-snapshot "playlists-none"))))

(ert-deftest yt-snapshot-history ()
  "The history, then empty."
  (yt-snapshot-test--with _ytdlp
    (yt-cache-add-history (yt-video--make :id "historyvid1" :title "Title historyvid1"
                                          :channel "Fake Channel" :duration 600))
    (yt-cache-set-position "historyvid1" 125)
    (with-current-buffer (yt-history)
      (yt-test-snapshot "history")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'y-or-n-p) (lambda (_) t)))
        (yt-history-clear))
      (yt-test-snapshot "history-empty"))))

(ert-deftest yt-snapshot-queue ()
  "The player's queue."
  (yt-snapshot-test--with _ytdlp
    (with-temp-buffer
      (yt-playlist-mode)
      (setq yt-playlist--items
            (list (list :index 0 :id 1 :current t :title "Title queued01"
                        :video (yt-video--make :id "queued01aaa" :channel "Fake Channel One"
                                               :duration 754))
                  (list :index 1 :id 2 :title "Title queued02"
                        :video (yt-video--make :id "queued02aaa" :channel "Fake Channel Two"
                                               :duration 61))))
      (tabulated-list-print)
      (yt-test-snapshot "queue"))))

(provide 'yt-snapshot-tests)
;;; yt-snapshot-tests.el ends here
