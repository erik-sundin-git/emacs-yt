;;; yt-info.el --- Details of a video -*- lexical-binding: t; -*-

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

;; `yt-info' shows what yt knows about a video at once, and fetches the
;; rest (the description, chapters, tags, likes and the exact upload
;; time) with yt-dlp in the background.  Chapters are buttons that play
;; the video from their start.  At most two such fetches run at once.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'goto-addr)
(require 'yt)
(require 'yt-video)
(require 'yt-process)
(require 'yt-cache)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-player)
(require 'yt-sponsorblock)
(require 'yt-feed)

(defface yt-info-title '((t :inherit (bold yt-feed-title) :height 1.2))
  "Face for the title in the info buffer."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-info-label '((t :inherit shadow))
  "Face for the labels in the info buffer."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-info-heading '((t :inherit bold))
  "Face for the section headings in the info buffer."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defconst yt-info-buffer "*yt: Info*"
  "Name of the info buffer.")

(defvar yt-info--queue (yt-process-queue-create 2)
  "Queue limiting how many details fetches run at once.")

(defvar-local yt-info--video nil
  "The `yt-video' this buffer describes.")

(defvar-local yt-info--details nil
  "The details fetched for the video, a plist, or nil.
It has :description, :chapters (a list of (START . TITLE)), :tags,
:likes and :views.")

(defvar-local yt-info--segments nil
  "The SponsorBlock segments of the video, as from `yt-sponsorblock-fetch'.")

(defvar-local yt-info--status nil
  "`fetching', an error message, or nil.")

(defun yt-info-details (info)
  "Return the details plist of the yt-dlp JSON INFO of one video.
See `yt-info--details'."
  (list :description (yt-video--string (plist-get info :description))
        :chapters (delq nil (mapcar (lambda (chapter)
                                      (let ((start (plist-get chapter :start_time)))
                                        (and (numberp start)
                                             (cons start (or (plist-get chapter :title) "")))))
                                    (plist-get info :chapters)))
        :tags (seq-filter #'stringp (plist-get info :tags))
        :likes (yt-video--number (plist-get info :like_count))
        :views (yt-video--number (plist-get info :view_count))))

;;;; Rendering

(defun yt-info--field (label value)
  "Insert the field LABEL with VALUE, a string, if VALUE is non-empty."
  (when (and value (not (string-empty-p value)))
    (insert (propertize (format "%-11s" label) 'face 'yt-info-label) value "\n")))

(defun yt-info--number (n)
  "Return the number N with thousands separators, or nil."
  (when n
    (let ((s (number-to-string n)))
      (while (string-match "\\([0-9]\\)\\([0-9]\\{3\\}\\)\\(\\'\\|,\\)" s)
        (setq s (replace-match "\\1,\\2\\3" t nil s)))
      s)))

(defun yt-info--date (video)
  "Return when VIDEO was published, as text, or nil."
  (when-let* ((ts (yt-video-timestamp video)))
    (let ((approx (yt-video-timestamp-approx-p video)))
      (format "%s%s (%s)"
              (if approx "about " "")
              (format-time-string (if approx "%F" "%F %R") ts)
              (let ((age (yt-video-format-age ts)))
                (cond ((equal age "now") "just now")
                      ((string-prefix-p "in" age) (concat "in " (substring age 2)))
                      (t (concat age " ago"))))))))

(defun yt-info--status-text (video)
  "Return the live status of VIDEO as text, or nil."
  (pcase (yt-video-live-status video)
    ('is_live (propertize "live now" 'face 'yt-feed-live))
    ('is_upcoming (propertize "upcoming" 'face 'yt-feed-upcoming))
    ('was_live "past live stream")
    ('post_live "live stream, being processed")))

(defun yt-info--play-chapter (button)
  "Play the video of the info buffer from the chapter of BUTTON."
  (yt-play-at yt-info--video (button-get button 'yt-start)))

(defun yt-info--render ()
  "Show the video and its details in the current buffer."
  (let* ((inhibit-read-only t)
         (video yt-info--video)
         (details yt-info--details)
         (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize (or (yt-video-title video) (yt-video-id video))
                        'face 'yt-info-title)
            "\n\n")
    (when-let* ((channel (yt-video-channel video)))
      (insert (propertize (format "%-11s" "Channel") 'face 'yt-info-label))
      (if (or (yt-video-channel-id video) (yt-video-channel-url video))
          (insert-text-button channel 'action (lambda (_) (yt-feed-open-channel video))
                              'help-echo "Show the channel's uploads")
        (insert channel))
      (insert "\n"))
    (yt-info--field "Published" (yt-info--date video))
    (yt-info--field "Duration" (and (yt-video-duration video)
                                    (yt-video-format-duration (yt-video-duration video))))
    (yt-info--field "Status" (yt-info--status-text video))
    (yt-info--field "Views" (yt-info--number (or (plist-get details :views)
                                                 (yt-video-views video))))
    (yt-info--field "Likes" (yt-info--number (plist-get details :likes)))
    (let ((cached (and (yt-video-id video) (yt-cache-get (yt-video-id video)))))
      (yt-info--field "Watched"
                      (cond ((and cached (yt-video-watched cached)) "yes")
                            ((and cached (yt-video-position cached))
                             (format "no, stopped at %s"
                                     (yt-video-format-duration (yt-video-position cached))))
                            (t "no"))))
    (insert (propertize (format "%-11s" "URL") 'face 'yt-info-label))
    (insert-text-button (yt-video-url video) 'action (lambda (_) (browse-url (yt-video-url video)))
                        'help-echo "Open in a web browser")
    (insert "\n")
    (pcase yt-info--status
      ('fetching (insert "\n" (propertize "Fetching details…" 'face 'shadow) "\n"))
      ((and (pred stringp) message)
       (insert "\n" (propertize message 'face 'warning) "\n")))
    (when-let* ((chapters (plist-get details :chapters)))
      (insert "\n" (propertize "Chapters" 'face 'yt-info-heading) "\n")
      (dolist (chapter chapters)
        (insert "  ")
        (insert-text-button (format "%8s" (yt-video-format-duration (car chapter)))
                            'action #'yt-info--play-chapter 'yt-start (car chapter)
                            'help-echo "Play from here")
        (insert "  " (cdr chapter) "\n")))
    (when yt-info--segments
      (insert "\n" (propertize "SponsorBlock" 'face 'yt-info-heading) "\n")
      (dolist (segment (sort (copy-sequence yt-info--segments)
                             (lambda (a b) (< (plist-get a :start) (plist-get b :start)))))
        (insert "  ")
        (insert-text-button (format "%8s" (yt-video-format-duration (plist-get segment :start)))
                            'action #'yt-info--play-chapter 'yt-start (plist-get segment :start)
                            'help-echo "Play from here")
        (insert (format "–%-8s %s%s\n"
                        (yt-video-format-duration (plist-get segment :end))
                        (yt-sponsorblock-category-name (plist-get segment :category))
                        (if (memq (plist-get segment :category) yt-sponsorblock-categories)
                            (propertize "  skipped in mpv" 'face 'shadow)
                          "")))))
    (when-let* ((tags (plist-get details :tags)))
      (insert "\n")
      (yt-info--field "Tags" (string-join tags ", ")))
    (when-let* ((description (plist-get details :description)))
      (insert "\n" (propertize "Description" 'face 'yt-info-heading) "\n")
      (let ((start (point)))
        (insert description "\n")
        (goto-address-fontify start (point))))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Fetching

(defun yt-info--fetch ()
  "Fetch the details of this buffer's video in the background."
  (let ((buffer (current-buffer))
        (video yt-info--video))
    (setq yt-info--status 'fetching)
    (yt-info--render)
    (yt-sponsorblock-fetch
     (yt-video-id video)
     (lambda (segments)
       (when (and segments (buffer-live-p buffer)
                  ;; The video object is replaced once its details arrive.
                  (equal (yt-video-id (buffer-local-value 'yt-info--video buffer))
                         (yt-video-id video)))
         (with-current-buffer buffer
           (setq yt-info--segments segments)
           (yt-info--render)))))
    (yt-process-queue-run
     yt-info--queue
     (lambda (done)
       (let ((finish
              (lambda (status &optional details merged)
                (funcall done)
                (when (and (buffer-live-p buffer)
                           (eq (buffer-local-value 'yt-info--video buffer) video))
                  (with-current-buffer buffer
                    (setq yt-info--status status)
                    (when details
                      (setq yt-info--details details))
                    (when merged
                      (setq yt-info--video merged
                            video merged))
                    (yt-info--render))))))
         (unless (and (buffer-live-p buffer)
                      (yt-auth-run
                       (yt-ytdlp-info-args (yt-video-url video))
                       :parse 'json :key (cons 'yt-info (yt-video-id video))
                       :on-success
                       (lambda (info _info)
                         (let ((fetched (yt-video-from-json info)))
                           (funcall finish nil (yt-info-details info)
                                    (and fetched (car (yt-cache-put-videos (list fetched)))))))
                       :on-error
                       (lambda (err)
                         (if (eq (plist-get err :type) 'cancelled)
                             (funcall done)
                           (funcall finish (plist-get err :message))))))
           ;; Nothing was started: the buffer is gone, or the same
           ;; video is being fetched already.
           (funcall done)))))))

;;;; Mode

(defun yt-info-ret ()
  "Press the button at point, or play the video."
  (interactive nil yt-info-mode)
  (if (button-at (point))
      (push-button)
    (call-interactively #'yt-play)))

(defun yt-info-refresh ()
  "Fetch the details of the video again."
  (interactive nil yt-info-mode)
  (yt-info--fetch))

(defvar-keymap yt-info-mode-map
  :doc "Keymap for `yt-info-mode'."
  :parent (make-composed-keymap yt-video-actions-map special-mode-map)
  "RET" #'yt-info-ret
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "g" #'yt-info-refresh)

(define-derived-mode yt-info-mode special-mode "yt-info"
  "Major mode for the details of a YouTube video.
\\<yt-info-mode-map>\\[yt-info-ret] plays the video, or presses the button at point;
chapters are buttons that play from their start.

\\{yt-info-mode-map}"
  :group 'yt-feed
  :interactive nil
  (setq-local yt-video-at-point-function (lambda () yt-info--video))
  (setq-local revert-buffer-function (lambda (&rest _) (yt-info--fetch)))
  (setq truncate-lines nil)
  (visual-line-mode 1))

;;;###autoload
(defun yt-info (video)
  "Show the details of VIDEO.
Interactively, describe the video at point, or ask for a URL."
  (interactive (list (yt-player--read-video)))
  (let ((buffer (get-buffer-create yt-info-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'yt-info-mode)
        (yt-info-mode))
      (setq yt-info--video video
            yt-info--details nil)
      (yt-info--fetch))
    (pop-to-buffer buffer)
    buffer))

(provide 'yt-info)
;;; yt-info.el ends here
