;;; yt-video.el --- The video record used throughout yt -*- lexical-binding: t; -*-

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

;; The `yt-video' structure, its construction from yt-dlp JSON, and
;; the formatting of ages and durations.  Everything here is a pure
;; function apart from the clock, which comes from `yt--now'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yt)

(cl-defstruct (yt-video (:constructor yt-video--make)
                        (:copier nil))
  "A YouTube video as yt shows it.
DURATION and TIMESTAMP are in seconds and may be nil.
TIMESTAMP-APPROX-P is non-nil when TIMESTAMP was derived from text
such as \"3 hours ago\".  VIEWS is usually nil in the subscription
feed.  LIVE-STATUS is nil or one of the symbols `is_live',
`is_upcoming', `was_live', `post_live' and `not_live'.
FEED-INDEX is the position in the feed it was fetched from, which
is the order to show it in.  FETCHED-AT, WATCHED and POSITION (the
resume position in seconds) are local state."
  id title channel channel-id channel-url duration timestamp
  timestamp-approx-p views live-status thumbnail url short-p
  feed-index fetched-at watched position)

(defun yt-video--string (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun yt-video--number (value)
  "Return VALUE if it is a number, else nil."
  (and (numberp value) value))

(defun yt-video--upload-date (value)
  "Return the epoch time of the YYYYMMDD date string VALUE, or nil."
  (when (and (stringp value)
             (string-match "\\`\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\'"
                           value))
    (time-convert (encode-time
                   (list 0 0 0
                         (string-to-number (match-string 3 value))
                         (string-to-number (match-string 2 value))
                         (string-to-number (match-string 1 value))
                         nil nil 0))
                  'integer)))

(defun yt-video--entry-url (entry id)
  "Return the YouTube page URL for the yt-dlp ENTRY with ID.
The entry's own \"url\" is used only when it is a YouTube page, since
for a fully extracted video it is a stream URL."
  (let ((url (yt-video--string (plist-get entry :url))))
    (or (and url (string-prefix-p "https://www.youtube.com/" url) url)
        (yt-video--string (plist-get entry :webpage_url))
        (format "https://www.youtube.com/watch?v=%s" id))))

(defun yt-video--entry-thumbnail (entry)
  "Return the URL of the largest thumbnail of the yt-dlp ENTRY, or nil."
  (or (yt-video--string (plist-get (car (last (plist-get entry :thumbnails)))
                                   :url))
      (yt-video--string (plist-get entry :thumbnail))))

(defun yt-video-from-json (entry &optional approx-p)
  "Return a `yt-video' for the yt-dlp JSON ENTRY, a plist, or nil.
Return nil if ENTRY has no id.  APPROX-P non-nil means the entry's
timestamp is approximate, as with the extractor argument
\"youtubetab:approximate_date\"."
  (let ((id (yt-video--string (plist-get entry :id))))
    (when id
      (let ((url (yt-video--entry-url entry id))
            (timestamp (or (yt-video--number (plist-get entry :timestamp))
                           (yt-video--number
                            (plist-get entry :release_timestamp))
                           (yt-video--upload-date
                            (plist-get entry :upload_date))))
            (live (plist-get entry :live_status)))
        (yt-video--make
         :id id
         :title (yt-video--string (plist-get entry :title))
         ;; Entries of a channel's uploads name the channel only as the
         ;; playlist's.
         :channel (or (yt-video--string (plist-get entry :channel))
                      (yt-video--string (plist-get entry :uploader))
                      (yt-video--string (plist-get entry :playlist_channel))
                      (yt-video--string (plist-get entry :playlist_uploader)))
         :channel-id (or (yt-video--string (plist-get entry :channel_id))
                         (yt-video--string (plist-get entry :playlist_channel_id)))
         :channel-url (or (yt-video--string (plist-get entry :channel_url))
                          (yt-video--string (plist-get entry :uploader_url)))
         :duration (yt-video--number (plist-get entry :duration))
         :timestamp timestamp
         :timestamp-approx-p (and approx-p timestamp t)
         :views (yt-video--number (plist-get entry :view_count))
         :live-status (and (yt-video--string live) (intern live))
         :thumbnail (yt-video--entry-thumbnail entry)
         :url url
         :short-p (and (string-match-p "/shorts/" url) t))))))

(defconst yt-video--url-id-regexp
  (concat "\\`https?://\\(?:\\(?:www\\.\\|m\\.\\|music\\.\\)?youtube\\.com/"
          "\\(?:watch\\?\\(?:.*&\\)?v=\\|shorts/\\|live/\\|embed/\\)"
          "\\|youtu\\.be/\\)"
          "\\([A-Za-z0-9_-]\\{11\\}\\)\\(?:[?&#/]\\|\\'\\)")
  "Regexp matching a YouTube video URL; group 1 is the video id.")

(defun yt-video-from-url (url)
  "Return a `yt-video' for the YouTube video URL, or nil if it is not one.
A bare 11-character video id is accepted too."
  (setq url (string-trim url))
  (let ((id (cond ((string-match yt-video--url-id-regexp url) (match-string 1 url))
                  ((string-match-p "\\`[A-Za-z0-9_-]\\{11\\}\\'" url) url))))
    (when id
      (let ((short-p (and (string-match-p "/shorts/" url) t)))
        (yt-video--make
         :id id :short-p short-p
         :url (format (if short-p
                          "https://www.youtube.com/shorts/%s"
                        "https://www.youtube.com/watch?v=%s")
                      id))))))

(defvar-local yt-video-at-point-function nil
  "Function returning the `yt-video' at point in this buffer, or nil.
yt's major modes set it, so that commands such as `yt-play' work in
all of them.")

(defun yt-video-at-point ()
  "Return the `yt-video' at point, or nil."
  (and yt-video-at-point-function (funcall yt-video-at-point-function)))

(defun yt-video--age-string (seconds)
  "Return SECONDS, a non-negative duration, in its largest whole unit."
  (cond ((< seconds 3600) (format "%dm" (/ seconds 60)))
        ((< seconds 86400) (format "%dh" (/ seconds 3600)))
        ((< seconds (* 7 86400)) (format "%dd" (/ seconds 86400)))
        ((< seconds (* 30 86400)) (format "%dw" (/ seconds (* 7 86400))))
        ((< seconds (* 365 86400)) (format "%dmo" (/ seconds (* 30 86400))))
        (t (format "%dy" (/ seconds (* 365 86400))))))

(defun yt-video-format-age (timestamp &optional now)
  "Return how long ago TIMESTAMP was, such as \"3h\" or \"2w\".
A future TIMESTAMP gives \"in2h\".  Return \"\" if TIMESTAMP is nil.
NOW defaults to the current time."
  (if (not timestamp)
      ""
    (let ((delta (truncate (- (or now (yt--now)) timestamp))))
      (cond ((< (abs delta) 60) (if (< delta 0) "soon" "now"))
            ((< delta 0) (concat "in" (yt-video--age-string (- delta))))
            (t (yt-video--age-string delta))))))

(defun yt-video-format-duration (seconds)
  "Return SECONDS as \"M:SS\" or \"H:MM:SS\", or \"\" if it is nil."
  (if (not seconds)
      ""
    (let* ((s (truncate seconds))
           (h (/ s 3600))
           (m (/ (% s 3600) 60)))
      (if (> h 0)
          (format "%d:%02d:%02d" h m (% s 60))
        (format "%d:%02d" m (% s 60))))))

(provide 'yt-video)
;;; yt-video.el ends here
