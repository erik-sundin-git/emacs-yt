;;; yt-thumbs.el --- Video thumbnails -*- lexical-binding: t; -*-

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

;; Thumbnails come from i.ytimg.com, fetched with curl (without
;; cookies, and never through url.el, which would send its own cookies)
;; into a cache directory.  At most four downloads run at once, each
;; video is fetched only once, and a download is written to a ".part"
;; file that is renamed when complete, so a half-written image is never
;; shown.  `yt-thumbs-changed-functions' runs when one arrives.

;;; Code:

(require 'xdg)
(require 'yt)
(require 'yt-process)

(defcustom yt-thumbs-height 90
  "Height of the thumbnails in the feed, in pixels.
The images YouTube serves are 180 pixels high; larger thumbnails
are scaled up.  A change shows in feed buffers after \\`t i' twice."
  :type 'natnum
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defvar yt-thumbs-changed-functions nil
  "Abnormal hook run with a video id when its thumbnail was downloaded.")

(defvar yt-thumbs--queue (yt-process-queue-create 4)
  "Queue limiting how many thumbnails are downloaded at once.")

(defvar yt-thumbs--pending (make-hash-table :test #'equal)
  "Ids of the videos whose thumbnails are queued or downloading.")

(defvar yt-thumbs--failed (make-hash-table :test #'equal)
  "When the thumbnail of each video id last failed to download.")

(defvar yt-thumbs-retry-after 600
  "Seconds after which a thumbnail that failed to download is tried again.")

(defvar yt-thumbs--directory nil
  "The thumbnail directory, once it was created and checked.")

(defvar yt-thumbs--curl-missing nil
  "Non-nil once curl was found missing in this session.")

(defun yt-thumbs-directory ()
  "Return the thumbnail cache directory, creating it if needed."
  (let ((dir (expand-file-name "yt/thumbs" (xdg-cache-home))))
    (if (equal yt-thumbs--directory dir)
        dir
      (setq yt-thumbs--directory
            (directory-file-name (yt--ensure-private-directory dir))))))

(defun yt-thumbs--valid-id-p (id)
  "Return non-nil if ID is safe to use in a file name and URL."
  (and (stringp id) (string-match-p "\\`[A-Za-z0-9_-]+\\'" id)))

(defun yt-thumbs-file (id)
  "Return the file name of the thumbnail of the video ID."
  (expand-file-name (concat id ".jpg") (yt-thumbs-directory)))

(defun yt-thumbs-url (id)
  "Return the URL of the thumbnail of the video ID."
  (format "https://i.ytimg.com/vi/%s/mqdefault.jpg" id))

(defun yt-thumbs-image (id)
  "Return the image of the thumbnail of ID, or nil if it is not cached."
  (when (yt-thumbs--valid-id-p id)
    (let ((file (yt-thumbs-file id)))
      (when (file-exists-p file)
        (create-image file nil nil :height yt-thumbs-height :ascent 'center)))))

(defun yt-thumbs--download (id done)
  "Download the thumbnail of ID, then call DONE."
  (let* ((file (yt-thumbs-file id))
         (part (concat file ".part"))
         (finish (lambda (ok &optional cancelled)
                   (remhash id yt-thumbs--pending)
                   ;; The queue slot is freed whatever happens here.
                   (unwind-protect
                       (if ok
                           (progn (rename-file part file t)
                                  (run-hook-with-args 'yt-thumbs-changed-functions id))
                         (ignore-errors (delete-file part))
                         ;; A cancelled download may be requested again.
                         (unless cancelled
                           (puthash id (yt--now) yt-thumbs--failed)))
                     (funcall done)))))
    (unless (yt-process-run
             yt-curl-program
             (list "--silent" "--fail" "--proto" "=https" "--max-time" "20"
                   "--output" part "--" (yt-thumbs-url id))
             :parse nil :key (cons 'yt-thumbs id) :timeout 30
             :on-success (lambda (_output _info)
                           (funcall finish (file-exists-p part)))
             :on-error (lambda (err)
                         (when (eq (plist-get err :type) 'missing)
                           (unless yt-thumbs--curl-missing
                             (setq yt-thumbs--curl-missing t)
                             (message "Thumbnails need curl (`yt-curl-program')")))
                         (funcall finish nil (eq (plist-get err :type) 'cancelled))))
      (remhash id yt-thumbs--pending)
      (funcall done))))

(defun yt-thumbs--recently-failed-p (id)
  "Return non-nil if the thumbnail of ID failed less than a while ago.
See `yt-thumbs-retry-after'."
  (when-let* ((failed (gethash id yt-thumbs--failed)))
    (< (- (yt--now) failed) yt-thumbs-retry-after)))

(defun yt-thumbs-forget-failures ()
  "Let thumbnails that failed to download be tried again at once.
The feed calls this after a refresh worked: the network is back."
  (clrhash yt-thumbs--failed))

(defun yt-thumbs-fetch (ids)
  "Download the thumbnails of the videos with IDS that are not cached.
Each is downloaded once; a failure is tried again after
`yt-thumbs-retry-after' seconds, or after `yt-thumbs-forget-failures'."
  (unless yt-thumbs--curl-missing
    (dolist (id ids)
      (when (and (yt-thumbs--valid-id-p id)
                 (not (gethash id yt-thumbs--pending))
                 (not (yt-thumbs--recently-failed-p id))
                 (not (file-exists-p (yt-thumbs-file id))))
        (puthash id t yt-thumbs--pending)
        (yt-process-queue-run yt-thumbs--queue
                              (lambda (done) (yt-thumbs--download id done)))))))

(provide 'yt-thumbs)
;;; yt-thumbs.el ends here
