;;; yt-org.el --- Store org links to YouTube videos -*- lexical-binding: t; -*-

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

;; In a yt buffer, `org-store-link' stores a link to the video at
;; point, described as "Title — Channel".  If that video is playing,
;; the link starts where it is (&t=N).  The links are plain YouTube
;; URLs, which work anywhere; with `yt-url-handler-mode' on, following
;; one in org plays it in yt, from its time.
;;
;; The "yt" link type only stores links: it is never written into a
;; note, so notes do not depend on yt.  To use it, load it with org's
;; links:
;;
;;   (with-eval-after-load 'ol (require 'yt-org))

;;; Code:

(require 'ol)
(require 'yt-video)

(declare-function yt-player-now-playing "yt-player" ())

(defun yt-org--start (video)
  "Return the whole seconds VIDEO is at if it is playing, or nil."
  (when-let* (((fboundp 'yt-player-now-playing))
              (playing (yt-player-now-playing))
              ((equal (yt-video-id (car playing)) (yt-video-id video)))
              (position (cdr playing))
              ((>= position 1)))
    (floor position)))

(defun yt-org-link (video &optional start)
  "Return the URL of VIDEO, starting at START seconds if non-nil."
  (concat (format "https://www.youtube.com/watch?v=%s" (yt-video-id video))
          (if start (format "&t=%d" start) "")))

(defun yt-org-description (video)
  "Return the description of an org link to VIDEO."
  (let ((title (or (yt-video-title video) (yt-video-id video)))
        (channel (yt-video-channel video)))
    (if channel (concat title " — " channel) title)))

(defun yt-org-store-link (&optional _interactive)
  "Store a link to the video at point in a yt buffer, or return nil."
  (when-let* ((video (yt-video-at-point))
              ((yt-video-id video)))
    (org-link-store-props :type "https"
                          :link (yt-org-link video (yt-org--start video))
                          :description (yt-org-description video))
    t))

(org-link-set-parameters "yt" :store #'yt-org-store-link)

(provide 'yt-org)
;;; yt-org.el ends here
