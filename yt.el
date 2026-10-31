;;; yt.el --- Browse and play your YouTube subscriptions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin

;; Author: Erik Sundin <mail@eriksundin.com>
;; Maintainer: Erik Sundin <mail@eriksundin.com>
;; URL: https://github.com/erik-sundin-git/emacs-yt
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; yt shows the subscription feed of your YouTube account in an Emacs
;; buffer and plays videos in an mpv window controlled from Emacs, or
;; streams them to VLC.  It signs in with cookies exported from a
;; dedicated Chromium profile and fetches everything through yt-dlp;
;; there is no OAuth and no API key.
;;
;; This file holds the customization groups, the shared state and
;; runtime directories, the `yt-map' prefix keymap and the `yt' entry
;; command.  See docs/PLAN.md in the repository for the design.
;;
;; Prior art: empv and mpv.el, whose mpv IPC handling informed the
;; design of the mpv backend.

;;; Code:

(require 'xdg)

(defgroup yt nil
  "Browse and play your YouTube subscriptions."
  :group 'multimedia
  :prefix "yt-"
  :link '(url-link :tag "Homepage" "https://github.com/erik-sundin-git/emacs-yt"))

(defcustom yt-state-directory (expand-file-name "yt" (xdg-state-home))
  "Directory for persistent yt state, such as cookies and the cache.
It is created with mode 0700, and yt refuses to use it if it is
accessible by other users."
  :type 'directory
  :package-version '(yt . "0.1.0"))

(defcustom yt-runtime-directory nil
  "Directory for per-session files, such as cookie copies and mpv sockets.
nil means the \"yt\" subdirectory of $XDG_RUNTIME_DIR.  The
directory must be owned by the current user and have mode 0700;
yt never falls back to a shared directory such as /tmp."
  :type '(choice (const :tag "$XDG_RUNTIME_DIR/yt" nil) directory)
  :package-version '(yt . "0.1.0"))

(defun yt--ensure-private-directory (dir)
  "Create DIR with mode 0700 if it is missing, then check it is private.
Signal a `user-error' if DIR is a symbolic link, is not a directory,
is not owned by the current user or is accessible by group or others.
Return DIR as a directory name."
  (setq dir (directory-file-name (expand-file-name dir)))
  (unless (or (file-exists-p dir) (file-symlink-p dir))
    (with-file-modes #o700
      (make-directory dir t)))
  (when (file-symlink-p dir)
    (user-error "Refusing to use %s: it is a symbolic link" dir))
  (let ((attrs (file-attributes dir 'integer)))
    (unless (eq t (file-attribute-type attrs))
      (user-error "Refusing to use %s: it is not a directory" dir))
    (unless (= (file-attribute-user-id attrs) (user-uid))
      (user-error "Refusing to use %s: it is not owned by you" dir))
    (unless (zerop (logand (file-modes dir) #o077))
      (user-error "Refusing to use %s: its mode is %o, but yt requires 700"
                  dir (file-modes dir))))
  (file-name-as-directory dir))

(defun yt-ensure-state-directory ()
  "Return `yt-state-directory', creating it with mode 0700 if needed."
  (yt--ensure-private-directory yt-state-directory))

(defun yt-ensure-runtime-directory ()
  "Return the runtime directory, creating it with mode 0700 if needed.
This is `yt-runtime-directory', or the \"yt\" subdirectory of
$XDG_RUNTIME_DIR when that option is nil."
  (yt--ensure-private-directory
   (or yt-runtime-directory
       (let ((xdg (getenv "XDG_RUNTIME_DIR")))
         (unless (and xdg (file-directory-p xdg))
           (user-error
            "XDG_RUNTIME_DIR is not set, and yt will not fall back to /tmp"))
         (expand-file-name "yt" xdg)))))

;;;###autoload
(defun yt ()
  "Show the subscription feed of your YouTube account.
Not implemented yet: the feed arrives in milestone M2."
  (interactive)
  (user-error "The yt subscription feed is not implemented yet"))

;;;###autoload
(defvar-keymap yt-map
  :doc "Prefix keymap for yt commands.
Bind it to a key of your choice, for example \\`C-c y'."
  "y" #'yt)

(provide 'yt)
;;; yt.el ends here
