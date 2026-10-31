;;; yt-video-tests.el --- Tests for yt-video.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for building `yt-video' records from yt-dlp JSON and for
;; formatting ages and durations.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-video)

(defun yt-video-test--feed ()
  "Return the entries of the feed fixture as plists."
  (mapcar #'yt-process-parse-json
          (split-string (yt-test-fixture-string "feed.ndjson") "\n" t)))

(ert-deftest yt-video-from-json-normal-entry ()
  "A normal flat feed entry maps onto every field."
  (let ((video (yt-video-from-json (car (yt-video-test--feed)) t)))
    (should (equal (yt-video-id video) "fakevideo01"))
    (should (equal (yt-video-title video) "A normal video with ünïcode"))
    (should (equal (yt-video-channel video) "Fake Channel One"))
    (should (equal (yt-video-channel-id video) "UCfakechannel00000000001"))
    (should (equal (yt-video-channel-url video)
                   "https://www.youtube.com/channel/UCfakechannel00000000001"))
    (should (= (yt-video-duration video) 754))
    (should (= (yt-video-timestamp video) 1793480400))
    (should (yt-video-timestamp-approx-p video))
    (should-not (yt-video-views video))
    (should-not (yt-video-live-status video))
    (should (equal (yt-video-thumbnail video)
                   "https://i.ytimg.com/vi/fakevideo01/maxresdefault.jpg"))
    (should (equal (yt-video-url video)
                   "https://www.youtube.com/watch?v=fakevideo01"))
    (should-not (yt-video-short-p video))))

(ert-deftest yt-video-from-json-special-entries ()
  "Upcoming, past live and Shorts entries, which lack many fields."
  (pcase-let ((`(,_ ,upcoming ,live ,short)
               (mapcar (lambda (e) (yt-video-from-json e t)) (yt-video-test--feed))))
    (should (eq (yt-video-live-status upcoming) 'is_upcoming))
    (should-not (yt-video-duration upcoming))
    (should-not (yt-video-timestamp upcoming))
    (should-not (yt-video-timestamp-approx-p upcoming))
    (should (eq (yt-video-live-status live) 'was_live))
    (should (yt-video-short-p short))
    (should-not (yt-video-channel short))
    (should-not (yt-video-duration short))
    (should (equal (yt-video-url short)
                   "https://www.youtube.com/shorts/fakeshort04"))))

(ert-deftest yt-video-from-json-fallbacks ()
  "Missing fields fall back sensibly, and stream URLs are not page URLs."
  (let ((video (yt-video-from-json
                '(:id "abc" :uploader "Uploader" :uploader_url "https://u"
                  :upload_date "20261031"
                  :url "https://rr1.googlevideo.com/videoplayback?x"
                  :webpage_url "https://www.youtube.com/watch?v=abc"
                  :thumbnail "https://t" :view_count 42 :title ""))))
    (should (equal (yt-video-channel video) "Uploader"))
    (should (equal (yt-video-channel-url video) "https://u"))
    (should (equal (format-time-string "%F %T" (yt-video-timestamp video) t)
                   "2026-10-31 00:00:00"))
    (should-not (yt-video-timestamp-approx-p video))
    (should (equal (yt-video-url video) "https://www.youtube.com/watch?v=abc"))
    (should (equal (yt-video-thumbnail video) "https://t"))
    (should (= (yt-video-views video) 42))
    (should-not (yt-video-title video)))
  (should (equal (yt-video-url (yt-video-from-json '(:id "xyz")))
                 "https://www.youtube.com/watch?v=xyz"))
  (should-not (yt-video-from-json '(:title "no id")))
  (should-not (yt-video-from-json '(:id ""))))

(ert-deftest yt-video-format-age ()
  "Ages use the largest whole unit; future times say \"in\"."
  (let ((now 1800000000))
    (pcase-dolist (`(,delta . ,expected)
                   '((0 . "now") (59 . "now") (-30 . "soon") (120 . "2m")
                     (7199 . "1h") (7200 . "2h") (172800 . "2d")
                     (864000 . "1w") (3456000 . "1mo") (34560000 . "1y")
                     (-7200 . "in2h") (-172800 . "in2d")))
      (should (equal (yt-video-format-age (- now delta) now) expected))))
  (should (equal (yt-video-format-age nil) ""))
  (let ((yt--now-function (lambda () 1800000000.5)))
    (should (equal (yt-video-format-age 1799996400) "1h"))))

(ert-deftest yt-video-format-duration ()
  "Durations are M:SS or H:MM:SS."
  (should (equal (yt-video-format-duration nil) ""))
  (should (equal (yt-video-format-duration 0) "0:00"))
  (should (equal (yt-video-format-duration 59.9) "0:59"))
  (should (equal (yt-video-format-duration 65) "1:05"))
  (should (equal (yt-video-format-duration 3723) "1:02:03")))

(provide 'yt-video-tests)
;;; yt-video-tests.el ends here
