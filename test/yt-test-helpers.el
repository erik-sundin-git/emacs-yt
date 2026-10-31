;;; yt-test-helpers.el --- Shared helpers for yt tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loaded by every test file.  Loading it refuses to continue unless the
;; tests run in the isolated environment that scripts/isolated sets up
;; (HOME and XDG directories under $YT_TEST_ROOT), so a test can never
;; touch the real cookie file, cache or customizations.

;;; Code:

(require 'ert)
(require 'yt)

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
                     (xdg-cache-home) (xdg-config-home)))
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

(provide 'yt-test-helpers)
;;; yt-test-helpers.el ends here
