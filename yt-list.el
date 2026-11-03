;;; yt-list.el --- Shared parts of the yt list buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
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

;; What the yt list buffers (feed, channels, playlists, history, the
;; player's playlist) share.  For now that is loading the embark and
;; marginalia integrations of yt-select.el as soon as either package is
;; loaded, so that embark acts on the rows of every yt buffer without
;; yt-select having been used first.

;;; Code:

(defvar yt-list--integrations-scheduled nil
  "Non-nil once loading yt-select for embark or marginalia was scheduled.")

(defun yt-list--load-integrations (&rest _)
  "Load yt-select once embark or marginalia is loaded.
yt-select registers yt's embark target finder and actions and its
marginalia annotations.  It is loaded from a timer, because this runs
from `after-load-functions', possibly while yt's own files are still
loading, and yt-select requires most of them."
  (when (and (not yt-list--integrations-scheduled)
             (not (featurep 'yt-select))
             (or (featurep 'embark) (featurep 'marginalia)))
    (setq yt-list--integrations-scheduled t)
    (run-at-time 0 nil #'require 'yt-select)))

(yt-list--load-integrations)
(add-hook 'after-load-functions #'yt-list--load-integrations)

(provide 'yt-list)
;;; yt-list.el ends here
