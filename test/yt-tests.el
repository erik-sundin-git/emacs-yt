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
  "`yt-map' opens the subscription feed on `y' and `RET', with labels."
  (should (eq (keymap-lookup yt-map "y") #'yt))
  (should (eq (keymap-lookup yt-map "RET") #'yt))
  (should (equal (alist-get ?y (cdr yt-map)) '("subscriptions" . yt)))
  (should (commandp #'yt))
  (should (eq (indirect-function 'yt-subscriptions) (indirect-function 'yt)))
  ;; The labelled player keys still reach their commands through `yt-map'.
  (should (eq (keymap-lookup yt-map "SPC") #'yt-player-pause))
  (should (eq (keymap-lookup yt-map "l") #'yt-player-playlist))
  ;; Every binding of both maps has a label for which-key.
  (dolist (map (list yt-map yt-player-map))
    (map-keymap (lambda (_key binding)
                  (unless (keymapp binding)
                    (should (stringp (car-safe binding)))))
                map)))

(ert-deftest yt-test-autoloads ()
  "The generated autoloads define the commands people run with M-x.
Every autoload cookie must precede a definition: one before a
comment autoloads whatever comes next instead."
  (let* ((dir (file-name-directory (directory-file-name yt-test-dir)))
         (out (expand-file-name "yt-autoloads-test.el" yt-test-root))
         (sources (seq-remove (lambda (f) (string-suffix-p "-autoloads.el" f))
                              (directory-files dir t "\\`yt.*\\.el\\'"))))
    (dolist (file sources)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^;;;###autoload\n" nil t)
          (should (equal (list (file-name-nondirectory file) "(")
                         (list (file-name-nondirectory file)
                               (buffer-substring (point) (min (point-max) (1+ (point))))))))))
    (unwind-protect
        (progn
          (let ((inhibit-message t))
            (loaddefs-generate dir out (list "yt-autoloads.el")))
          (let ((text (yt-test-file-string out)))
            (dolist (command '(yt yt-subscriptions yt-login yt-logout yt-forget-history
                                  yt-history yt-channels yt-search yt-play-url yt-doctor
                                  yt-subscribe yt-unsubscribe yt-saved-playlists))
              (should (string-match-p (format "(\\(?:autoload\\|defalias\\) '%s " command) text)))))
      (when (file-exists-p out)
        (delete-file out)))))

(ert-deftest yt-test-version-matches-changelog ()
  "The Version header of yt.el is the newest release in the CHANGELOG."
  (require 'lisp-mnt)
  (let* ((dir (file-name-directory (directory-file-name yt-test-dir)))
         (changelog (yt-test-file-string (expand-file-name "CHANGELOG.org" dir))))
    (should (string-match "^\\* \\([0-9][0-9.]*\\) (" changelog))
    (let ((released (match-string 1 changelog)))
      (should (equal (lm-version (expand-file-name "yt.el" dir)) released))
      (should (equal yt-version released)))))

(defconst yt-test-mx-only-commands
  '(yt-check-auth yt-debug-fetch-feed yt-forget-history yt-logout yt-player-mode
    yt-subscribe-browse yt-subscriptions yt-feed-subscriptions yt-url-handler-mode
    ;; Reached through + and - in feeds.
    yt-feed-save-playlist yt-feed-forget-playlist yt-subscribe yt-unsubscribe)
  "yt's commands that are meant for M-x, or reached through another key.")

(ert-deftest yt-test-every-command-has-a-key ()
  "Every interactive yt command is bound in a yt keymap, or allowlisted."
  (dolist (feature '(yt-channels yt-playlists yt-history yt-info yt-mpv yt-vlc yt-select
                                 yt-subscribe yt-url yt-doctor))
    (require feature))
  (let ((maps (list yt-map yt-feed-mode-map yt-channels-mode-map yt-playlists-mode-map
                    yt-history-mode-map yt-info-mode-map yt-playlist-mode-map
                    yt-list-mode-map yt-video-actions-map yt-player-map yt-feed-toggle-map))
        unbound)
    (mapatoms
     (lambda (symbol)
       (when (and (string-prefix-p "yt-" (symbol-name symbol))
                  (not (string-search "--" (symbol-name symbol)))
                  (commandp symbol)
                  (not (memq symbol yt-test-mx-only-commands))
                  (let ((file (symbol-file symbol 'defun)))
                    (and file (string-prefix-p "yt" (file-name-nondirectory file))))
                  ;; One map at a time: in a list, one map's key hides another's.
                  (not (seq-some (lambda (map) (where-is-internal symbol map t)) maps)))
         (push symbol unbound))))
    (should-not (sort unbound #'string<))))

(ert-deftest yt-test-keys-are-consistent ()
  "The same keys do the same in every yt list."
  (dolist (feature '(yt-channels yt-playlists yt-history yt-info)) (require feature))
  (dolist (map (list yt-feed-mode-map yt-channels-mode-map yt-playlists-mode-map
                     yt-history-mode-map yt-playlist-mode-map yt-info-mode-map))
    (should (eq (keymap-lookup map "j c") #'yt-channels))
    (should (eq (keymap-lookup map "P SPC") #'yt-player-pause)))
  (dolist (map (list yt-channels-mode-map yt-playlists-mode-map yt-history-mode-map))
    (should (eq (keymap-lookup map "/") #'yt-list-filter))
    (should (eq (keymap-lookup map "C") #'yt-list-clear-filter))
    (should (eq (keymap-lookup map "s") #'yt-list-filter-with-s)))
  (should (eq (keymap-lookup yt-feed-mode-map "s") #'yt-list-filter-with-s))
  (should (eq (keymap-lookup yt-playlists-mode-map "o") #'yt-playlists-open))
  (should (eq (keymap-lookup yt-playlist-mode-map "z") #'yt-player-shuffle-playlist))
  (should (eq (keymap-lookup yt-player-repeat-map "=") #'yt-player-normal-speed)))

(provide 'yt-tests)
;;; yt-tests.el ends here
