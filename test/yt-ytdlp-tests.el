;;; yt-ytdlp-tests.el --- Tests for yt-ytdlp.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for yt-dlp argument lists, the error classifier and the
;; version check.  The messages are those of yt-dlp 2026.10.21, either
;; copied from its source or, for reasons YouTube supplies itself, as
;; yt-dlp prints them.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-ytdlp)

(defconst yt-ytdlp-test--messages
  '((bot-check . "ERROR: [youtube] fakevideo01: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ for how to manually pass cookies.")
    (age . "ERROR: [youtube] fakevideo01: Sign in to confirm your age. This video may be inappropriate for some users. Use --cookies-from-browser or --cookies for the authentication.")
    (members . "ERROR: [youtube] fakevideo01: Join this channel to get access to members-only content like this video, and other exclusive perks.")
    (rate-limit . "ERROR: [youtube] fakevideo01: Your account has been rate-limited by YouTube for up to an hour. It is recommended to use `-t sleep` to avoid this.")
    (expired . "ERROR: [youtube:tab] ytsubs: Login details are needed to download this content. Use --cookies-from-browser or --cookies for the authentication.")
    (expired . "WARNING: [youtube] The provided YouTube account cookies are no longer valid. They have likely been rotated in the browser as a security measure.")
    (corrupt-cookies . "ERROR: failed to load cookies")
    (network . "ERROR: [youtube:tab] ytsubs: Unable to download webpage: <urlopen error [Errno -3] Temporary failure in name resolution> (caused by TransportError)")
    (network . "ERROR: [youtube] fakevideo01: Unable to download API page: The read operation timed out")
    (extractor . "ERROR: [youtube:tab] ytsubs: Unable to recognize tab page")
    (extractor . "WARNING: [youtube] fakevideo01: Signature solving failed: Some formats may be missing.")
    (format . "ERROR: [youtube] fakevideo01: Requested format is not available. Use --list-formats for a list of available formats"))
  "Pairs of (CLASS . STDERR) that the classifier must recognize.")

