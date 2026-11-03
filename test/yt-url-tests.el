;;; yt-url-tests.el --- Tests for opening YouTube links in yt -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for parsing YouTube links strictly, `yt-url-handler-mode', and
;; yt's own "open in browser" commands bypassing it.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-url)
(require 'browse-url)

(ert-deftest yt-url-parse-accepts-youtube-links ()
  "Videos, playlists and channels are recognized and rebuilt canonically."
  (pcase-dolist (`(,link ,expected)
                 '(("https://www.youtube.com/watch?v=abcdefghijk"
                    (video :id "abcdefghijk" :url "https://www.youtube.com/watch?v=abcdefghijk" :start nil))
                   ("https://youtu.be/abcdefghijk?si=trackme&t=90"
                    (video :id "abcdefghijk" :url "https://www.youtube.com/watch?v=abcdefghijk" :start 90))
                   ("https://m.youtube.com/watch?feature=share&v=abcdefghijk&t=1h2m3s"
                    (video :id "abcdefghijk" :url "https://www.youtube.com/watch?v=abcdefghijk" :start 3723))
                   ("https://www.youtube.com/shorts/abcdefghijk"
                    (video :id "abcdefghijk" :url "https://www.youtube.com/watch?v=abcdefghijk" :start nil))
                   ("http://youtube.com/live/abcdefghijk?start=30"
                    (video :id "abcdefghijk" :url "https://www.youtube.com/watch?v=abcdefghijk" :start 30))
                   ("https://www.youtube.com/playlist?list=PLfake_list-1"
                    (playlist :id "PLfake_list-1" :url "https://www.youtube.com/playlist?list=PLfake_list-1"))
                   ("https://www.youtube.com/channel/UCfakechannel00000000002/videos"
                    (channel :id "UCfakechannel00000000002"
                             :url "https://www.youtube.com/channel/UCfakechannel00000000002"))
                   ("https://www.youtube.com/@Fake.Channel_2"
                    (channel :id nil :url "https://www.youtube.com/@Fake.Channel_2"))))
    (should (equal (cons link (yt-url-parse link)) (cons link expected)))))

(ert-deftest yt-url-parse-rejects-everything-else ()
  "Other hosts, user names, ports, bad ids and other schemes are refused."
  (dolist (link '("https://example.com/watch?v=abcdefghijk"
                  "https://youtube.com.example.com/watch?v=abcdefghijk"
                  "https://user@www.youtube.com/watch?v=abcdefghijk"
                  "https://www.youtube.com:8080/watch?v=abcdefghijk"
                  "https://www.youtube.com/watch?v=short"
                  "https://www.youtube.com/watch?v=abcdefghij%27"
                  "file:///www.youtube.com/watch?v=abcdefghijk"
                  "https://www.youtube.com/feed/history"
                  "https://www.youtube.com/playlist?list=bad%20id"
                  "--renderer-cmd-prefix=evil"
                  "not a url"))
    (should (equal (list link nil) (list link (yt-url-parse link)))))
  ;; Absurd start times are dropped.
  (should-not (plist-get (cdr (yt-url-parse "https://youtu.be/abcdefghijk?t=9999999")) :start))
  (should (equal (mapcar #'yt-url-parse-time '("90" "90s" "2m" "1h" "1m30s" "" "x" "-5"))
                 '(90 90 120 3600 90 nil nil nil))))

(ert-deftest yt-url-handler-mode-opens-links-in-yt ()
  "With the mode on, browse-url plays videos and opens channels in yt."
  (yt-test-with-scenario (_ _)
    (let* ((calls nil)
           (browse-url-handlers nil)
           (browse-url-browser-function (lambda (url &rest _) (push (list 'browser url) calls))))
      (cl-letf (((symbol-function 'yt-play-at)
                 (lambda (video start &rest _) (push (list 'play-at (yt-video-id video) start) calls)))
                ((symbol-function 'yt-play)
                 (lambda (video &rest _) (push (list 'play (yt-video-id video)) calls)))
                ((symbol-function 'yt-feed-channel)
                 (lambda (id url name) (push (list 'channel id url name) calls))))
        (unwind-protect
            (progn
              (yt-url-handler-mode 1)
              (should (= (length browse-url-handlers) 1))
              (browse-url "https://youtu.be/abcdefghijk?t=1m30s")
              (browse-url "https://www.youtube.com/watch?v=bcdefghijkl")
              (browse-url "https://www.youtube.com/@fake")
              (browse-url "https://example.com/page")
              ;; With a prefix argument, the browser gets it.
              (let ((current-prefix-arg '(4)))
                (browse-url "https://www.youtube.com/watch?v=cdefghijklm"))
              ;; yt's own "open in browser" never loops back into yt.
              (yt-browse-url "https://www.youtube.com/watch?v=defghijklmn")
              (should-error (yt-browse-url "https://example.com/x") :type 'user-error)
              ;; Turning it on twice adds one handler.
              (yt-url-handler-mode 1)
              (should (= (length browse-url-handlers) 1)))
          (yt-url-handler-mode -1))
        (should-not browse-url-handlers)
        (should (equal (nreverse calls)
                       '((play-at "abcdefghijk" 90)
                         (play "bcdefghijkl")
                         (channel "https://www.youtube.com/@fake" "https://www.youtube.com/@fake" "@fake")
                         (browser "https://example.com/page")
                         (browser "https://www.youtube.com/watch?v=cdefghijklm")
                         (browser "https://www.youtube.com/watch?v=defghijklmn"))))))))

(ert-deftest yt-url-play-url-starts-at-link-time ()
  "\\[yt-play-url] plays from the t= time of the link."
  (let (played)
    (cl-letf (((symbol-function 'yt-play-at)
               (lambda (video start &rest _) (setq played (list (yt-video-id video) start))))
              ((symbol-function 'yt-play)
               (lambda (video &rest _) (setq played (list (yt-video-id video))))))
      (yt-play-url "https://youtu.be/abcdefghijk?t=42")
      (should (equal played '("abcdefghijk" 42)))
      (yt-play-url "https://youtu.be/abcdefghijk")
      (should (equal played '("abcdefghijk"))))))

(provide 'yt-url-tests)
;;; yt-url-tests.el ends here
