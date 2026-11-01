;;; yt-test-helpers.el --- Shared helpers for yt tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loaded by every test file.  Loading it refuses to continue unless the
;; tests run in the isolated environment that scripts/isolated sets up
;; (HOME and XDG directories under $YT_TEST_ROOT), so a test can never
;; touch the real cookie file, cache or customizations.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'yt)
(require 'yt-process)
(require 'yt-auth)
(require 'yt-cache)
(require 'yt-feed)

(defconst yt-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding the test files.")

(defconst yt-test-fixtures-dir (expand-file-name "fixtures" yt-test-dir)
  "Directory holding the test fixtures.")

(defconst yt-test-root
  (let ((root (getenv "YT_TEST_ROOT")))
    (unless (and root (file-directory-p root))
      (error "YT_TEST_ROOT is unset: run tests with `make test' or `nix run .#test'"))
    (file-name-as-directory (file-truename root)))
  "Temporary root directory of the isolated test environment.")

(defun yt-test-under-root-p (file)
  "Return non-nil if FILE is inside `yt-test-root'."
  (string-prefix-p yt-test-root (file-truename (expand-file-name file))))

(defun yt-test--assert-isolated ()
  "Signal an error unless every directory yt writes to is under the root."
  (dolist (dir (list "~" yt-state-directory (yt-ensure-runtime-directory)
                     (yt-cache-file-name) (xdg-cache-home) (xdg-config-home)))
    (unless (yt-test-under-root-p dir)
      (error "Test isolation broken: %s is outside %s" dir yt-test-root))))

(yt-test--assert-isolated)

;; Tests must never persist customizations.
(advice-add 'customize-save-variable :override
            (lambda (&rest _)
              (error "Tests must not call `customize-save-variable'"))
            '((name . yt-test-no-customize-save)))

;;;; Fixture leak guard

(defconst yt-test-leak-patterns
  '(("[?&]ip=" . "signed stream URL (ip=)")
    ("expire=" . "signed stream URL (expire=)")
    ("/home/" . "home directory path")
    ("SAPISID\\|__Secure-\\|LOGIN_INFO" . "session cookie name outside a fake cookie line")
    ("[[:alnum:]._%+-]+@[[:alnum:]-]+\\.[[:alnum:].-]*[[:alpha:]]\\{2,\\}" . "email address"))
  "Regexps that must not occur in fixtures, with a description of each.")

(defun yt-test--cookie-line-p (line)
  "Return the fields of LINE if it is a Netscape cookie-file line, else nil."
  (let ((fields (split-string line "\t")))
    (and (= (length fields) 7)
         (member (nth 1 fields) '("TRUE" "FALSE"))
         fields)))

(defun yt-test-fixture-leaks (dir)
  "Return a list of (FILE LINE REASON) for suspected secrets under DIR.
A line of a Netscape cookie file is allowed to name session
cookies, but its value must start with \"FAKE\"."
  (let (leaks)
    (dolist (file (and (file-directory-p dir)
                       (directory-files-recursively dir "")))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((n 0))
          (dolist (line (split-string (buffer-string) "\n"))
            (setq n (1+ n))
            (let ((cookie (yt-test--cookie-line-p line)))
              (if cookie
                  (unless (string-prefix-p "FAKE" (nth 6 cookie))
                    (push (list file n "cookie value is not FAKE…") leaks))
                (pcase-dolist (`(,re . ,reason) yt-test-leak-patterns)
                  (when (string-match-p re line)
                    (push (list file n reason) leaks)))))))))
    (nreverse leaks)))

;;;; Waiting for asynchronous results

(defvar yt-test-timeout
  (string-to-number (or (getenv "YT_TEST_TIMEOUT") "30"))
  "Seconds `yt-test-wait-until' waits before failing.")

(defun yt-test-wait-until (predicate &optional what)
  "Process events until PREDICATE returns non-nil, and return its value.
Fail the test after `yt-test-timeout' seconds, naming WHAT."
  (let ((deadline (+ (float-time) yt-test-timeout))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or value
        (ert-fail (list "Timed out waiting for" (or what predicate))))))

(defun yt-test-sleep (seconds)
  "Process events for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02))))

(defun yt-test-process (program args &rest keys)
  "Run `yt-process-run' with PROGRAM, ARGS and KEYS, and wait for it.
Return (ok VALUE INFO) or (error PLIST)."
  (let (result)
    (apply #'yt-process-run program args
           :on-success (lambda (value info) (setq result (list 'ok value info)))
           :on-error (lambda (err) (setq result (list 'error err)))
           keys)
    (yt-test-wait-until (lambda () result) program)))

(defun yt-test-sh (script &rest keys)
  "Run SCRIPT with sh -c through `yt-process-run' with KEYS; see `yt-test-process'."
  (apply #'yt-test-process "sh" (list "-c" script) keys))

(defun yt-test-auth-run (args &rest keys)
  "Run `yt-auth-run' with ARGS and KEYS and wait for it.
Return (ok VALUE INFO) or (error PLIST)."
  (let (result)
    (apply #'yt-auth-run args
           :on-success (lambda (value info) (setq result (list 'ok value info)))
           :on-error (lambda (err) (setq result (list 'error err)))
           keys)
    (yt-test-wait-until (lambda () result) "yt-auth-run")))

;;;; Fixtures and fake programs

(defconst yt-test-bin-dir (expand-file-name "bin" yt-test-dir)
  "Directory holding the fake programs.")

(defun yt-test-fixture (name)
  "Return the file name of the fixture NAME."
  (expand-file-name name yt-test-fixtures-dir))

(defun yt-test-fixture-string (name)
  "Return the contents of the fixture NAME."
  (with-temp-buffer
    (insert-file-contents (yt-test-fixture name))
    (buffer-string)))

(defun yt-test-write (file string)
  "Write STRING to FILE."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region string nil file nil 'silent)))

(defun yt-test-cookies (&optional sid)
  "Return the contents of a fake YouTube cookie file whose SID is SID."
  (concat "# Netscape HTTP Cookie File\n"
          ".youtube.com\tTRUE\t/\tTRUE\t1830000000\tLOGIN_INFO\tFAKE-login\n"
          ".youtube.com\tTRUE\t/\tTRUE\t1830000000\tSAPISID\tFAKE-sapisid\n"
          ".youtube.com\tTRUE\t/\tTRUE\t1830000000\tSID\t"
          (or sid "FAKE-sid") "\n"))

(defun yt-test-export-summary (&rest overrides)
  "Return an exporter JSON summary, with OVERRIDES applied to a good one."
  (let ((summary (list :keyring "GNOMEKEYRING" :count 3 :total 9
                       :decrypt_failures 0 :has_login_info t :has_sapisid t
                       :warnings [] :error :null :ok t
                       :profile "Profile 1" :written :null)))
    (while overrides
      (setq summary (plist-put summary (pop overrides) (pop overrides))))
    (json-serialize summary :false-object :false :null-object :null)))

(cl-defun yt-test-step (dir n &key out err exit mode cookies)
  "Describe the Nth call of a fake program in scenario directory DIR.
OUT and ERR are its output, EXIT its exit status, MODE one of
\"stream\", \"hang\" and \"stream-hang\", and COOKIES the cookie
file it writes."
  (let ((nn (format "%02d" n)))
    (pcase-dolist (`(,ext . ,value) `(("out" . ,out) ("err" . ,err)
                                      ("exit" . ,(and exit (format "%d" exit)))
                                      ("mode" . ,mode) ("cookies" . ,cookies)))
      (when value
        (yt-test-write (expand-file-name (concat nn "." ext) dir) value)))))

(defun yt-test-calls (dir)
  "Return how many times the fake program of scenario DIR was called."
  (let ((file (expand-file-name "count" dir)))
    (if (file-exists-p file)
        (string-to-number (with-temp-buffer
                            (insert-file-contents file)
                            (buffer-string)))
      0)))

(defun yt-test-argv (dir n)
  "Return the arguments of the Nth call of the fake program of scenario DIR."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (format "argv-%02d" n) dir))
    (split-string (buffer-string) "\n" t)))

(defun yt-test-install-cookies (&optional contents)
  "Install CONTENTS, or fake login cookies, as the master cookie file."
  (let ((file (yt-auth-cookie-file)))
    (with-file-modes #o600
      (yt-test-write file (or contents (yt-test-cookies))))
    (set-file-modes file #o600)
    file))

(defun yt-test-file-string (file)
  "Return the contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun yt-test-cookie-copies ()
  "Return the per-run cookie copies left in the runtime directory."
  (directory-files (yt-ensure-runtime-directory) t "\\`cookies-.*\\.txt\\'"))

(defmacro yt-test-with-scenario (dirs &rest body)
  "Run BODY with yt pointed at fake programs and fresh directories.
DIRS is (YTDLP-DIR EXPORT-DIR): variables bound to the scenario
directories of the fake yt-dlp and the fake cookie exporter.  The
yt state, runtime and Chromium directories are fresh, and the
sign-in state, the cache and the feed buffers are reset."
  (declare (indent 1))
  (let ((root (make-symbol "root")))
    `(let* ((,root (make-temp-file (expand-file-name "scenario-" yt-test-root) t))
            (,(car dirs) (expand-file-name "ytdlp" ,root))
            (,(cadr dirs) (expand-file-name "export" ,root))
            (yt-state-directory (expand-file-name "state" ,root))
            (yt-runtime-directory (expand-file-name "runtime" ,root))
            (yt-chromium-directory (expand-file-name "chromium" ,root))
            (yt-ytdlp-program (expand-file-name "fake-yt-dlp" yt-test-bin-dir))
            (yt-export-cookies-program
             (expand-file-name "fake-export-cookies" yt-test-bin-dir))
            (yt-cookie-profile nil)
            (yt-ytdlp-extra-args nil)
            (yt-auth--state 'unknown)
            (yt-auth--state-time nil)
            (yt-auth--generation 0)
            (yt-auth--export-waiters nil)
            (yt-auth--backoff nil)
            (yt-auth--stale-copies-cleaned t)
            (yt-ytdlp--version-checked t)
            (yt-cache-file nil)
            (yt-cache--db nil)
            (yt-feed--fully-refreshed nil)
            (yt-watched-changed-functions nil)
            (yt-auth-state-change-hook nil)
            (process-environment
             (append (list (concat "FAKE_SCENARIO=" ,(car dirs))
                           (concat "FAKE_EXPORT_SCENARIO=" ,(cadr dirs)))
                     process-environment)))
       (make-directory ,(car dirs) t)
       (make-directory ,(cadr dirs) t)
       (make-directory yt-chromium-directory t)
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (yt-feed--buffers))
           (kill-buffer buffer))
         (let (keys)
           (maphash (lambda (key _) (push key keys)) yt-process--running)
           (mapc #'yt-process-cancel keys))
         (cancel-function-timers #'yt-feed--update-ages)
         (yt-cache-close)
         (delete-directory ,root t)))))

(provide 'yt-test-helpers)
;;; yt-test-helpers.el ends here
