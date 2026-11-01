;;; yt-channels.el --- The subscribed channels -*- lexical-binding: t; -*-

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

;; `yt-channels' lists the channels you subscribe to, with the number
;; of their videos in the subscription feed you have not watched and
;; when they last uploaded one.  RET shows a channel's uploads.  The
;; list is cached and fetched again when it is a day old, or with g.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'yt)
(require 'yt-video)
(require 'yt-cache)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-feed)

(defconst yt-channels-buffer "*yt: Channels*"
  "Name of the channels buffer.")

(defvar yt-channels-refresh-interval 86400
  "Seconds after which \\[yt-channels] fetches the channel list again.")

(defvar-local yt-channels--channels nil
  "The channels of this buffer, plists in YouTube's order.")

(defvar-local yt-channels--query nil
  "The filter on channel names, or nil.")

(defvar-local yt-channels--refreshing nil
  "Non-nil while the channel list is being fetched.")

(defvar-local yt-channels--error nil
  "The message of the last failed fetch, or nil.")

(defvar-local yt-channels--stats nil
  "The statistics of the channels printed last; see `yt-channels--stats'.")

(defun yt-channels--from-json (entry)
  "Return the channel plist for ENTRY of yt-dlp's channel list, or nil."
  (let ((id (or (yt-video--string (plist-get entry :channel_id))
                (yt-video--string (plist-get entry :id)))))
    (when id
      (list :id id
            :name (or (yt-video--string (plist-get entry :channel))
                      (yt-video--string (plist-get entry :title))
                      id)
            :url (or (yt-video--string (plist-get entry :channel_url))
                     (yt-video--string (plist-get entry :url))
                     (format "https://www.youtube.com/channel/%s" id))
            :followers (yt-video--number (plist-get entry :channel_follower_count))))))

(defun yt-channels--stats ()
  "Return a hash table mapping channel ids to (UNWATCHED . LAST-UPLOAD).
They are computed from the cached subscription feed."
  (let ((stats (make-hash-table :test #'equal)))
    (dolist (video (yt-cache-feed "subscriptions"))
      (when-let* ((id (yt-video-channel-id video)))
        (let ((stat (or (gethash id stats) (puthash id (cons 0 nil) stats)))
              (ts (yt-video-timestamp video)))
          (unless (yt-video-watched video)
            (cl-incf (car stat)))
          (when (and ts (not (memq (yt-video-live-status video) '(is_upcoming)))
                     (or (not (cdr stat)) (> ts (cdr stat))))
            (setcdr stat ts)))))
    stats))

(defun yt-channels--entries ()
  "Return the tabulated-list entries of the channels passing the filter."
  (let ((stats (setq yt-channels--stats (yt-channels--stats)))
        (now (yt--now))
        (query (and yt-channels--query (downcase yt-channels--query))))
    (delq nil
          (mapcar
           (lambda (channel)
             (let* ((id (plist-get channel :id))
                    (name (plist-get channel :name))
                    (stat (gethash id stats)))
               (when (or (not query) (string-search query (downcase name)))
                 (list id
                       (vector (propertize name 'face 'yt-feed-channel)
                               (if (and stat (> (car stat) 0))
                                   (propertize (number-to-string (car stat))
                                               'face 'yt-feed-new-marker)
                                 "")
                               (propertize (yt-video-format-age (cdr stat) now)
                                           'face 'yt-feed-age))))))
           yt-channels--channels))))

(defun yt-channels--stat (entry index)
  "Return the number in column INDEX of ENTRY, or 0."
  (string-to-number (aref (cadr entry) index)))

(defun yt-channels--sort-unwatched (a b)
  "Return non-nil if entry A has more unwatched videos than entry B."
  (> (yt-channels--stat a 1) (yt-channels--stat b 1)))

(defun yt-channels--sort-last-upload (a b)
  "Return non-nil if entry A uploaded more recently than entry B."
  (> (or (cdr (gethash (car a) yt-channels--stats)) 0)
     (or (cdr (gethash (car b) yt-channels--stats)) 0)))

(defun yt-channels--header-line ()
  "Return the header line of the channels buffer."
  (let ((refreshed (yt-cache-meta "refreshed:channels")))
    (concat " "
            (string-join
             (delq nil
                   (list (and yt-channels--refreshing "Fetching the channels…")
                         (and yt-channels--error
                              (propertize yt-channels--error 'face 'warning))
                         (if refreshed
                             (format "updated %s" (yt-feed--ago refreshed))
                           "never updated")
                         (and yt-channels--query
                              (format "filter “%s”" yt-channels--query))
                         (format "%d channels" (length yt-channels--channels))))
             "  ·  "))))

(defun yt-channels--print ()
  "Print the channels again, keeping point on the same channel."
  (tabulated-list-print t)
  (when (and (not yt-channels--channels) (not yt-channels--refreshing))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert "\n  " (or yt-channels--error
                           (substitute-command-keys
                            "No channels yet.  Press \\[yt-channels-refresh] to fetch them."))
                "\n"))))
  (force-mode-line-update))

(defun yt-channels-refresh ()
  "Fetch the list of subscribed channels again."
  (interactive nil yt-channels-mode)
  (let ((buffer (current-buffer)))
    (setq yt-channels--refreshing t
          yt-channels--error nil)
    (force-mode-line-update)
    (yt-auth-run
     (yt-ytdlp-channels-args)
     :parse 'json :key '(yt-channels . list) :force t :source 'channels
     :on-success
     (lambda (value _info)
       (let ((channels (delq nil (mapcar #'yt-channels--from-json
                                         (plist-get value :entries)))))
         (yt-cache-put-channels channels)
         (yt-cache-set-meta "refreshed:channels" (truncate (yt--now)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq yt-channels--channels channels
                   yt-channels--refreshing nil)
             (yt-channels--print)))
         (message "yt: %d channels" (length channels))))
     :on-error
     (lambda (err)
       (unless (eq (plist-get err :type) 'cancelled)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq yt-channels--refreshing nil
                   yt-channels--error (plist-get err :message))
             (yt-channels--print)))
         (message "%s" (plist-get err :message)))))))

