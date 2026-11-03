;;; yt-sponsorblock.el --- Skip sponsored segments with SponsorBlock -*- lexical-binding: t; -*-

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

;; SponsorBlock (https://sponsor.ajay.app) is a community database of
;; segments of YouTube videos: sponsors, self-promotion, reminders to
;; subscribe, and more.  yt asks it for a video's segments with curl
;; when mpv is about to play the video, and mpv skips the segments of
;; the categories in `yt-sponsorblock-categories'.
;;
;; The request names only the first 4 characters of the SHA-256 hash of
;; the video id, which many videos share; yt picks the video's segments
;; from the answer.  It carries no cookies.  Segments are kept for the
;; session.  When SponsorBlock cannot be reached, the video plays
;; without skipping.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'url-util)
(require 'yt)
(require 'yt-process)

(defconst yt-sponsorblock-category-names
  '((sponsor . "sponsor")
    (selfpromo . "self-promotion")
    (interaction . "interaction reminder")
    (intro . "intro")
    (outro . "endcards")
    (preview . "preview")
    (hook . "hook")
    (filler . "filler")
    (music_offtopic . "non-music section"))
  "The SponsorBlock categories of skippable segments, with their names.")

(defcustom yt-sponsorblock-categories '(sponsor selfpromo interaction)
  "The SponsorBlock categories of the segments mpv skips.
nil turns SponsorBlock off: yt then never contacts it."
  :type '(set (const :tag "Sponsor" sponsor)
              (const :tag "Unpaid or self-promotion" selfpromo)
              (const :tag "Interaction reminder (subscribe, like)" interaction)
              (const :tag "Intro animation" intro)
              (const :tag "Endcards and credits" outro)
              (const :tag "Preview or recap" preview)
              (const :tag "Hook or greetings" hook)
              (const :tag "Filler tangent" filler)
              (const :tag "Non-music section of music videos" music_offtopic))
  :group 'yt-player
  :package-version '(yt . "0.2.0"))

(defcustom yt-sponsorblock-api "https://sponsor.ajay.app"
  "The SponsorBlock server."
  :type 'string
  :group 'yt-player
  :package-version '(yt . "0.2.0"))

(defvar yt-sponsorblock-duration-tolerance 5
  "Seconds a segment's video may differ in length from the video played.
Segments submitted for an older cut of the video are ignored.")

(defvar yt-sponsorblock--segments (make-hash-table :test #'equal)
  "The segments of each video id fetched in this session, or `none'.")

(defvar yt-sponsorblock--waiting (make-hash-table :test #'equal)
  "The callbacks waiting for the segments of each video id being fetched.")

(defun yt-sponsorblock--url (id)
  "Return the URL asking for the segments of the videos sharing ID's hash prefix."
  (format "%s/api/skipSegments/%s?%s"
          (string-trim-right yt-sponsorblock-api "/")
          (substring (secure-hash 'sha256 id) 0 4)
          (url-build-query-string
           `(("service" "YouTube")
             ("categories" ,(json-serialize
                             (vconcat (mapcar (lambda (c) (symbol-name (car c)))
                                              yt-sponsorblock-category-names))))
             ("actionTypes" "[\"skip\"]")))))

(defun yt-sponsorblock--parse (id json)
  "Return the segments of ID in JSON, SponsorBlock's answer, as plists.
Each has :start, :end and :video-duration in seconds, :category, a
symbol, and :uuid."
  (when-let* ((entry (seq-find (lambda (e) (equal (plist-get e :videoID) id)) json)))
    (cl-loop for segment in (plist-get entry :segments)
             for (start end) = (plist-get segment :segment)
             for category = (intern-soft (or (plist-get segment :category) ""))
             when (and (numberp start) (numberp end) (< start end)
                       (equal (plist-get segment :actionType) "skip")
                       (assq category yt-sponsorblock-category-names))
             collect (list :start start :end end :category category
                           :uuid (plist-get segment :UUID)
                           :video-duration (plist-get segment :videoDuration)))))

(defun yt-sponsorblock--done (id segments)
  "Keep SEGMENTS as those of ID, if non-nil, and call the waiting callbacks."
  (let ((callbacks (gethash id yt-sponsorblock--waiting)))
    (remhash id yt-sponsorblock--waiting)
    (when segments
      (puthash id segments yt-sponsorblock--segments))
    (dolist (callback callbacks)
      (funcall callback (and (listp segments) segments)))))

(defun yt-sponsorblock-fetch (id &optional callback)
  "Fetch the SponsorBlock segments of the video ID.
Call CALLBACK, if non-nil, with them, or with nil if there are none
or SponsorBlock could not be reached.  Segments are fetched once per
session; a failed fetch is tried again next time."
  (cond
   ((or (not id) (not yt-sponsorblock-categories))
    (when callback (yt-process-deliver callback nil)))
   ((gethash id yt-sponsorblock--segments)
    (when callback (yt-process-deliver callback (yt-sponsorblock-segments id))))
   (t
    (let ((first (not (gethash id yt-sponsorblock--waiting))))
      (puthash id (append (gethash id yt-sponsorblock--waiting) (and callback (list callback)))
               yt-sponsorblock--waiting)
      (when (and first
                 (not (yt-process-curl
                       (yt-sponsorblock--url id)
                       :key (cons 'yt-sponsorblock id) :max-time 10
                       :on-response
                       (lambda (response)
                         (yt-sponsorblock--done id (yt-sponsorblock--response id response)))
                       :on-error
                       (lambda (err)
                         (yt-process-log "SponsorBlock: %s" (plist-get err :message))
                         (yt-sponsorblock--done id nil)))))
        ;; Busy: no callback will come.  Answer from a timer, as always.
        (yt-process-deliver #'yt-sponsorblock--done id nil))))))

(defun yt-sponsorblock--response (id response)
  "Return the segments of ID in RESPONSE, `none', or nil on failure.
RESPONSE is (STATUS . BODY).  A body that is not JSON is a failure,
tried again next time, not \"no segments\"."
  (pcase-let ((`(,status . ,body) response))
    (pcase status
      (404 'none)                       ; No segments for this hash prefix.
      (200 (let ((json (condition-case nil
                           (yt-process-parse-json body)
                         (json-error (yt-process-log "SponsorBlock: answer is not JSON")
                                     'invalid))))
             (and (not (eq json 'invalid))
                  (or (yt-sponsorblock--parse id json) 'none))))
      (_ (yt-process-log "SponsorBlock: HTTP %d" status)
         nil))))

(defun yt-sponsorblock-segments (id)
  "Return the fetched segments of the video ID, or nil."
  (let ((segments (and id (gethash id yt-sponsorblock--segments))))
    (and (listp segments) segments)))

(defun yt-sponsorblock-skippable (segments duration)
  "Return the SEGMENTS mpv should skip in a video of DURATION seconds.
They are those of `yt-sponsorblock-categories', and not submitted for
a cut of the video of another length."
  (seq-filter
   (lambda (segment)
     (let ((length (plist-get segment :video-duration)))
       (and (memq (plist-get segment :category) yt-sponsorblock-categories)
            (not (and (numberp length) (> length 0) (numberp duration) (> duration 0)
                      (> (abs (- length duration)) yt-sponsorblock-duration-tolerance))))))
   segments))

(defun yt-sponsorblock-category-name (category)
  "Return the name of the SponsorBlock CATEGORY, a symbol."
  (or (cdr (assq category yt-sponsorblock-category-names))
      (symbol-name category)))

(provide 'yt-sponsorblock)
;;; yt-sponsorblock.el ends here
