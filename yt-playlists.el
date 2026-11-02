;;; yt-playlists.el --- Channel playlists and saved playlists -*- lexical-binding: t; -*-

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

;; `yt-channel-playlists' lists the playlists a channel created, from
;; its Playlists tab.  RET shows a playlist's videos in a feed buffer,
;; in the playlist's order, and + saves it.  Saved playlists are kept in
;; yt's cache, not in your YouTube account; `yt-saved-playlists' lists
;; them, with the number of their videos you have not watched.

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

(defconst yt-saved-playlists-buffer "*yt: Saved playlists*"
  "Name of the saved playlists buffer.")

(defvar-local yt-playlists--source nil
  "What this buffer lists: `saved', or (channel ID URL NAME).")

(defvar-local yt-playlists--playlists nil
  "The playlists of this buffer, plists in order.")

(defvar-local yt-playlists--query nil
  "The filter on playlist titles and channels, or nil.")

(defvar-local yt-playlists--refreshing nil
  "Non-nil while the channel's playlists are being fetched.")

(defvar-local yt-playlists--error nil
  "The message of the last failed fetch, or nil.")

(defun yt-playlists--from-json (entry)
  "Return the playlist plist for ENTRY of a channel's playlists, or nil."
  (let ((id (yt-video--string (plist-get entry :id))))
    (when id
      (list :id id
            :title (or (yt-video--string (plist-get entry :title)) id)
            :channel (or (yt-video--string (plist-get entry :channel))
                         (yt-video--string (plist-get entry :uploader)))
            :channel-id (yt-video--string (plist-get entry :channel_id))
            :url (or (and (string-prefix-p "https://www.youtube.com/"
                                           (or (plist-get entry :url) ""))
                          (plist-get entry :url))
                     (format "https://www.youtube.com/playlist?list=%s" id))))))

(defun yt-playlists--unwatched (id)
  "Return how many cached videos of the playlist ID are not watched."
  (seq-count (lambda (video) (not (yt-video-watched video)))
             (yt-cache-feed (concat "playlist:" id))))

(defun yt-playlists--entries ()
  "Return the tabulated-list entries of the playlists passing the filter."
  (let ((query (and yt-playlists--query (downcase yt-playlists--query))))
    (delq nil
          (mapcar
           (lambda (playlist)
             (let* ((id (plist-get playlist :id))
                    (title (plist-get playlist :title))
                    (channel (or (plist-get playlist :channel) ""))
                    (new (yt-playlists--unwatched id)))
               (when (or (not query)
                         (string-search query (downcase (concat title " " channel))))
                 (list id
                       (vector (if (yt-cache-playlist-saved-p id)
                                   (propertize "★" 'face 'yt-feed-new-marker)
                                 " ")
                               (propertize title 'face 'yt-feed-title)
                               (propertize channel 'face 'yt-feed-channel)
                               (if (> new 0)
                                   (propertize (number-to-string new) 'face 'yt-feed-new-marker)
                                 ""))))))
           yt-playlists--playlists))))

(defun yt-playlists--header-line ()
  "Return the header line of a playlists buffer."
  (concat " "
          (string-join
           (delq nil
                 (list (and yt-playlists--refreshing "Fetching the playlists…")
                       (and yt-playlists--error
                            (propertize yt-playlists--error 'face 'warning))
                       (and yt-playlists--query
                            (format "filter “%s”" yt-playlists--query))
                       (format "%d playlists" (length yt-playlists--playlists))
                       (substitute-command-keys
                        "\\<yt-playlists-mode-map>\\[yt-playlists-save] saves, \\[yt-playlists-forget] forgets")))
           "  ·  ")))

(defun yt-playlists--print ()
  "Print the playlists again, keeping point on the same playlist."
  (tabulated-list-print t)
  (when (and (not yt-playlists--playlists) (not yt-playlists--refreshing))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert "\n  "
                (or yt-playlists--error
                    (if (eq yt-playlists--source 'saved)
                        (substitute-command-keys
                         "No saved playlists.  Press \\<yt-playlists-mode-map>\\[yt-playlists-save] on a channel's playlist to save it.")
                      "This channel has no playlists."))
                "\n"))))
  (force-mode-line-update))

