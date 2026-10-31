;;; yt-doctor-tests.el --- Tests for yt-doctor.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the diagnostics buffer and the debug feed listing.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-doctor)

(ert-deftest yt-doctor-cookie-stats ()
  "Cookie statistics count cookies and list domains only."
  (should (equal (yt-doctor--cookie-stats (yt-test-fixture "cookies.txt"))
                 '(3 ".youtube.com"))))

(ert-deftest yt-doctor-buffer-never-shows-cookie-values ()
  "The doctor buffer describes the cookie file without its values."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out "2026.10.21\n")
    (save-window-excursion
      (yt-doctor)
      (with-current-buffer "*yt-doctor*"
        (let ((text (buffer-string))
              (case-fold-search nil))
          (should (string-match-p "Cookie file" text))
          (should (string-match-p "  mode +600" text))
          (should (string-match-p "  cookies +3" text))
          (should (string-match-p "  domains +\\.youtube\\.com" text))
          (should (string-match-p "  version +2026\\.10\\.21" text))
          (should-not (string-match-p "FAKE-\\|LOGIN_INFO\\|SAPISID" text))))
      (kill-buffer "*yt-doctor*"))))

(ert-deftest yt-doctor-debug-fetch-feed ()
  "`yt-debug-fetch-feed' lists the parsed feed entries in order."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :mode "stream" :out (yt-test-fixture-string "feed.ndjson"))
    (save-window-excursion
      (yt-debug-fetch-feed 10)
      (with-current-buffer "*yt-debug-feed*"
        (yt-test-wait-until (lambda () (string-match-p "entries in" (buffer-string))))
        (let ((text (buffer-string)))
          (should (string-match-p "\\`4 entries in" text))
          (should (string-match-p "  0 .*12:34 +Fake Channel One +A normal video with ünïcode" text))
          (should (string-match-p "  3 .*A short" text))))
      (kill-buffer "*yt-debug-feed*"))
    (should (member "1:10" (yt-test-argv ytdlp 1)))))

(provide 'yt-doctor-tests)
;;; yt-doctor-tests.el ends here
