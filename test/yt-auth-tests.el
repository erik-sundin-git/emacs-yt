;;; yt-auth-tests.el --- Tests for yt-auth.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for profiles, the cookie export, per-run cookie copies and
;; their write-back, re-export on expiry, back-off and the commands.
;; yt-dlp and the exporter are the scripted fakes in test/bin.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-auth)

(defconst yt-auth-test--expired
  "ERROR: [youtube:tab] ytsubs: Login details are needed to download this content. Use --cookies-from-browser or --cookies for the authentication.\n"
  "What yt-dlp prints when the feed needs a login.")

(defconst yt-auth-test--bot
  "ERROR: [youtube:tab] ytsubs: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.\n"
  "What yt-dlp prints when YouTube asks for a bot check.")

(defun yt-auth-test--use-profile ()
  "Install the Local State fixture and choose \"Profile 1\"."
  (copy-file (yt-test-fixture "local-state.json")
             (expand-file-name "Local State" yt-chromium-directory) t)
  (yt-state-put 'cookie-profile "Profile 1"))

(defun yt-auth-test--export (&optional callback)
  "Run `yt-auth-export' and wait; return (OK RESULT).
CALLBACK, if non-nil, is also passed to `yt-auth-export'."
  (let (result)
    (yt-auth-export (lambda (ok res)
                      (setq result (list ok res))
                      (when callback (funcall callback ok res))))
    (yt-test-wait-until (lambda () result) "export")))

;;;; Profiles

(ert-deftest yt-auth-chromium-profiles ()
  "Profiles are read from Chromium's Local State."
  (yt-test-with-scenario (_ _)
    (should-not (yt-auth-chromium-profiles))
    (yt-auth-test--use-profile)
    (should (equal (yt-auth-chromium-profiles)
                   '(("Default" . "Person 1") ("Profile 1" . "emacs-yt")
                     ("Profile 2" . "Other"))))
    (should (equal (yt-auth-profile-label "Profile 1") "‘emacs-yt’ (Profile 1)"))))

(ert-deftest yt-auth-read-profile ()
  "The emacs-yt profile is the default; Default needs confirmation."
  (yt-test-with-scenario (_ _)
    (yt-auth-test--use-profile)
    (let ((answer nil) (confirm nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _coll &optional _pred _req _init _hist def &rest _)
                   (or answer def)))
                ((symbol-function 'yes-or-no-p) (lambda (_) confirm)))
        (should (equal (yt-auth-read-profile) "Profile 1"))
        (setq answer "Person 1 (Default)")
        (should-error (yt-auth-read-profile) :type 'user-error)
        (setq confirm t)
        (should (equal (yt-auth-read-profile) "Default"))))))

(ert-deftest yt-auth-profile-precedence ()
  "`yt-cookie-profile' overrides the profile stored by `yt-login'."
  (yt-test-with-scenario (_ _)
    (should-not (yt-auth-profile))
    (yt-state-put 'cookie-profile "Profile 1")
    (should (equal (yt-auth-profile) "Profile 1"))
    (let ((yt-cookie-profile "Profile 9"))
      (should (equal (yt-auth-profile) "Profile 9")))
    (should (= (file-modes (expand-file-name "state.eld" yt-state-directory)) #o600))))

;;;; Export

(ert-deftest yt-auth-export-success ()
  "A good export writes the master file and bumps the generation."
  (yt-test-with-scenario (_ export)
    (yt-auth-test--use-profile)
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (pcase-let ((`(,ok ,summary) (yt-auth-test--export)))
      (should ok)
      (should (= (plist-get summary :count) 3)))
    (should (= yt-auth--generation 1))
    (should (= (file-modes (yt-auth-cookie-file)) #o600))
    (should (equal (yt-test-argv export 1)
                   (list "--profile" "Profile 1" "--output" (yt-auth-cookie-file))))))

(ert-deftest yt-auth-export-failures ()
  "Export problems are classified from the exporter's summary."
  (yt-test-with-scenario (_ export)
    (yt-auth-test--use-profile)
    (yt-test-step export 1 :exit 2 :out (yt-test-export-summary
                                         :ok :false :decrypt_failures 7))
    (yt-test-step export 2 :exit 2 :out (yt-test-export-summary
                                         :ok :false :has_login_info :false))
    (yt-test-step export 3 :exit 2 :out (yt-test-export-summary
                                         :ok :false
                                         :error "could not find chromium cookies database in \"x\""))
    (pcase-dolist (`(,class . ,state) '((keyring . keyring) (no-cookies . no-cookies)
                                        (bad-profile . bad-profile)))
      (pcase-let ((`(,ok ,result) (yt-auth-test--export)))
        (should-not ok)
        (should (eq (plist-get result :class) class))
        (should (stringp (plist-get result :message)))
        (should (eq (yt-auth-state) state))))
    (should (= yt-auth--generation 0))
    (should-not (file-exists-p (yt-auth-cookie-file)))))

(ert-deftest yt-auth-export-joins-running-export ()
  "Exports requested while one runs share its result."
  (yt-test-with-scenario (_ export)
    (yt-auth-test--use-profile)
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (let (results)
      (yt-auth-export (lambda (ok _) (push (list 'a ok) results)))
      (yt-auth-export (lambda (ok _) (push (list 'b ok) results)))
      (yt-test-wait-until (lambda () (= (length results) 2)))
      (should (equal (nreverse results) '((a t) (b t)))))
    (should (= (yt-test-calls export) 1))
    (should (= yt-auth--generation 1))))

(ert-deftest yt-auth-export-without-profile ()
  "Without a chosen profile the export fails without running anything."
  (yt-test-with-scenario (_ export)
    (pcase-let ((`(,ok ,result) (yt-auth-test--export)))
      (should-not ok)
      (should (eq (plist-get result :class) 'no-cookies)))
    (should (= (yt-test-calls export) 0))))

;;;; Running yt-dlp with cookies

(ert-deftest yt-auth-run-without-cookies ()
  "Without a master cookie file nothing runs."
  (yt-test-with-scenario (ytdlp _)
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)))
      (should (eq (plist-get err :class) 'no-cookies)))
    (should (= (yt-test-calls ytdlp) 0))
    (should (eq (yt-auth-state) 'no-cookies))))

(ert-deftest yt-auth-run-uses-private-copy ()
  "yt-dlp gets a private 0600 copy of the cookies, deleted afterwards."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :mode "stream" :out (yt-test-fixture-string "feed.ndjson"))
    (let (modes)
      (pcase-let ((`(ok ,_ ,info)
                   (yt-test-auth-run (yt-ytdlp-feed-args 10) :parse 'ndjson :source 'feed
                                     :on-line (lambda (_)
                                                (setq modes (mapcar #'file-modes
                                                                    (yt-test-cookie-copies)))
                                                nil))))
        (should (= (plist-get info :lines) 4))
        (should-not (plist-get info :class)))
      (should (equal modes '(#o600))))
    (let* ((argv (yt-test-argv ytdlp 1))
           (copy (cadr (member "--cookies" argv))))
      (should (member "--ignore-config" argv))
      (should (equal (last argv 2) '("--" ":ytsubs")))
      (should (string-prefix-p (file-name-as-directory yt-runtime-directory) copy))
      (should-not (equal copy (yt-auth-cookie-file))))
    (should-not (yt-test-cookie-copies))
    (should (eq (yt-auth-state) 'ok))))

(ert-deftest yt-auth-run-writes-back-rotated-cookies ()
  "Cookies that yt-dlp rotated in the copy replace the master file."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out "{\"entries\": [{\"id\": \"x\"}]}"
                  :cookies (yt-test-cookies "FAKE-rotated"))
    (should (eq 'ok (car (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify))))
    (should (string-match-p "FAKE-rotated" (yt-test-file-string (yt-auth-cookie-file))))
    (should (= (file-modes (yt-auth-cookie-file)) #o600))
    (should-not (yt-test-cookie-copies))))

(ert-deftest yt-auth-run-skips-unsafe-write-back ()
  "No write-back if the master was replaced meanwhile or the copy is bad."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    ;; The master is re-exported while the first run is in flight.
    (yt-test-step ytdlp 1 :mode "stream" :out (yt-test-fixture-string "feed.ndjson")
                  :cookies (yt-test-cookies "FAKE-stale"))
    (yt-test-auth-run (yt-ytdlp-feed-args 10) :parse 'ndjson :source 'feed
                      :on-line (lambda (_) (setq yt-auth--generation 5) nil))
    (should-not (string-match-p "FAKE-stale" (yt-test-file-string (yt-auth-cookie-file))))
    ;; The copy lost its login cookies.
    (yt-test-step ytdlp 2 :out "{\"entries\": [{\"id\": \"x\"}]}"
                  :cookies "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tPREF\tFAKE\n")
    (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)
    (should (string-match-p "LOGIN_INFO" (yt-test-file-string (yt-auth-cookie-file))))))

(ert-deftest yt-auth-run-reexports-and-retries-once ()
  "An expired session is re-exported, and the run retried once."
  (yt-test-with-scenario (ytdlp export)
    (yt-auth-test--use-profile)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1 :err yt-auth-test--expired)
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies "FAKE-new"))
    (yt-test-step ytdlp 2 :mode "stream" :out (yt-test-fixture-string "feed.ndjson"))
    (pcase-let ((`(ok ,_ ,info) (yt-test-auth-run (yt-ytdlp-feed-args 10)
                                                  :parse 'ndjson :source 'feed)))
      (should (= (plist-get info :lines) 4)))
    (should (= (yt-test-calls ytdlp) 2))
    (should (= (yt-test-calls export) 1))
    (should (eq (yt-auth-state) 'ok))))

(ert-deftest yt-auth-run-gives-up-after-one-retry ()
  "A session still expired after re-export is reported."
  (yt-test-with-scenario (ytdlp export)
    (yt-auth-test--use-profile)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1 :err yt-auth-test--expired)
    (yt-test-step ytdlp 2 :exit 1 :err yt-auth-test--expired)
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-feed-args 10)
                                                 :parse 'ndjson :source 'feed)))
      (should (eq (plist-get err :class) 'expired))
      (should (string-match-p "expired" (plist-get err :message))))
    (should (= (yt-test-calls ytdlp) 2))
    (should (= (yt-test-calls export) 1))
    (should (eq (yt-auth-state) 'expired))))

(ert-deftest yt-auth-run-empty-feed-or-warning-means-expired ()
  "Exit 0 with no entries, or with a cookie warning, is an expired session."
  (yt-test-with-scenario (ytdlp export)
    (yt-auth-test--use-profile)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out "")
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (yt-test-step ytdlp 2 :out (yt-test-fixture-string "feed.ndjson")
                  :err "WARNING: [youtube] The provided YouTube account cookies are no longer valid.\n")
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-feed-args 10)
                                                 :parse 'ndjson :source 'feed)))
      (should (eq (plist-get err :class) 'expired)))
    (should (= (yt-test-calls ytdlp) 2))
    (should (= (yt-test-calls export) 1))))

(ert-deftest yt-auth-run-still-empty-after-export-is-not-expired ()
  "Nothing even with fresh cookies is reported as empty, not expired."
  (yt-test-with-scenario (ytdlp export)
    (yt-auth-test--use-profile)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out "")
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (yt-test-step ytdlp 2 :out "")
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-feed-args 10)
                                                 :parse 'ndjson :source 'feed)))
      (should (eq (plist-get err :class) 'empty))
      (should (string-match-p "\\`YouTube returned no videos with freshly exported cookies"
                              (plist-get err :message))))
    (should-not (memq (yt-auth-state) '(expired bot-check)))
    (should-not (yt-auth--backing-off))
    (should (= (yt-test-calls ytdlp) 2))
    (should (= (yt-test-calls export) 1))))

(ert-deftest yt-auth-run-survives-failed-write-back ()
  "A run succeeds even when saving the rotated cookies fails."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :out "{\"entries\": [{\"id\": \"x\"}]}")
    (cl-letf (((symbol-function 'yt-auth--write-back)
               (lambda (&rest _) (error "Disk full"))))
      (should (eq 'ok (car (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)))))
    (should-not (yt-test-cookie-copies))))

(ert-deftest yt-auth-export-that-cannot-start-ends ()
  "An export that signals while starting ends, and the next one runs."
  (yt-test-with-scenario (_ export)
    (yt-auth-test--use-profile)
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (let (results)
      (cl-letf (((symbol-function 'yt-auth-cookie-file)
                 (lambda () (user-error "Refusing to use the state directory"))))
        (yt-auth-export (lambda (ok result) (push (list ok (plist-get result :message)) results)))
        (yt-test-wait-until (lambda () results) "failed export"))
      (should (equal results '((nil "Refusing to use the state directory"))))
      (should-not yt-auth--export-waiters)
      (setq results nil)
      (yt-auth-export (lambda (ok _) (push ok results)))
      (yt-test-wait-until (lambda () results) "second export")
      (should (equal results '(t))))))

(ert-deftest yt-auth-run-concurrent-expiry-shares-one-export ()
  "Runs that find the session expired together trigger one export."
  (yt-test-with-scenario (ytdlp export)
    (yt-auth-test--use-profile)
    (yt-test-install-cookies)
    (dolist (n '(1 2))
      (yt-test-step ytdlp n :exit 1 :err yt-auth-test--expired))
    (dolist (n '(3 4))
      (yt-test-step ytdlp n :out "{\"entries\": [{\"id\": \"x\"}]}"))
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (let (results)
      (dotimes (_ 2)
        (yt-auth-run (yt-ytdlp-verify-args) :source 'verify
                     :on-success (lambda (_ _) (push 'ok results))
                     :on-error (lambda (err) (push err results))))
      (yt-test-wait-until (lambda () (= (length results) 2)))
      (should (equal results '(ok ok))))
    (should (= (yt-test-calls export) 1))
    (should (= (yt-test-calls ytdlp) 4))))

(ert-deftest yt-auth-run-backs-off-after-bot-check ()
  "After a bot check, runs fail at once unless they ignore the back-off."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1 :err yt-auth-test--bot)
    (yt-test-step ytdlp 2 :out "{\"entries\": [{\"id\": \"x\"}]}")
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)))
      (should (eq (plist-get err :class) 'bot-check)))
    (should (eq (yt-auth-state) 'bot-check))
    (pcase-let ((`(error ,err) (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)))
      (should (eq (plist-get err :type) 'backoff))
      (should (string-match-p "waiting until" (plist-get err :message))))
    (should (= (yt-test-calls ytdlp) 1))
    (should (eq 'ok (car (yt-test-auth-run (yt-ytdlp-verify-args)
                                           :source 'verify :ignore-backoff t))))
    (let ((yt--now-function (lambda () (+ (float-time) yt-auth-bot-check-backoff 1))))
      (should-not (yt-auth--backing-off)))))

(ert-deftest yt-auth-successful-check-lifts-backoff ()
  "A successful sign-in check ends the pause; a refused run does not."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (yt-test-step ytdlp 1 :exit 1 :err yt-auth-test--bot)
    (yt-test-step ytdlp 2 :exit 1 :err yt-auth-test--bot)
    (yt-test-step ytdlp 3 :out "{\"entries\": [{\"id\": \"x\"}]}")
    (yt-test-step ytdlp 4 :out "{\"entries\": [{\"id\": \"x\"}]}")
    (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify)
    (should (string-match-p "\\`Paused until [0-9:]+ (YouTube asked for a bot check)\\'"
                            (yt-auth-backoff-description)))
    (with-temp-buffer
      (yt-feed-mode)
      (setq yt-feed--source 'subscriptions)
      (should (string-match-p "Paused until" (yt-feed--header-line))))
    ;; A check that fails again keeps the pause.
    (yt-check-auth)
    (yt-test-wait-until (lambda () (= (yt-test-calls ytdlp) 2)) "second check")
    (yt-test-wait-until (lambda () (not (yt-process-busy-p '(yt-auth . verify)))) "check done")
    (should (yt-auth--backing-off))
    (yt-check-auth)
    (yt-test-wait-until (lambda () (not (yt-auth--backing-off))) "pause lifted")
    (should-not (yt-auth-backoff-description))
    (should (eq 'ok (car (yt-test-auth-run (yt-ytdlp-verify-args) :source 'verify))))
    (should (= (yt-test-calls ytdlp) 4))))

(ert-deftest yt-auth-run-denied-extra-args-leave-no-copy ()
  "Refused extra arguments signal an error and leave no cookie copy."
  (yt-test-with-scenario (ytdlp _)
    (yt-test-install-cookies)
    (let ((yt-ytdlp-extra-args '("--print-traffic")))
      (should-error (yt-auth-run (yt-ytdlp-verify-args)) :type 'user-error))
    (should-not (yt-test-cookie-copies))
    (should (= (yt-test-calls ytdlp) 0))))

;;;; Commands

(ert-deftest yt-auth-login-flow ()
  "`yt-login' asks for the profile, exports and verifies."
  (yt-test-with-scenario (ytdlp export)
    (copy-file (yt-test-fixture "local-state.json")
               (expand-file-name "Local State" yt-chromium-directory))
    (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
    (yt-test-step ytdlp 1 :out "{\"entries\": [{\"id\": \"a\"}, {\"id\": \"b\"}]}")
    (let (messages)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _coll &optional _pred _req _init _hist def &rest _) def))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (yt-login)
        (yt-test-wait-until (lambda () (eq (yt-auth-state) 'ok)))
        (yt-test-sleep 0.1))
      (should (string-match-p "Signed in to YouTube" (car messages))))
    (should (equal (yt-state-get 'cookie-profile) "Profile 1"))
    (should (member ":ytsubs" (yt-test-argv ytdlp 1)))))

(ert-deftest yt-auth-logout ()
  "`yt-logout' deletes the cookies and invalidates running copies."
  (yt-test-with-scenario (_ _)
    (yt-test-install-cookies)
    (yt-test-write (expand-file-name "cookies-x.txt" (yt-ensure-runtime-directory)) "x")
    (cl-letf (((symbol-function 'message) #'ignore))
      (yt-logout))
    (should-not (file-exists-p (yt-auth-cookie-file)))
    (should-not (yt-test-cookie-copies))
    (should (= yt-auth--generation 1))
    (should (eq (yt-auth-state) 'no-cookies))))

(provide 'yt-auth-tests)
;;; yt-auth-tests.el ends here