(defun yt-playlists-refresh ()
  "Fetch the channel's playlists again, or reread the saved ones."
  (interactive nil yt-playlists-mode)
  (pcase yt-playlists--source
    ('saved
     (setq yt-playlists--playlists (yt-cache-saved-playlists))
     (yt-playlists--print))
    (`(channel ,_id ,url ,_name)
     (let ((buffer (current-buffer)))
       (setq yt-playlists--refreshing t
             yt-playlists--error nil)
       (yt-playlists--print)
       (yt-auth-run
        (yt-ytdlp-channel-playlists-args url)
        :parse 'json :key (cons 'yt-playlists url) :force t
        :on-success
        (lambda (value _info)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq yt-playlists--playlists
                    (delq nil (mapcar #'yt-playlists--from-json
                                      (plist-get value :entries)))
                    yt-playlists--refreshing nil)
              (yt-playlists--print))))
        :on-error
        (lambda (err)
          (unless (eq (plist-get err :type) 'cancelled)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq yt-playlists--refreshing nil
                      yt-playlists--error (plist-get err :message))
                (yt-playlists--print)))
            (message "%s" (plist-get err :message)))))))))

(defun yt-playlists--at-point ()
  "Return the playlist at point, or signal a `user-error'."
  (let ((id (tabulated-list-get-id)))
    (or (and id (seq-find (lambda (p) (equal (plist-get p :id) id))
                          yt-playlists--playlists))
        (user-error "No playlist here"))))

(defun yt-playlists-open (playlist)
  "Show the videos of PLAYLIST, the playlist at point."
  (interactive (list (yt-playlists--at-point)) yt-playlists-mode)
  (yt-feed-playlist (plist-get playlist :id) (plist-get playlist :url)
                    (plist-get playlist :title)))

(defun yt-playlists-shuffle (playlist)
  "Play the videos of PLAYLIST, the playlist at point, in random order.
The playlist opens first; if it was never fetched, the shuffle starts
once its videos arrive."
  (interactive (list (yt-playlists--at-point)) yt-playlists-mode)
  (let ((buffer (save-window-excursion (yt-playlists-open playlist))))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (if (and yt-feed--videos (not yt-feed--refreshing))
          (yt-feed-shuffle)
        (letrec ((once (lambda ()
                         (remove-hook 'yt-feed-refreshed-hook once t)
                         (yt-feed-shuffle))))
          (add-hook 'yt-feed-refreshed-hook once nil t))))))

(defun yt-playlists-save (playlist)
  "Save PLAYLIST, the playlist at point, in yt."
  (interactive (list (yt-playlists--at-point)) yt-playlists-mode)
  (yt-cache-save-playlist playlist)
  (yt-playlists--print)
  (message "Saved the playlist “%s”" (plist-get playlist :title)))

(defun yt-playlists-forget (playlist)
  "Remove PLAYLIST, the playlist at point, from the saved playlists."
  (interactive (list (yt-playlists--at-point)) yt-playlists-mode)
  (yt-cache-forget-playlist (plist-get playlist :id))
  (when (eq yt-playlists--source 'saved)
    (setq yt-playlists--playlists (yt-cache-saved-playlists)))
  (yt-playlists--print)
  (message "Removed the playlist “%s” from the saved playlists"
           (plist-get playlist :title)))

(defun yt-playlists-browse (playlist)
  "Open PLAYLIST, the playlist at point, in a web browser."
  (interactive (list (yt-playlists--at-point)) yt-playlists-mode)
  (browse-url (plist-get playlist :url)))

(defun yt-playlists-filter (query)
  "Show only the playlists with QUERY in their title or channel.
An empty QUERY shows all of them."
  (interactive (list (read-string "Filter playlists: " yt-playlists--query))
               yt-playlists-mode)
  (setq yt-playlists--query (and (not (string-blank-p query)) query))
  (yt-playlists--print))

(defvar-keymap yt-playlists-mode-map
  :doc "Keymap for `yt-playlists-mode'."
  :parent tabulated-list-mode-map
  "RET" #'yt-playlists-open
  "z" #'yt-playlists-shuffle
  "+" #'yt-playlists-save
  "-" #'yt-playlists-forget
  "d" #'yt-playlists-forget
  "b" #'yt-playlists-browse
  "/" #'yt-playlists-filter
  "s" #'yt-playlists-filter
  "g" #'yt-playlists-refresh)

(define-derived-mode yt-playlists-mode tabulated-list-mode "yt-playlists"
  "Major mode for a list of YouTube playlists.
A ★ marks the playlists saved in yt.  \"New\" is the number of a
playlist's videos you have not watched, once it was opened.

\\{yt-playlists-mode-map}"
  :group 'yt-feed
  :interactive nil
  (setq tabulated-list-format [(" " 1 nil) ("Playlist" 50 t) ("Channel" 24 t)
                               ("New" 4 nil :right-align t)]
        tabulated-list-entries #'yt-playlists--entries
        tabulated-list-use-header-line nil
        header-line-format '(:eval (yt-playlists--header-line)))
  (setq-local revert-buffer-function (lambda (&rest _) (yt-playlists-refresh)))
  (tabulated-list-init-header))

(defun yt-playlists--show (source name)
  "Show the playlists of SOURCE in the buffer NAME and return the buffer.
A channel's playlists are fetched when the buffer is new."
  (let* ((buffer (get-buffer name))
         (new (not (and buffer
                        (equal (buffer-local-value 'yt-playlists--source buffer) source)))))
    (when new
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        (yt-playlists-mode)
        (setq yt-playlists--source source)))
    (with-current-buffer buffer
      (if (or new (eq source 'saved))
          (yt-playlists-refresh)
        (yt-playlists--print)))
    (pop-to-buffer-same-window buffer)
    buffer))

;;;###autoload
(defun yt-saved-playlists ()
  "List the playlists you saved in yt."
  (interactive)
  (yt-playlists--show 'saved yt-saved-playlists-buffer))

;;;###autoload
(defun yt-channel-playlists (id url name)
  "List the playlists created by the channel NAME with ID and page URL.
Interactively, use the channel of the video at point, of the
channel buffer, or at point in the channels list."
  (interactive (yt-channel-at-point))
  (yt-playlists--show (list 'channel id url name) (format "*yt: %s playlists*" name)))

(provide 'yt-playlists)
;;; yt-playlists.el ends here
