;;; yt-history.el --- The videos you played -*- lexical-binding: t; -*-

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

;; `yt-history' lists the videos you played in yt, the most recently
;; played first, with when you played them and how far you got.  RET
;; plays a video again, from where you stopped; d removes it from the
;; list and D clears the list.  The history is kept in yt's cache, on
;; this machine only; `yt-player-youtube-history' also adds the videos
;; you play to your YouTube history.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'yt)
(require 'yt-video)
(require 'yt-cache)
(require 'yt-player)
(require 'yt-list)
(require 'yt-feed)

(defconst yt-history-buffer "*yt: History*"
  "Name of the history buffer.")

(defvar yt-history-limit 500
  "Number of played videos the history buffer shows.")

(defvar-local yt-history--items nil
  "The played videos shown, as from `yt-cache-history'.")

(defvar-local yt-history--table nil
  "Hash table mapping the ids of the videos shown to the videos.")

(defvar-local yt-history--played-at nil
  "Hash table mapping the ids of the videos shown to when they were played.")

(defvar-local yt-history--stale nil
  "Non-nil if the history changed while this buffer was not shown.")

(defvar yt-history--refresh-timer nil
  "Timer that prints the history buffer again, or nil.")

(defvar-local yt-history--query nil
  "The filter on titles and channels, or nil.")

(defun yt-history--progress (video)
  "Return how far you got in VIDEO, as text."
  (let ((position (yt-video-position video))
        (duration (yt-video-duration video)))
    (cond ((yt-video-watched video) (propertize "watched" 'face 'success))
          (position (if duration
                        (format "%s/%s" (yt-video-format-duration position)
                                (yt-video-format-duration duration))
                      (yt-video-format-duration position)))
          (t ""))))

(defun yt-history--match-p (video words)
  "Return non-nil if every one of WORDS is in VIDEO's title or channel."
  (let ((text (downcase (concat (or (yt-video-title video) "") " "
                                (or (yt-video-channel video) "")))))
    (seq-every-p (lambda (word) (string-search word text)) words)))

(defun yt-history--entries ()
  "Return the tabulated-list entries of the videos passing the filter."
  (let ((now (yt--now))
        (words (and yt-history--query (split-string (downcase yt-history--query)))))
    (cl-loop for (video . played) in yt-history--items
             when (or (not words) (yt-history--match-p video words))
             collect
             (list (yt-video-id video)
                   (vector (propertize (or (yt-video-channel video) "") 'face 'yt-feed-channel)
                           (propertize (or (yt-video-title video) (yt-video-id video))
                                       'face (if (yt-video-watched video)
                                                 'yt-feed-title-watched
                                               'yt-feed-title-unwatched))
                           (propertize (yt-video-format-age played now) 'face 'yt-feed-age)
                           (yt-history--progress video)
                           (propertize (yt-video-format-duration (yt-video-duration video))
                                       'face 'yt-feed-duration))))))

(defun yt-history--played (id)
  "Return when the video ID was played, in seconds since the epoch."
  (gethash id yt-history--played-at 0))

(defun yt-history--sort-played (a b)
  "Return non-nil if entry A was played after entry B."
  (> (yt-history--played (car a)) (yt-history--played (car b))))

(defun yt-history--header-line ()
  "Return the header line of the history buffer."
  (concat " "
          (string-join
           (delq nil
                 (list (format "%d videos played" (length yt-history--items))
                       (and yt-history--query (format "filter “%s”" yt-history--query))
                       (substitute-command-keys
                        "\\<yt-history-mode-map>\\[yt-history-remove] removes, \
\\[yt-history-clear] clears")
                       (and yt-player-youtube-history "also sent to YouTube")))
           "  ·  ")))

(defun yt-history--print ()
  "Read the played videos again and print them, keeping point."
  (setq yt-history--items (yt-cache-history yt-history-limit)
        yt-history--table (make-hash-table :test #'equal)
        yt-history--played-at (make-hash-table :test #'equal)
        yt-history--stale nil)
  (dolist (item yt-history--items)
    (puthash (yt-video-id (car item)) (car item) yt-history--table)
    (puthash (yt-video-id (car item)) (cdr item) yt-history--played-at))
  (tabulated-list-print t)
  (unless yt-history--items
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert "\n  No videos played yet.\n"))))
  (force-mode-line-update))

(defun yt-history--refresh (&rest _)
  "Print the history buffer again shortly, once for a burst of changes.
A video starting or ending changes the history several times."
  (unless (timerp yt-history--refresh-timer)
    (setq yt-history--refresh-timer
          (run-with-timer 0.2 nil #'yt-history--refresh-now))))

(defun yt-history--refresh-now ()
  "Print the history buffer again if it is shown, else mark it stale."
  (setq yt-history--refresh-timer nil)
  (when-let* ((buffer (get-buffer yt-history-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'yt-history-mode)
        (if (get-buffer-window buffer t)
            (yt-history--print)
          (setq yt-history--stale t))))))

(defun yt-history--print-now ()
  "Print the history buffer now, for a change made from it."
  (when (timerp yt-history--refresh-timer)
    (cancel-timer yt-history--refresh-timer)
    (setq yt-history--refresh-timer nil))
  (yt-history--print))

(defun yt-history--shown (_window)
  "Print the history again when it is shown after it changed unseen."
  (when yt-history--stale
    (yt-history--print)))

(defun yt-history--video-at-point ()
  "Return the video at point, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (gethash id yt-history--table)))

(defun yt-history--ids-in-region-or-at-point ()
  "Return the ids of the rows in the region, or of the row at point."
  (if (use-region-p)
      (let ((end (region-end)) ids)
        (save-excursion
          (goto-char (region-beginning))
          (while (< (point) end)
            (when-let* ((id (tabulated-list-get-id)))
              (push id ids))
            (forward-line 1)))
        (nreverse ids))
    (list (or (tabulated-list-get-id) (user-error "No video here")))))

(defun yt-history-remove (ids)
  "Remove the videos with IDS from the history.
Interactively, the videos in the region, or the video at point.
Their watched marks and resume positions stay."
  (interactive (list (yt-history--ids-in-region-or-at-point)) yt-history-mode)
  (yt-cache-remove-history ids)
  (yt-history--print-now)
  (message "Removed %d %s from the history" (length ids)
           (if (cdr ids) "videos" "video")))

(defun yt-history-clear ()
  "Remove every video from the history, after confirmation.
Watched marks and resume positions stay; \\[yt-forget-history]
forgets them too."
  (interactive nil yt-history-mode)
  (when (yes-or-no-p "Clear the list of played videos? ")
    (yt-cache-clear-history)
    (yt-history--print-now)
    (message "Cleared the history")))

(defun yt-history-filter (query)
  "Show only the videos with every word of QUERY in their title or channel.
An empty QUERY shows all of them."
  (interactive (list (read-string "Filter history: " yt-history--query
                                  (yt-minibuffer-history 'yt-filter-history))) yt-history-mode)
  (setq yt-history--query (and (not (string-blank-p query)) query))
  (yt-history--print))

(defvar-keymap yt-history-mode-map
  :doc "Keymap for `yt-history-mode'."
  :parent (make-composed-keymap yt-video-actions-map tabulated-list-mode-map)
  "d" #'yt-history-remove
  "D" #'yt-history-clear
  "/" #'yt-history-filter
  "s" #'yt-history-filter
  "g" #'revert-buffer)

(define-derived-mode yt-history-mode tabulated-list-mode "yt-history"
  "Major mode for the list of videos you played.
\"Played\" is how long ago you played a video, and \"Progress\"
where you stopped, or whether you watched it.  The video keys of
the feed work here too.

\\{yt-history-mode-map}"
  :group 'yt-player
  :interactive nil
  (setq tabulated-list-entries #'yt-history--entries
        tabulated-list-sort-key nil
        tabulated-list-use-header-line nil
        header-line-format '(:eval (yt-history--header-line)))
  (setq-local yt-video-at-point-function #'yt-history--video-at-point)
  (setq-local yt-list-reprint-function #'yt-history--print)
  (setq-local revert-buffer-function (lambda (&rest _) (yt-history--print)))
  (add-hook 'yt-history-changed-hook #'yt-history--refresh)
  (add-hook 'yt-watched-changed-functions #'yt-history--refresh)
  (add-hook 'window-buffer-change-functions #'yt-history--shown nil t)
  (yt-list-fit-columns [("Channel" 20 t)
                        ("Title" 60 t)
                        ("Played" 7 yt-history--sort-played :right-align t)
                        ("Progress" 15 nil :right-align t)
                        ("Dur" 8 nil :right-align t)]))

;;;###autoload
(defun yt-history ()
  "List the videos you played in yt, the most recently played first."
  (interactive)
  (let ((buffer (get-buffer-create yt-history-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'yt-history-mode)
        (yt-history-mode))
      (yt-history--print))
    (pop-to-buffer-same-window buffer)
    buffer))

(provide 'yt-history)
;;; yt-history.el ends here