(ert-deftest yt-ytdlp-classify-known-messages ()
  "Each known message is classified correctly."
  (pcase-dolist (`(,class . ,stderr) yt-ytdlp-test--messages)
    (should (equal (cons class (yt-ytdlp-classify stderr)) (cons class class)))))

(ert-deftest yt-ytdlp-classify-precedence ()
  "Specific problems win over the generic login hint they contain."
  ;; The bot check and the age gate both carry the cookie hint.
  (should (eq (yt-ytdlp-classify (alist-get 'bot-check yt-ytdlp-test--messages)) 'bot-check))
  (should (eq (yt-ytdlp-classify (alist-get 'age yt-ytdlp-test--messages)) 'age))
  (should-not (yt-ytdlp-classify "ERROR: Use --cookies-from-browser or --cookies for the authentication."))
  ;; A bot check that also timed out is still a bot check.
  (should (eq (yt-ytdlp-classify (concat "ERROR: read timed out\n"
                                         (alist-get 'bot-check yt-ytdlp-test--messages)))
              'bot-check)))

(ert-deftest yt-ytdlp-classify-ignores-harmless-output ()
  "Harmless warnings, other lines and empty stderr give nil."
  (should-not (yt-ytdlp-classify nil))
  (should-not (yt-ytdlp-classify ""))
  (should-not (yt-ytdlp-classify "WARNING: [youtube] fakevideo01: Some web client https formats have been skipped as they are missing a url. YouTube is forcing SABR streaming for this client."))
  (should-not (yt-ytdlp-classify "[youtube] fakevideo01: confirm you are not a bot (just a title)")))

(ert-deftest yt-ytdlp-classify-feed-redirect ()
  "A redirect to the home page means expiry only for the feed."
  (let ((stderr "ERROR: [youtube:tab] ytsubs: The channel/playlist does not exist and the URL redirected to youtube.com home page"))
    (should (eq (yt-ytdlp-classify stderr 'feed) 'expired))
    (should (eq (yt-ytdlp-classify stderr 'verify) 'expired))
    (should-not (yt-ytdlp-classify stderr))))

(ert-deftest yt-ytdlp-error-messages ()
  "Every class has a message; unknown problems show the last error line."
  (dolist (class '(bot-check age members rate-limit expired no-cookies bad-profile
                             corrupt-cookies network extractor format timeout cancelled))
    (should (stringp (yt-ytdlp-error-message class))))
  (should (string-match-p "update yt-dlp" (yt-ytdlp-error-message 'extractor)))
  (should (equal (yt-ytdlp-error-message nil "x\nERROR: first\nERROR: last\nmore\n")
                 "ERROR: last"))
  (should (equal (yt-ytdlp-error-message nil "only line\n") "only line")))

(ert-deftest yt-ytdlp-args-shape ()
  "Argument lists start with the base options and end with -- and the URL."
  (let ((yt-ytdlp-extra-args '("--limit-rate" "1M")))
    (dolist (args (list (yt-ytdlp-feed-args 5) (yt-ytdlp-verify-args)))
      (let ((argv (yt-ytdlp-args "/tmp/copy.txt" args)))
        (should (equal (seq-take argv (length yt-ytdlp-base-args)) yt-ytdlp-base-args))
        (should (member "--ignore-config" argv))
        (should (equal (cadr (member "--cookies" argv)) "/tmp/copy.txt"))
        (should (member "--limit-rate" argv))
        (should (equal (last argv 2) '("--" ":ytsubs")))
        (should (= 1 (seq-count (lambda (a) (equal a "--")) argv)))
        (should (< (seq-position argv "--limit-rate") (seq-position argv "--")))))
    (should (member "1:5" (yt-ytdlp-feed-args 5)))
    (should (member "youtubetab:approximate_date" (yt-ytdlp-feed-args 5)))
    (should (member "-j" (yt-ytdlp-feed-args 5)))
    (should (member "-J" (yt-ytdlp-verify-args)))))

(ert-deftest yt-ytdlp-extra-args-denylist ()
  "Extra arguments that leak secrets or break parsing are refused."
  (dolist (bad '("-v" "--verbose" "--print-traffic" "--print" "--print=title"
                 "-O" "--cookies" "--cookies-from-browser" "--no-warnings"
                 "--dump-pages" "--compat-options"))
    (let ((yt-ytdlp-extra-args (list bad)))
      (should-error (yt-ytdlp-args "/c" (yt-ytdlp-verify-args)) :type 'user-error)))
  (let ((yt-ytdlp-extra-args '("--limit-rate" "1M" "--proxy" "socks5://h")))
    (should (yt-ytdlp-args "/c" (yt-ytdlp-verify-args)))))

(ert-deftest yt-ytdlp-version-problem ()
  "Old or stale yt-dlp versions produce a warning."
  (let ((yt-ytdlp-min-version "2026.06.01")
        (yt-ytdlp-program "yt-dlp-fake-name")
        (now (yt-ytdlp-parse-version "2026.11.01")))
    (should-not (yt-ytdlp-version-problem "2026.10.21\n" now))
    (should-not (yt-ytdlp-version-problem "2026.10.21.1" now))
    (should (string-match-p "older than 2026.06.01"
                            (yt-ytdlp-version-problem "2026.05.31" now)))
    (should (string-match-p "more than 60 days old"
                            (yt-ytdlp-version-problem "2026.07.01" now)))
    (should (string-match-p "Cannot read"
                            (yt-ytdlp-version-problem "nightly" now)))
    (should (string-match-p "yt-dlp-fake-name"
                            (yt-ytdlp-version-problem "2026.05.31" now)))))

(ert-deftest yt-ytdlp-parse-streams-live ()
  "Only a stream that is live now counts as live."
  (let ((info (yt-process-parse-json (yt-test-fixture-string "resolve-combined.json"))))
    (should-not (plist-get (yt-ytdlp-parse-streams info) :live))
    (should (plist-get (yt-ytdlp-parse-streams (plist-put (copy-sequence info)
                                                          :live_status "is_live"))
                       :live))
    (should-not (plist-get (yt-ytdlp-parse-streams (plist-put (copy-sequence info)
                                                              :live_status "was_live"))
                           :live))))

(provide 'yt-ytdlp-tests)
;;; yt-ytdlp-tests.el ends here
