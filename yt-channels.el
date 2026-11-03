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
;; when they last uploaded one.  RET shows a channel's uploads, and -
;; unsubscribes from it.  The list is cached and fetched again when it
;; is a day old, or with g.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'yt)
(require 'yt-video)
(require 'yt-cache)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-list)
(require 'yt-feed)

(declare-function yt-channel-playlists "yt-playlists" (id url name))
(declare-function yt-unsubscribe "yt-subscribe" (id url name &optional confirm))

(defconst yt-channels-buffer "*yt: Channels*"
  "Name of the channels buffer.")

(defvar yt-channels-refresh-interval 86400
  "Seconds after which \\[yt-channels] fetches the channel list again.")

(defvar-local yt-channels--channels nil
  "The channels of this buffer, plists in YouTube's order.")

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
        (terms (yt-list-query-terms)))
    (delq nil
          (mapcar
           (lambda (channel)
             (let* ((id (plist-get channel :id))
                    (name (plist-get channel :name))
                    (stat (gethash id stats)))
               (when (yt-list-match-p terms (downcase name) (downcase name))
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

(defun yt-channels--header-parts ()
  "Return the parts of the channels list's header line."
  (let ((refreshed (yt-cache-meta "refreshed:channels")))
    (list (if refreshed
              (format "updated %s" (yt-list-ago refreshed))
            "never updated")
          (yt-list-count (length yt-channels--channels) "channel"))))

(defun yt-channels--empty ()
  "Return what an empty channels list says."
  (substitute-command-keys
   "No channels yet.  Press \\<yt-channels-mode-map>\\[yt-channels-refresh] to fetch them."))

(defun yt-channels-refresh ()
  "Fetch the list of subscribed channels again."
  (interactive nil yt-channels-mode)
  (let ((buffer (current-buffer)))
    (setq yt-list--refreshing t
          yt-list--error nil)
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
                   yt-list--refreshing nil)
             (yt-list-print)))
         (message "yt: %d channels" (length channels))))
     :on-error
     (lambda (err)
       (unless (eq (plist-get err :type) 'cancelled)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq yt-list--refreshing nil
                   yt-list--error (plist-get err :message))
             (yt-list-print)))
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
  (yt-browse-url (plist-get channel :url)))

(defun yt-channels-unsubscribe (channel)
  "Unsubscribe from CHANNEL, the channel at point, after confirmation."
  (interactive (list (yt-channels--at-point)) yt-channels-mode)
  (require 'yt-subscribe)
  (yt-unsubscribe (plist-get channel :id) (plist-get channel :url)
                  (plist-get channel :name) t))

(defun yt-channels--subscriptions-changed (_channel _subscribed)
  "Show the cached channels again in the channels buffer."
  (when-let* ((buffer (get-buffer yt-channels-buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'yt-channels-mode)
        (setq yt-channels--channels (yt-cache-channels))
        (yt-list-print)))))

(defvar-keymap yt-channels-mode-map
  :doc "Keymap for `yt-channels-mode'."
  :parent yt-list-mode-map
  "RET" #'yt-channels-open
  "o" #'yt-channels-open
  "O" #'yt-channel-playlists
  "b" #'yt-channels-browse
  "-" #'yt-channels-unsubscribe
  "d" #'yt-channels-unsubscribe
  "g" #'yt-channels-refresh
  "L" #'yt-login)

(define-derived-mode yt-channels-mode yt-list-mode "yt-channels"
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
        yt-list-header-function #'yt-channels--header-parts
        yt-list-empty-function #'yt-channels--empty)
  (setq-local revert-buffer-function (lambda (&rest _) (yt-channels-refresh)))
  (add-hook 'kill-buffer-hook (lambda () (yt-process-cancel '(yt-channels . list))) nil t)
  (add-hook 'yt-subscriptions-changed-functions #'yt-channels--subscriptions-changed)
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
      (yt-list-print))
    (pop-to-buffer-same-window buffer)
    (let ((refreshed (yt-cache-meta "refreshed:channels")))
      (unless (or yt-list--refreshing
                  (and refreshed (< (- (yt--now) refreshed) yt-channels-refresh-interval)))
        (yt-channels-refresh)))
    buffer))

(provide 'yt-channels)
;;; yt-channels.el ends here
