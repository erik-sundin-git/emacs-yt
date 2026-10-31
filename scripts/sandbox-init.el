;;; sandbox-init.el --- Init file for the yt sandbox Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loaded by the init.el that `nix run .#sandbox' generates.  It loads
;; yt straight from the working tree, in an Emacs that is separate from
;; the host Emacs: its own init directory, and its own yt state, cache
;; and runtime directories (set up by the sandbox wrapper), so nothing
;; it does touches the host's data.

;;; Code:

(setq load-prefer-newer t
      inhibit-startup-screen t
      custom-file (expand-file-name "custom.el" user-emacs-directory)
      frame-title-format '("yt sandbox — %b"))

(add-to-list 'load-path (file-name-as-directory (getenv "YT_SANDBOX_REPO")))
(setq yt-runtime-directory (getenv "YT_SANDBOX_RUNTIME_DIR"))

(require 'yt)
(keymap-global-set "C-c y" yt-map)

(setq initial-scratch-message
      (format ";; yt sandbox: Emacs %s, separate from the host Emacs.
;; Code:    %s
;; State:   %s
;; Runtime: %s
;; Reload yt after editing with M-x load-library RET yt RET.

"
              emacs-version (getenv "YT_SANDBOX_REPO")
              yt-state-directory (getenv "YT_SANDBOX_RUNTIME_DIR")))

;;; sandbox-init.el ends here
