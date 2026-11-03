;;; yt-org-tests.el --- Tests for org links to YouTube videos -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for storing org links to the video at point.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-org)
(require 'yt-url)

(defun yt-org-test--video ()
  "Return a video to store links to."
  (yt-video--make :id "abcdefghijk" :title "A talk" :channel "Fake Channel One"
                  :url "https://www.youtube.com/watch?v=abcdefghijk"))

(defmacro yt-org-test--at-video (video &rest body)
  "Run BODY in a buffer whose video at point is VIDEO."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((video ,video))
       (setq-local yt-video-at-point-function (lambda () video)))
     ,@body))

(ert-deftest yt-org-store-link-to-video ()
  "`org-store-link' in a yt buffer stores a plain YouTube link."
  (yt-org-test--at-video (yt-org-test--video)
    (let ((org-stored-links nil))
      (should (member #'yt-org-store-link (org-store-link-functions)))
      (org-store-link nil t)
      (should (equal (car org-stored-links)
                     '("https://www.youtube.com/watch?v=abcdefghijk"
                       "A talk — Fake Channel One"))))))

(ert-deftest yt-org-store-link-at-position ()
  "A link to the video playing starts where it is, and plays from there."
  (let ((video (yt-org-test--video)))
    (yt-org-test--at-video video
      (cl-letf (((symbol-function 'yt-player-now-playing)
                 (lambda () (cons (yt-org-test--video) 61.7))))
        (should (yt-org-store-link))
        (let ((link (plist-get org-store-link-plist :link)))
          (should (equal link "https://www.youtube.com/watch?v=abcdefghijk&t=61"))
          (should (equal (plist-get (cdr (yt-url-parse link)) :start) 61))))
      ;; Another video playing, or the first second: no time.
      (cl-letf (((symbol-function 'yt-player-now-playing)
                 (lambda () (cons (yt-video--make :id "otherid0000") 61.7))))
        (yt-org-store-link)
        (should (equal (plist-get org-store-link-plist :link)
                       "https://www.youtube.com/watch?v=abcdefghijk")))
      (cl-letf (((symbol-function 'yt-player-now-playing)
                 (lambda () (cons video 0.4))))
        (yt-org-store-link)
        (should (equal (plist-get org-store-link-plist :link)
                       "https://www.youtube.com/watch?v=abcdefghijk"))))))

(ert-deftest yt-org-store-link-elsewhere ()
  "Outside yt buffers, and for a video without a channel, the link is plain."
  (with-temp-buffer
    (should-not (yt-org-store-link)))
  (yt-org-test--at-video (yt-video--make :id "abcdefghijk")
    (yt-org-store-link)
    (should (equal (plist-get org-store-link-plist :description) "abcdefghijk"))))

(provide 'yt-org-tests)
;;; yt-org-tests.el ends here