(defun yt-channels--at-point ()
  "Return the channel at point, or signal a `user-error'."
  (let ((id (tabulated-list-get-id)))
    (or (and id (seq-find (lambda (c) (equal (plist-get c :id) id))
                          yt-channels--channels))
        (user-error "No channel here"))))

(defun yt-channels-open (channel)
  "Show the uploads of CHANNEL, the channel at point."
  (interactive (list (yt-channels--at-point)) yt-channels-mode)
  (yt-feed-channel (plist-get channel :id) (plist-get channel :url)
                   (plist-get channel :name)))

(defun yt-channels-browse (channel)
  "Open the page of CHANNEL, the channel at point, in a web browser."
  (interactive (list (yt-channels--at-point)) yt-channels-mode)
  (browse-url (plist-get channel :url)))

(defun yt-channels-filter (query)
  "Show only the channels with QUERY in their name.
An empty QUERY shows all channels."
  (interactive (list (read-string "Filter channels: " yt-channels--query))
               yt-channels-mode)
  (setq yt-channels--query (and (not (string-blank-p query)) query))
  (yt-channels--print))

(defvar-keymap yt-channels-mode-map
  :doc "Keymap for `yt-channels-mode'."
  :parent tabulated-list-mode-map
  "RET" #'yt-channels-open
  "o" #'yt-channels-open
  "b" #'yt-channels-browse
  "/" #'yt-channels-filter
  "s" #'yt-channels-filter
  "g" #'yt-channels-refresh
  "L" #'yt-login)

(define-derived-mode yt-channels-mode tabulated-list-mode "yt-channels"
  "Major mode for the list of channels you subscribe to.
\"New\" is the number of their videos in the subscription feed you
have not watched.

\\{yt-channels-mode-map}"
  :group 'yt-feed
  :interactive nil
  (setq tabulated-list-format
        [("Channel" 36 t)
         ("New" 4 yt-channels--sort-unwatched :right-align t)
         ("Last upload" 12 yt-channels--sort-last-upload :right-align t)]
        tabulated-list-entries #'yt-channels--entries
        tabulated-list-sort-key nil
        tabulated-list-use-header-line nil
        header-line-format '(:eval (yt-channels--header-line)))
  (setq-local revert-buffer-function (lambda (&rest _) (yt-channels-refresh)))
  (add-hook 'kill-buffer-hook (lambda () (yt-process-cancel '(yt-channels . list))) nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun yt-channels ()
  "List the channels you subscribe to.
The list comes from the cache, and is fetched again when it is more
than a day old."
  (interactive)
  (let ((buffer (get-buffer-create yt-channels-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'yt-channels-mode)
        (yt-channels-mode)
        (setq yt-channels--channels (yt-cache-channels)))
      (yt-channels--print))
    (pop-to-buffer-same-window buffer)
    (let ((refreshed (yt-cache-meta "refreshed:channels")))
      (unless (or yt-channels--refreshing
                  (and refreshed (< (- (yt--now) refreshed) yt-channels-refresh-interval)))
        (yt-channels-refresh)))
    buffer))

(provide 'yt-channels)
;;; yt-channels.el ends here
