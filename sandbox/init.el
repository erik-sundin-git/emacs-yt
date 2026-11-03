;;; init.el --- Config of the yt sandbox Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The whole configuration of `nix run .#sandbox': default Emacs plus
;; yt, loaded from the working tree.  The wrapper starts Emacs with
;; -q --no-site-file, so no host config is read: not ~/.emacs.d, not
;; ~/.emacs, not default.el and not the site-lisp of the Nix profiles.
;; Emacs keeps its own files (history, custom.el, auto-saves) in
;; .sandbox/emacs.d, and yt its state and cache in yt-sandbox
;; directories of $XDG_STATE_HOME and $XDG_CACHE_HOME, outside the
;; checkout.
;;
;; Keep this file minimal: it is meant to show how yt behaves in a
;; stock Emacs.  Reload yt after editing with M-x load-library RET yt.

;;; Code:

(defconst yt-sandbox-repo (file-name-as-directory (getenv "YT_SANDBOX_REPO"))
  "The emacs-yt checkout the sandbox loads yt from.")

;; Customizations go to .sandbox/emacs.d, never to this file.
(setq custom-file (locate-user-emacs-file "custom.el"))
(load custom-file t t)

(add-to-list 'load-path yt-sandbox-repo)
(setq load-prefer-newer t)

;; yt's per-session files, separate from a yt in the host Emacs.
(setq yt-runtime-directory (getenv "YT_SANDBOX_RUNTIME_DIR"))

;; Never the host yt's state, cookies and history.
(require 'yt)
(when (equal (file-name-as-directory (expand-file-name yt-state-directory))
             (file-name-as-directory (expand-file-name (getenv "YT_SANDBOX_REAL_STATE"))))
  (error "The sandbox would use the host yt's state in %s" yt-state-directory))

;; Generate the autoloads from the working tree, as installing the
;; package would.  The file sits next to the sources (git ignores it)
;; because autoloads name files relative to it.
(let ((autoloads (expand-file-name "yt-autoloads.el" yt-sandbox-repo)))
  (loaddefs-generate yt-sandbox-repo autoloads)
  (load autoloads nil t))

;; The suggested binding from yt's README.
(keymap-global-set "C-c y" yt-map)

;;; init.el ends here
