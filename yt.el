;;; yt.el --- Browse and play your YouTube subscriptions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin

;; Author: Erik Sundin <mail@eriksundin.com>
;; Maintainer: Erik Sundin <mail@eriksundin.com>
;; URL: https://github.com/erik-sundin-git/emacs-yt
;; Version: 0.2.0
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

(defconst yt-version (package-get-version)
  "The version of yt.")

(defgroup yt nil
  "Browse and play your YouTube subscriptions."
  :group 'multimedia
  :prefix "yt-"
  :link '(url-link :tag "Homepage" "https://github.com/erik-sundin-git/emacs-yt"))

(defgroup yt-backend nil
  "How yt runs yt-dlp and signs in to YouTube."
  :group 'yt
  :prefix "yt-")

(defgroup yt-feed nil
  "The yt subscription feed."
  :group 'yt
  :prefix "yt-feed-")

(defgroup yt-player nil
  "How yt plays videos."
  :group 'yt
  :prefix "yt-")

(defcustom yt-player-backend 'auto
  "The player used by \\[yt-play].
`auto' means mpv when it is installed (and yt's mpv backend is
available), otherwise VLC."
  :type '(choice (const :tag "mpv if installed, else VLC" auto)
                 (const :tag "mpv" mpv)
                 (const :tag "VLC" vlc)
                 (symbol :tag "Other backend"))
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-player-format "bv*[height<=1080]+ba/b"
  "The yt-dlp format selector for the streams to play.
See \"FORMAT SELECTION\" in yt-dlp's documentation.  If the format
is not available, yt retries once with \"b\"."
  :type 'string
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-mpv-program "mpv"
  "Name or file name of the mpv program."
  :type 'string
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-mpv-extra-args '("--hwdec=auto-safe")
  "Extra arguments passed to mpv when it starts.
Add \"--keep-open=yes\" to keep the last frame on screen when the
playlist ends."
  :type '(repeat string)
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-mark-watched-when 'near-end
  "When mpv marks a video as watched.
`near-end' means once you have played `yt-player-watched-threshold'
of it, or it played to the end; `start' means when it starts.  VLC
always marks videos when they start, since yt cannot follow it."
  :type '(choice (const :tag "Near the end" near-end)
                 (const :tag "When it starts" start))
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-player-watched-threshold 0.9
  "Fraction of a video that counts as having watched it."
  :type 'float
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-player-resume t
  "Non-nil means videos resume where you stopped watching them."
  :type 'boolean
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-vlc-program "vlc"
  "Name or file name of the VLC program."
  :type 'string
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-vlc-extra-args nil
  "Extra arguments passed to VLC before the stream URLs."
  :type '(repeat string)
  :group 'yt-player
  :package-version '(yt . "0.1.0"))

(defcustom yt-ytdlp-program "yt-dlp"
  "Name or file name of the yt-dlp program."
  :type 'string
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-ytdlp-extra-args nil
  "Extra arguments passed to every yt-dlp invocation.
Arguments that would print secrets, change the output format or
replace yt's cookie handling, such as \"--verbose\",
\"--print-traffic\", \"--print\" or \"--cookies\", are refused."
  :type '(repeat string)
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-ytdlp-min-version "2026.06.01"
  "Oldest yt-dlp version that yt accepts without a warning.
The value has the form YYYY.MM.DD, like the output of
\"yt-dlp --version\"."
  :type 'string
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-ytdlp-update-hint "update yt-dlp (it comes from %s)"
  "How to tell the user to update yt-dlp.
The string is passed to `format' with the absolute file name of
the yt-dlp program."
  :type 'string
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-export-cookies-program "yt-export-cookies"
  "Name or file name of the cookie exporter shipped in yt's Nix flake."
  :type 'string
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-chromium-directory (expand-file-name "chromium" (xdg-config-home))
  "Chromium's user data directory, which holds \"Local State\"."
  :type 'directory
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-chromium-program "chromium"
  "Name or file name of the Chromium program.
yt opens a channel in the Chromium profile it signs in with when it
cannot subscribe to the channel itself."
  :type 'string
  :group 'yt-backend
  :package-version '(yt . "0.2.0"))

(defcustom yt-cookie-profile nil
  "Chromium profile directory that yt reads YouTube cookies from.
nil means the profile chosen with \\[yt-login], which yt remembers
in its state directory.  Use a profile that is signed in only to
YouTube: the cookies are Google session tokens."
  :type '(choice (const :tag "Chosen with yt-login" nil)
                 (string :tag "Profile directory, e.g. \"Profile 1\""))
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-process-timeout 120
  "Seconds after which a yt-dlp run is interrupted."
  :type 'natnum
  :group 'yt-backend
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-limit 100
  "Number of videos to fetch from the subscription feed."
  :type 'natnum
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-stop-after-known 10
  "Stop a feed refresh after this many videos in a row that are cached.
nil means always fetch `yt-feed-limit' videos.  The first refresh of
a session, and \\[universal-argument] \\[yt-feed-refresh], always fetch them all."
  :type '(choice (natnum :tag "Videos") (const :tag "Never stop early" nil))
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-refresh-interval 900
  "Seconds for which \\[yt] shows the feed without refreshing it."
  :type 'natnum
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-hide-watched nil
  "Non-nil means the feed hides videos you have watched."
  :type 'boolean
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-hide-shorts nil
  "Non-nil means the feed hides Shorts."
  :type 'boolean
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-hide-upcoming nil
  "Non-nil means the feed hides upcoming premieres and live streams."
  :type 'boolean
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-feed-thumbnails nil
  "Non-nil means the feed shows thumbnails, on displays that can.
Thumbnails are downloaded from i.ytimg.com with `yt-curl-program'
into the \"yt/thumbs\" directory of `xdg-cache-home'."
  :type 'boolean
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defcustom yt-curl-program "curl"
  "Name or file name of the curl program.
It downloads thumbnails, and sends the requests that subscribe to
channels and unsubscribe from them."
  :type 'string
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

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

(defcustom yt-cache-file nil
  "SQLite file holding the video cache and watch history.
nil means \"yt.sqlite\" in `yt-state-directory'."
  :type '(choice (const :tag "yt.sqlite in the state directory" nil) file)
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

;;;; Clock

(defvar yt--now-function #'float-time
  "Function returning the current time in seconds since the epoch.
Tests bind it to control the clock.")

(defun yt--now ()
  "Return the current time in seconds since the epoch."
  (funcall yt--now-function))

;;;; Persistent state

(defun yt--state-file ()
  "Return the name of the file holding yt's small persistent state."
  (expand-file-name "state.eld" yt-state-directory))

(defun yt--state-read ()
  "Return the alist stored in the state file, or nil."
  (let ((file (yt--state-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((data (ignore-errors (read (current-buffer)))))
          (and (listp data) data))))))

(defun yt-state-get (key)
  "Return the value stored for KEY in yt's state file, or nil."
  (alist-get key (yt--state-read)))

(defun yt-state-put (key value)
  "Store VALUE for KEY in yt's state file and return VALUE.
The file is replaced atomically and has mode 0600."
  (let* ((dir (yt-ensure-state-directory))
         (data (cons (cons key value) (assq-delete-all key (yt--state-read))))
         (tmp (with-file-modes #o600
                (make-temp-file (expand-file-name ".state-" dir)))))
    (let ((coding-system-for-write 'utf-8-unix)
          (print-length nil)
          (print-level nil))
      (with-temp-file tmp
        (insert ";; yt state, written by yt.  -*- mode: lisp-data -*-\n")
        (prin1 data (current-buffer))
        (insert "\n")))
    (set-file-modes tmp #o600)
    (rename-file tmp (yt--state-file) t)
    value))

;;;###autoload
(defun yt ()
  "Show the subscription feed of your YouTube account.
The feed appears at once from the cache and is then refreshed, unless
it was refreshed less than `yt-feed-refresh-interval' seconds ago.
The first time, this signs in with \\[yt-login]."
  (interactive)
  (require 'yt-feed)
  (yt-feed-subscriptions))

;;;###autoload
(defalias 'yt-subscriptions #'yt
  "Show the subscription feed, yt's main view; the same as \\[yt].")

(declare-function yt-feed-subscriptions "yt-feed" ())
(declare-function yt-search "yt-feed" (query))
(declare-function yt-select-play "yt-select" (video))
(declare-function yt-channels "yt-channels" ())
(declare-function yt-saved-playlists "yt-playlists" ())
(declare-function yt-player-playlist "yt-player" ())
(declare-function yt-play-url "yt-player" (url))
(declare-function yt-player-stop "yt-player" ())
(declare-function yt-player-quit "yt-player" ())
(declare-function yt-player-pause "yt-player" ())
(declare-function yt-player-seek-forward "yt-player" (&optional seconds))
(declare-function yt-player-seek-backward "yt-player" (&optional seconds))
(declare-function yt-player-seek-forward-more "yt-player" ())
(declare-function yt-player-seek-backward-more "yt-player" ())
(declare-function yt-player-faster "yt-player" ())
(declare-function yt-player-slower "yt-player" ())
(declare-function yt-player-normal-speed "yt-player" ())
(declare-function yt-player-next "yt-player" ())
(declare-function yt-player-previous "yt-player" ())
(declare-function yt-player-show-log "yt-player" ())
(declare-function yt-player-shuffle-playlist "yt-player" ())
(declare-function yt-login "yt-auth" (&optional choose))
(declare-function yt-doctor "yt-doctor" ())

;;;###autoload
(defvar-keymap yt-player-map
  :doc "Keymap for controlling the player.
It is bound under \\`P' in yt buffers, and its keys are also in `yt-map'.
Each binding has a short label, which which-key shows."
  "SPC" '("pause" . yt-player-pause)
  "<left>" '("back 5 s" . yt-player-seek-backward)
  "<right>" '("forward 5 s" . yt-player-seek-forward)
  "<down>" '("back 1 min" . yt-player-seek-backward-more)
  "<up>" '("forward 1 min" . yt-player-seek-forward-more)
  "[" '("slower" . yt-player-slower)
  "]" '("faster" . yt-player-faster)
  "=" '("normal speed" . yt-player-normal-speed)
  "n" '("next video" . yt-player-next)
  "p" '("previous video" . yt-player-previous)
  "l" '("playlist" . yt-player-playlist)
  "z" '("shuffle playlist" . yt-player-shuffle-playlist)
  "U" '("undo skip" . yt-player-unskip)
  "K" '("skipping on/off" . yt-player-toggle-skipping)
  "S" '("stop" . yt-player-stop)
  "Q" '("quit player" . yt-player-quit)
  "!" '("player log" . yt-player-show-log))

;;;###autoload
(defvar-keymap yt-map
  :doc "Prefix keymap for yt commands.
Bind it to a key of your choice, for example \\`C-c y'.  Its main
view, the subscription feed, is on \\`y' and \\`RET'.  Each binding
has a short label, which which-key shows."
  :parent yt-player-map
  "y" '("subscriptions" . yt)
  "RET" '("subscriptions" . yt)
  "c" '("channels" . yt-channels)
  "h" '("history" . yt-history)
  "P" '("saved playlists" . yt-saved-playlists)
  "s" '("search" . yt-search)
  "f" '("find video" . yt-select-play)
  "u" '("play URL" . yt-play-url)
  "L" '("sign in" . yt-login)
  "d" '("diagnostics" . yt-doctor))

(provide 'yt)
;;; yt.el ends here
