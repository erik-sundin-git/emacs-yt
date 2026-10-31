;;; yt-tests.el --- Tests for yt.el and the test environment -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the private-directory helpers in yt.el, the isolation of
;; the test environment and the fixture leak guard.

;;; Code:

(require 'yt-test-helpers)

(defmacro yt-test-with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory, run BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "yt-test-" t)))
     (unwind-protect (progn ,@body)
       (set-file-modes ,var #o700)
       (delete-directory ,var t))))

;;;; Test environment

(ert-deftest yt-test-environment-is-isolated ()
  "HOME, the XDG directories and yt's directories are under the root."
  (should (yt-test-under-root-p "~"))
  (should (yt-test-under-root-p yt-state-directory))
  (should (yt-test-under-root-p (yt-ensure-runtime-directory)))
  (should (yt-test-under-root-p (xdg-state-home)))
  (should (equal (getenv "TZ") "UTC")))

(ert-deftest yt-test-customize-save-is-blocked ()
  "Tests cannot persist customizations."
  (should-error (customize-save-variable 'yt-runtime-directory nil)))

;;;; Private directories

(ert-deftest yt-test-runtime-directory-created-private ()
  "The runtime directory is created with mode 0700."
  (let ((dir (yt-ensure-runtime-directory)))
    (should (file-directory-p dir))
    (should (= (file-modes dir) #o700))
    (should (equal dir (file-name-as-directory
                        (expand-file-name "yt" (getenv "XDG_RUNTIME_DIR")))))))

(ert-deftest yt-test-state-directory-created-private ()
  "The state directory is created with mode 0700, parents included."
  (yt-test-with-temp-dir tmp
    (let ((yt-state-directory (expand-file-name "a/b/yt" tmp)))
      (should (= (file-modes (yt-ensure-state-directory)) #o700))
      (should (= (file-modes (expand-file-name "a" tmp)) #o700)))))

(ert-deftest yt-test-private-directory-rejects-shared-mode ()
  "A directory accessible by group or others is refused."
  (yt-test-with-temp-dir tmp
    (set-file-modes tmp #o755)
    (let ((yt-runtime-directory tmp))
      (should-error (yt-ensure-runtime-directory) :type 'user-error))))

(ert-deftest yt-test-private-directory-rejects-symlink ()
  "A symbolic link is refused, even one pointing at a private directory."
  (yt-test-with-temp-dir tmp
    (let ((target (expand-file-name "target" tmp))
          (link (expand-file-name "link" tmp)))
      (make-directory target)
      (set-file-modes target #o700)
      (make-symbolic-link target link)
      (let ((yt-runtime-directory link))
        (should-error (yt-ensure-runtime-directory) :type 'user-error)))))

(ert-deftest yt-test-private-directory-rejects-file ()
  "A regular file is refused."
  (yt-test-with-temp-dir tmp
    (let ((file (expand-file-name "file" tmp)))
      (write-region "" nil file)
      (let ((yt-runtime-directory file))
        (should-error (yt-ensure-runtime-directory) :type 'user-error)))))

(ert-deftest yt-test-runtime-directory-requires-xdg ()
  "Without XDG_RUNTIME_DIR there is no fallback to /tmp."
  (let ((yt-runtime-directory nil)
        (process-environment (cons "XDG_RUNTIME_DIR" process-environment)))
    (should-not (getenv "XDG_RUNTIME_DIR"))
    (should-error (yt-ensure-runtime-directory) :type 'user-error)))

;;;; Fixture leak guard

(ert-deftest yt-test-fixtures-contain-no-secrets ()
  "No fixture contains stream URLs, home paths, emails or real cookies."
  (should-not (yt-test-fixture-leaks yt-test-fixtures-dir)))

(ert-deftest yt-test-leak-guard-detects-leaks ()
  "The leak guard flags each kind of leak and accepts fake cookies."
  (yt-test-with-temp-dir tmp
    (let ((good (expand-file-name "good.txt" tmp))
          (bad (expand-file-name "bad.txt" tmp)))
      (write-region (concat "# Netscape HTTP Cookie File\n"
                            ".youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tFAKE1\n"
                            "{\"title\": \"A video\"}\n")
                    nil good)
      (should-not (yt-test-fixture-leaks tmp))
      (write-region (concat ".youtube.com\tTRUE\t/\tTRUE\t0\tSID\treal\n"
                            "https://x.googlevideo.com/v?expire=1&ip=1.2.3.4\n"
                            "/home/someone/.config\n"
                            "{\"cookie\": \"__Secure-3PSID\"}\n"
                            "contact: someone@example.com\n")
                    nil bad)
      (let ((reasons (mapcar #'caddr (yt-test-fixture-leaks tmp))))
        (should (member "cookie value is not FAKE…" reasons))
        (should (member "signed stream URL (ip=)" reasons))
        (should (member "signed stream URL (expire=)" reasons))
        (should (member "home directory path" reasons))
        (should (member "session cookie name outside a fake cookie line"
                        reasons))
        (should (member "email address" reasons))))))

;;;; Entry points

(ert-deftest yt-test-entry-command-is-bound ()
  "`yt-map' binds `y' to the `yt' command."
  (should (eq (keymap-lookup yt-map "y") #'yt))
  (should (commandp #'yt)))

(provide 'yt-tests)
;;; yt-tests.el ends here
