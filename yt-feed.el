;;; yt-feed.el --- The subscription feed buffer -*- lexical-binding: t; -*-

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

;; `yt-feed-mode' lists videos in a tabulated list, in the order of the
;; feed they came from.  \\[yt] shows the subscription feed: first the
;; cached videos, at once, then the result of an asynchronous refresh,
;; which is merged into the cache.  A refresh keeps point, and the
;; position of each window showing the feed, on the same video.
;;
;; Filters (a query, a channel, and hiding watched videos, Shorts or
;; upcoming streams) apply to the videos already in the buffer and never
;; refetch.  The header line shows the sign-in state, when the feed was
;; last updated, the active filters and the number of videos shown.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'yt)
(require 'yt-video)
(require 'yt-cache)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-player)
(require 'yt-list)
(require 'yt-thumbs)

(declare-function yt-info "yt-info" (video))
(declare-function yt-channels "yt-channels" ())
(declare-function yt-saved-playlists "yt-playlists" ())
(declare-function yt-subscribe "yt-subscribe" (id url name))
(declare-function yt-unsubscribe "yt-subscribe" (id url name &optional confirm))

;;;; Faces

(defvar yt-feed-visit-gap 600
  "Seconds without opening the subscription feed that end a visit.
Videos that arrived since the visit before are marked as new.")

(defvar-local yt-feed--last-visit nil
  "When you last looked at the subscription feed before now, or nil.")

;;;; Buffer state

(defconst yt-feed-subscriptions-buffer "*yt: Subscriptions*"
  "Name of the subscription feed buffer.")

(defvar-local yt-feed--source nil
  "The feed this buffer shows.
It is `subscriptions' for the subscription feed, (channel ID URL
NAME) for a channel's uploads, (playlist ID URL TITLE) for a
playlist, and (search QUERY) for search results.")

(defvar yt-playlist-limit 300
  "Number of videos fetched from a playlist.")

(defvar yt-search-limit 20
  "Number of results of a search.")

(defvar-local yt-feed--videos nil
  "The videos of this buffer, in feed order, before filtering.")

(defvar-local yt-feed--table nil
  "Hash table mapping the ids of `yt-feed--videos' to the videos.")

(defvar-local yt-feed--filter nil
  "The active filter, a plist.
:query is the query string, see `yt-list-parse-query'; :channel is
\(ID . NAME) of the channel shown; :hide-watched, :hide-shorts,
:hide-upcoming and :hide-muted are booleans.")

(defvar-local yt-feed--muted nil
  "The muted channels, a hash table of ids, in the subscription feed.
Elsewhere nil: a channel's own uploads are never hidden.")

(defvar-local yt-feed--shown 0
  "Number of videos printed, that is, passing the filter.")

(defvar-local yt-feed--refreshed-at nil
  "When this feed was last refreshed, in seconds since the epoch.")

(defvar-local yt-feed--refreshing nil
  "Non-nil while this feed is refreshing: the number of the running refresh.")

(defvar-local yt-feed--status nil
  "A message about the running refresh, or nil.")

(defvar-local yt-feed--error nil
  "The message of the last failed refresh, or nil.")

(defvar yt-feed--refresh-count 0
  "Number of refreshes started, used to recognize stale callbacks.")

(defvar yt-feed--fully-refreshed nil
  "Sources fetched in full in this session.")

(defvar yt-feed--age-timer nil
  "Timer that updates the ages shown in visible feed buffers.")

(defvar yt-feed-age-update-interval 300
  "Seconds between updates of the ages shown in visible feed buffers.")

(defun yt-feed--cache-source ()
  "Return the cache key of this buffer's feed, or nil if it is not kept.
The order of search results is not kept."
  (pcase yt-feed--source
    ('subscriptions "subscriptions")
    (`(channel ,id . ,_) (concat "channel:" id))
    (`(playlist ,id . ,_) (concat "playlist:" id))))

(defun yt-feed--fetch-spec ()
  "Return how to fetch this buffer's feed, a plist.
:args are the yt-dlp arguments, :auth-source the SOURCE for
`yt-auth-run', :redact the arguments to keep out of logs, :approx
whether timestamps are approximate and :stop-early whether a
refresh may stop at cached videos.  :replace means a fetch replaces
the cached feed instead of being merged into it."
  (pcase yt-feed--source
    ('subscriptions
     (list :args (yt-ytdlp-feed-args yt-feed-limit) :auth-source 'feed
           :approx t :stop-early t))
    (`(channel ,_id ,url . ,_)
     (list :args (yt-ytdlp-channel-args url yt-feed-limit) :approx t :stop-early t))
    (`(playlist ,_id ,url . ,_)
     (list :args (yt-ytdlp-playlist-args url yt-playlist-limit) :approx t :replace t))
    (`(search ,query)
     (let ((args (yt-ytdlp-search-args query yt-search-limit)))
       (list :args args :redact (last args))))))

(defun yt-feed--process-key ()
  "Return the process key of this buffer's refresh."
  (cons 'yt-feed yt-feed--source))

(defun yt-feed--buffers ()
  "Return the live feed buffers."
  (seq-filter (lambda (buffer)
                (eq (buffer-local-value 'major-mode buffer) 'yt-feed-mode))
              (buffer-list)))

(defun yt-feed--set-videos (videos)
  "Make VIDEOS, in feed order, the videos of this buffer."
  (let ((table (make-hash-table :test #'equal :size (max 64 (length videos)))))
    (dolist (video videos)
      (puthash (yt-video-id video) video table))
    (setq yt-feed--videos videos
          yt-feed--table table)))

(defun yt-feed-video-at-point ()
  "Return the `yt-video' at point, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (and yt-feed--table (gethash id yt-feed--table))))

;;;; Filters

(defun yt-feed--match-p (video terms filter)
  "Return non-nil if VIDEO passes the query TERMS and the FILTER plist.
TERMS come from `yt-list-parse-query'; see `yt-feed--filter' for
FILTER."
  (let ((title (downcase (or (yt-video-title video) "")))
        (channel (downcase (or (yt-video-channel video) "")))
        (shown (plist-get filter :channel)))
    (and (not (and (plist-get filter :hide-watched) (yt-video-watched video)))
         (not (and (plist-get filter :hide-muted) yt-feed--muted
                   (gethash (yt-video-channel-id video) yt-feed--muted)))
         (or (not (plist-get filter :only-arrived)) (yt-feed--arrived-p video))
         (not (and (plist-get filter :hide-shorts) (yt-video-short-p video)))
         (not (and (plist-get filter :hide-upcoming)
                   (memq (yt-video-live-status video) '(is_upcoming is_live))))
         (or (not shown)
             (if (car shown)
                 (equal (car shown) (yt-video-channel-id video))
               (equal (cdr shown) (yt-video-channel video))))
         (yt-list-match-p terms title channel))))

(defun yt-feed--arrived-p (video)
  "Return non-nil if VIDEO arrived since your last visit to the feed."
  (and yt-feed--last-visit (yt-video-fetched-at video)
       (> (yt-video-fetched-at video) yt-feed--last-visit)))

(defun yt-feed--arrived-count ()
  "Return how many unwatched videos arrived since your last visit."
  (seq-count (lambda (video) (and (not (yt-video-watched video)) (yt-feed--arrived-p video)))
             yt-feed--videos))

(defun yt-feed--note-visit ()
  "Note that you look at the subscription feed now.
The visit before is kept in `yt-feed--last-visit', unless you looked
less than `yt-feed-visit-gap' seconds ago, which is the same visit."
  (let ((now (truncate (yt--now)))
        (before (yt-cache-meta "visited:subscriptions")))
    (when (or (not yt-feed--last-visit)
              (not before)
              (>= (- now before) yt-feed-visit-gap))
      (setq yt-feed--last-visit before))
    (yt-cache-set-meta "visited:subscriptions" now)))

(defun yt-feed--filtered-videos ()
  "Return the videos of this buffer that pass the filter, in feed order."
  (let ((terms (yt-list-parse-query (plist-get yt-feed--filter :query))))
    (seq-filter (lambda (video) (yt-feed--match-p video terms yt-feed--filter))
                yt-feed--videos)))

(defun yt-feed--filter-description ()
  "Return a description of the active filter, or nil."
  (let ((parts nil))
    (when-let* ((query (plist-get yt-feed--filter :query)))
      (push (format "filter “%s”" query) parts))
    (when-let* ((channel (plist-get yt-feed--filter :channel)))
      (push (format "channel %s" (cdr channel)) parts))
    (let ((hidden (delq nil (list (and (plist-get yt-feed--filter :hide-watched) "watched")
                                  (and (plist-get yt-feed--filter :hide-shorts) "Shorts")
                                  (and (plist-get yt-feed--filter :hide-upcoming)
                                       "upcoming")
                                  (and (plist-get yt-feed--filter :hide-muted)
                                       yt-feed--muted (> (hash-table-count yt-feed--muted) 0)
                                       "muted channels")))))
      (when hidden
        (push (concat "hiding " (string-join hidden ", ")) parts)))
    (when (plist-get yt-feed--filter :only-arrived)
      (push "only new since your last visit" parts))
    (and parts (string-join (nreverse parts) ", "))))

;;;; Rows

(defun yt-feed--badge (video)
  "Return the badge shown before the title of VIDEO, or \"\"."
  (pcase (yt-video-live-status video)
    ('is_live (propertize "[LIVE] " 'face 'yt-feed-live))
    ('is_upcoming
     (propertize (if-let* ((ts (and (not (eq (yt-video-timestamp-approx-p video)
                                             'inherited))
                                    (yt-video-timestamp video))))
                     (format "[SOON %s] "
                             (format-time-string
                              (if (< (abs (- ts (yt--now))) 86400) "%H:%M" "%b %-d %H:%M")
                              ts))
                   "[SOON] ")
                 'face 'yt-feed-upcoming))
    (_ (if (yt-video-short-p video)
           (propertize "[S] " 'face 'yt-feed-short)
         ""))))

(defvar-local yt-feed--thumbnails nil
  "Non-nil if this buffer shows thumbnails; see `yt-feed-thumbnails'.")

(defvar-local yt-feed--thumbnail-timer nil
  "Timer that requests the thumbnails of the visible rows.")

(defun yt-feed--images-p ()
  "Return non-nil if the selected frame can show images."
  (display-images-p))

(defun yt-feed--thumbnails-p ()
  "Return non-nil if thumbnails are on in this buffer and can be shown."
  (and yt-feed--thumbnails (yt-feed--images-p)))

(defun yt-feed--thumbnail-cell (video)
  "Return the thumbnail cell of VIDEO: its image, or a blank."
  (if-let* ((image (yt-thumbs-image (yt-video-id video))))
      (propertize " " 'display image)
    ""))

(defun yt-feed--entry (video now)
  "Return the tabulated-list entry of VIDEO, with ages relative to NOW."
  (let ((watched (yt-video-watched video))
        (live (yt-video-live-status video)))
    (list (yt-video-id video)
          (vconcat
           (and (yt-feed--thumbnails-p) (list (yt-feed--thumbnail-cell video)))
           (list
           (cond (watched " ")
                 ((yt-feed--arrived-p video) (propertize "◆" 'face 'yt-feed-arrived-marker))
                 (t (propertize "●" 'face 'yt-feed-new-marker)))
           (propertize (or (yt-video-channel video) "") 'face 'yt-feed-channel)
           (concat (yt-feed--badge video)
                   (propertize (or (yt-video-title video) (yt-video-id video))
                               'face (if watched
                                         'yt-feed-title-watched
                                       'yt-feed-title-unwatched)))
           (propertize (yt-video-format-age (yt-video-timestamp video) now)
                       'face 'yt-feed-age)
           (pcase live
             ('is_live (propertize "LIVE" 'face 'yt-feed-live))
             ('is_upcoming (propertize "SOON" 'face 'yt-feed-upcoming))
             (_ (propertize (yt-video-format-duration (yt-video-duration video))
                            'face 'yt-feed-duration))))))))

(defun yt-feed--entries ()
  "Return the tabulated-list entries of the videos that pass the filter."
  (let ((now (yt--now)))
    (mapcar (lambda (video) (yt-feed--entry video now))
            (yt-feed--filtered-videos))))

(defun yt-feed--entry-video (entry)
  "Return the video of the tabulated-list ENTRY."
  (gethash (car entry) yt-feed--table))

(defun yt-feed--sort-age (a b)
  "Return non-nil if entry A is newer than entry B."
  (let ((va (yt-feed--entry-video a))
        (vb (yt-feed--entry-video b)))
    (let ((ta (or (yt-video-timestamp va) 0))
          (tb (or (yt-video-timestamp vb) 0)))
      (if (= ta tb)
          (< (or (yt-video-feed-index va) 0) (or (yt-video-feed-index vb) 0))
        (> ta tb)))))

(defun yt-feed--sort-duration (a b)
  "Return non-nil if entry A is shorter than entry B."
  (< (or (yt-video-duration (yt-feed--entry-video a)) 0)
     (or (yt-video-duration (yt-feed--entry-video b)) 0)))

;;;; Printing

(defun yt-feed--row-positions ()
  "Return a hash table mapping the ids of the printed rows to positions."
  (let ((rows (make-hash-table :test #'equal)))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (tabulated-list-get-id)))
          (puthash id (point) rows))
        (forward-line 1)))
    rows))

(defun yt-feed--printed-ids ()
  "Return the ids of the printed rows, in order."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (tabulated-list-get-id)))
          (push id ids))
        (forward-line 1)))
    (nreverse ids)))

(defun yt-feed--find-row (id old-ids rows)
  "Return the position of the row of ID, or of the nearest row.
OLD-IDS are the ids printed before, in order, and ROWS maps the ids
printed now to their positions.  If ID is gone, the nearest row is
the first later row of OLD-IDS still printed, else the last earlier
one.  Return nil if there is no row."
  (or (and id (gethash id rows))
      (let ((tail (member id old-ids)))
        (or (seq-some (lambda (other) (gethash other rows)) (cdr tail))
            (seq-some (lambda (other) (gethash other rows))
                      (reverse (seq-take old-ids (- (length old-ids)
                                                    (length tail)))))))))

(defun yt-feed--insert-placeholder ()
  "Explain the empty feed at the end of the buffer."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert "\n  "
              (cond (yt-feed--status yt-feed--status)
                    (yt-feed--refreshing "Fetching the feed…")
                    (yt-feed--error yt-feed--error)
                    ((and yt-feed--videos (yt-feed--hidden-message)))
                    ((eq (car-safe yt-feed--source) 'search)
                     (format "No results for “%s”." (cadr yt-feed--source)))
                    ((and (eq yt-feed--source 'subscriptions)
                          (not (file-exists-p (yt-auth-cookie-file))))
                     (substitute-command-keys
                      "\\<yt-feed-mode-map>Not signed in yet.  To sign in:
    1. In Chromium, make a profile used only for YouTube, and sign in to YouTube there.
    2. Press \\[yt-login] and choose that profile.
    3. Press \\[yt-feed-refresh] to fetch your subscriptions."))
                    (t (substitute-command-keys
                        "No videos yet.  Press \\<yt-feed-mode-map>\\[yt-feed-refresh] to refresh.")))
              "\n"))))

(defun yt-feed--hidden-message ()
  "Say why every video of the feed is hidden, and how to show them.
Return nil if no filter is on."
  (let* ((filter yt-feed--filter)
         (reasons
          (delq nil
                (list (and (plist-get filter :query)
                           (format "the filter “%s” (\\[yt-feed-clear-filters] clears it)"
                                   (plist-get filter :query)))
                      (and (plist-get filter :channel)
                           (format "the channel filter %s (\\[yt-feed-clear-filters] clears it)"
                                   (cdr (plist-get filter :channel))))
                      (and (plist-get filter :hide-watched)
                           "hiding watched videos (\\[yt-feed-toggle-hide-watched] shows them)")
                      (and (plist-get filter :hide-shorts)
                           "hiding Shorts (\\[yt-feed-toggle-hide-shorts] shows them)")
                      (and (plist-get filter :hide-upcoming)
                           "hiding upcoming videos (\\[yt-feed-toggle-hide-upcoming] shows them)")
                      (and (plist-get filter :hide-muted) yt-feed--muted
                           (> (hash-table-count yt-feed--muted) 0)
                           "hiding muted channels (\\[yt-feed-toggle-hide-muted] shows them)")
                      (and (plist-get filter :only-arrived)
                           "showing only new ones (\\[yt-feed-toggle-only-arrived] shows all)")))))
    (and reasons
         (substitute-command-keys
          (concat "\\<yt-feed-mode-map>"
                  (format "All %d videos are hidden by " (length yt-feed--videos))
                  (string-join reasons "; ")
                  ".")))))

(defun yt-feed--redisplay ()
  "Print the feed again, keeping each window on the same video.
The row at point in each window showing the buffer, and the number
of lines above it in the window, are restored.  A row that was
filtered out is replaced by its nearest neighbour."
  (yt-feed--update-kept)
  (setq yt-feed--muted (and (eq yt-feed--source 'subscriptions) (yt-cache-muted-channels)))
  (let* ((old-ids (yt-feed--printed-ids))
         (point-id (tabulated-list-get-id))
         (windows (mapcar (lambda (window)
                            (with-selected-window window
                              (list window (tabulated-list-get-id)
                                    (count-lines (window-start)
                                                 (line-beginning-position)))))
                          (get-buffer-window-list nil nil t))))
    (tabulated-list-print)
    (yt-feed--request-thumbnails)
    (let ((rows (yt-feed--row-positions)))
      (setq yt-feed--shown (hash-table-count rows))
      (when (zerop yt-feed--shown)
        (yt-feed--insert-placeholder))
      (goto-char (or (yt-feed--find-row point-id old-ids rows) (point-min)))
      (pcase-dolist (`(,window ,id ,above) windows)
        (let ((pos (or (yt-feed--find-row id old-ids rows) (point-min))))
          (set-window-point window pos)
          (set-window-start window (save-excursion
                                     (goto-char pos)
                                     (forward-line (- above))
                                     (point))))))))

(defun yt-feed--redraw-rows (ids)
  "Print the rows of the videos with IDS again, leaving the others alone."
  (let ((inhibit-read-only t)
        (now (yt--now)))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((id (tabulated-list-get-id))
               (video (and id (member id ids) (gethash id yt-feed--table))))
          (if (not video)
              (forward-line 1)
            (delete-region (line-beginning-position)
                           (min (point-max) (1+ (line-end-position))))
            (apply tabulated-list-printer (yt-feed--entry video now))))))))

(defun yt-feed--watched-changed (ids watched)
  "Update the feed buffers after the videos with IDS were marked WATCHED."
  (dolist (buffer (yt-feed--buffers))
    (with-current-buffer buffer
      (let ((shown nil))
        (dolist (id ids)
          (when-let* ((video (gethash id yt-feed--table)))
            (setf (yt-video-watched video) watched)
            (setq shown t)))
        (when shown
          (if (plist-get yt-feed--filter :hide-watched)
              (yt-feed--redisplay)
            (yt-feed--redraw-rows ids)))))))

(defun yt-feed--subscriptions-changed (channel subscribed)
  "Update the feed buffers after a change of subscription to CHANNEL.
SUBSCRIBED is non-nil if you are now subscribed.  After
unsubscribing, the channel's videos leave the subscription feed.
After subscribing, the next refresh fetches the whole feed, since
the channel's videos are older than those already cached."
  (if subscribed
      (setq yt-feed--fully-refreshed (delete 'subscriptions yt-feed--fully-refreshed))
    (dolist (buffer (yt-feed--buffers))
      (with-current-buffer buffer
        (when (eq yt-feed--source 'subscriptions)
          (yt-feed--set-videos
           (seq-remove (lambda (video)
                         (equal (yt-video-channel-id video) (plist-get channel :id)))
                       yt-feed--videos))
          (yt-feed--redisplay)))))
  (dolist (buffer (yt-feed--buffers))
    (with-current-buffer buffer
      (yt-feed--update-kept)
      (force-mode-line-update))))

(defun yt-feed--auth-changed ()
  "Update the header lines of the feed buffers."
  (dolist (buffer (yt-feed--buffers))
    (with-current-buffer buffer
      (force-mode-line-update))))

(defun yt-feed--update-ages ()
  "Print the visible feed buffers again so that their ages are current.
Stop the timer when no feed buffer is left."
  (let ((buffers (yt-feed--buffers)))
    (if (not buffers)
        (progn (cancel-function-timers #'yt-feed--update-ages)
               (setq yt-feed--age-timer nil))
      (dolist (buffer buffers)
        (when (get-buffer-window buffer t)
          (with-current-buffer buffer
            (unless yt-feed--refreshing
              (yt-feed--redisplay))))))))

;;;; Header line

(defvar-keymap yt-feed--sign-in-map
  :doc "Keymap of the sign-in button in the header line."
  "<header-line> <mouse-1>" #'yt-login
  "<header-line> <mouse-2>" #'yt-login)

(defvar-local yt-feed--kept nil
  "Whether this buffer's playlist is saved or its channel subscribed.
One of `saved', `not-saved', `subscribed', `not-subscribed', or nil
when there is nothing to say.  The header line reads it, so that
redisplay does not query the cache; `yt-feed--update-kept' sets it.")

(defun yt-feed--update-kept ()
  "Set `yt-feed--kept' from the cache."
  (setq yt-feed--kept
        (pcase yt-feed--source
          (`(playlist ,id . ,_)
           (if (yt-cache-playlist-saved-p id) 'saved 'not-saved))
          (`(channel ,id . ,_)
           ;; Known only once the channel list was fetched.
           (when (yt-cache-meta "refreshed:channels")
             (if (yt-cache-subscribed-p id) 'subscribed 'not-subscribed))))))

(defun yt-feed--header-line ()
  "Return the header line of a feed buffer."
  (let* ((state (yt-auth-state))
         (count yt-feed--shown)
         (total (length yt-feed--videos))
         (parts
          (list
           (and (memq state '(no-cookies expired bad-profile keyring corrupt-cookies))
                (propertize (substitute-command-keys
                             "Not signed in: press \\[yt-login]")
                            'face 'warning 'mouse-face 'header-line-highlight
                            'keymap yt-feed--sign-in-map
                            'help-echo "mouse-1: sign in to YouTube"))
           (when-let* ((paused (yt-auth-backoff-description)))
             (propertize paused 'face 'warning))
           (pcase yt-feed--kept
             ('saved (propertize "saved playlist" 'face 'success))
             ('not-saved (substitute-command-keys
                          "\\<yt-feed-mode-map>\\[yt-feed-add] saves this playlist"))
             ('subscribed (propertize "subscribed" 'face 'success))
             ('not-subscribed (substitute-command-keys
                               "\\<yt-feed-mode-map>\\[yt-feed-add] subscribes")))
           (cond (yt-feed--status (propertize yt-feed--status 'face 'shadow))
                 (yt-feed--error (propertize yt-feed--error 'face 'warning)))
           (if yt-feed--refreshed-at
               (format "updated %s" (yt-list-ago yt-feed--refreshed-at))
             "never updated")
           (when-let* ((visit yt-feed--last-visit)
                       (arrived (yt-feed--arrived-count))
                       ((> arrived 0)))
             (propertize (format "◆ %d new since %s" arrived (yt-list-ago visit))
                         'face 'yt-feed-arrived-marker))
           (yt-feed--filter-description)
           (if (= count total)
               (format "%d videos" total)
             (format "%d of %d videos" count total)))))
    (concat " " (string-join (delq nil parts) "  ·  "))))

;;;; Refreshing

(defun yt-feed--fresh-p ()
  "Return non-nil if the feed was refreshed recently enough to show as is."
  (and yt-feed--refreshed-at
       (< (- (yt--now) yt-feed--refreshed-at) yt-feed-refresh-interval)))

(defun yt-feed--load-cache ()
  "Fill this buffer from the cache, if its feed is kept there."
  (when-let* ((source (yt-feed--cache-source)))
    (yt-feed--set-videos (yt-cache-feed source))
    (setq yt-feed--refreshed-at (yt-cache-meta (concat "refreshed:" source)))))

(defun yt-feed--start (status)
  "Start a refresh with STATUS, and return its number."
  (setq yt-feed--refreshing (cl-incf yt-feed--refresh-count)
        yt-feed--status status
        yt-feed--error nil)
  (force-mode-line-update)
  yt-feed--refreshing)

(defun yt-feed--current-p (buffer run)
  "Return non-nil if BUFFER is live and RUN is its running refresh."
  (and (buffer-live-p buffer)
       (eql run (buffer-local-value 'yt-feed--refreshing buffer))))

(defun yt-feed--fail (message)
  "End the running refresh with the error MESSAGE."
  (setq yt-feed--refreshing nil
        yt-feed--status nil
        yt-feed--error message)
  (yt-feed--redisplay)
  (force-mode-line-update)
  (message "%s" message))

(defun yt-feed--failure-message (err)
  "Return the message to show for the failed refresh ERR."
  (if (eq (plist-get err :class) 'network)
      "Offline: showing the cached feed"
    (or (plist-get err :message) "Refreshing the feed failed")))

(defvar-local yt-feed-refreshed-hook nil
  "Hook run in a feed buffer after a refresh showed its videos.")

(defun yt-feed--fetched (buffer run videos info full)
  "Show VIDEOS fetched by the refresh RUN of BUFFER.
INFO is from `yt-auth-run'; FULL is non-nil for a full refresh."
  (when (yt-feed--current-p buffer run)
    (with-current-buffer buffer
      (let* ((source (yt-feed--cache-source))
             (now (truncate (yt--now)))
             (new (seq-count (lambda (video)
                               (not (gethash (yt-video-id video) yt-feed--table)))
                             videos)))
        (if source
            (progn (yt-feed--set-videos
                    (yt-cache-put-feed source videos
                                       (plist-get (yt-feed--fetch-spec) :replace)))
                   (yt-cache-set-meta (concat "refreshed:" source) now))
          (let ((index -1))
            (dolist (video (setq videos (yt-cache-put-videos videos)))
              (setf (yt-video-feed-index video) (cl-incf index))))
          (yt-feed--set-videos videos)
          (setq new nil))
        (when (and full (not (plist-get info :stopped)))
          (cl-pushnew yt-feed--source yt-feed--fully-refreshed :test #'equal))
        ;; YouTube answered, so thumbnails that failed offline may work.
        (when info
          (yt-thumbs-forget-failures))
        (setq yt-feed--refreshed-at now
              yt-feed--refreshing nil
              yt-feed--status nil)
        (yt-feed--redisplay)
        (force-mode-line-update)
        (run-hooks 'yt-feed-refreshed-hook)
        (message "yt: %s" (cond ((not new) (format "%d results" (length videos)))
                                ((zerop new) "no new videos")
                                (t (format "%d new video%s" new
                                           (if (= new 1) "" "s")))))))))

(defun yt-feed--fetch (full)
  "Fetch this buffer's feed; FULL non-nil means do not stop early."
  (let* ((buffer (current-buffer))
         (spec (yt-feed--fetch-spec))
         (known yt-feed--table)
         (stop-after (and (not full) (plist-get spec :stop-early)
                          yt-feed-stop-after-known))
         (approx (plist-get spec :approx))
         (videos nil)
         (streak 0)
         (run (yt-feed--start nil)))
    (yt-auth-run
     (plist-get spec :args)
     :parse 'ndjson :key (yt-feed--process-key) :force full
     :source (plist-get spec :auth-source) :redact (plist-get spec :redact)
     :on-line (lambda (entry)
                (when-let* ((video (yt-video-from-json entry approx)))
                  (push video videos)
                  (setq streak (if (and known (gethash (yt-video-id video) known))
                                   (1+ streak)
                                 0))
                  (and stop-after (>= streak stop-after) 'stop)))
     :on-success (lambda (_value info)
                   (yt-feed--finish buffer run
                                    (lambda ()
                                      (yt-feed--fetched buffer run (nreverse videos)
                                                        info full))))
     :on-error (lambda (err)
                 (when (and (yt-feed--current-p buffer run)
                            (not (eq (plist-get err :type) 'cancelled)))
                   (yt-feed--finish
                    buffer run
                    (lambda ()
                      ;; Keep what arrived before a timeout or a network
                      ;; error; a playlist is only replaced when whole.
                      (when (and videos (memq (plist-get err :type) '(timeout exit))
                                 (not (plist-get spec :replace)))
                        (yt-feed--fetched buffer run (nreverse videos) nil nil))
                      (with-current-buffer buffer
                        (yt-feed--fail (yt-feed--failure-message err))))))))))

(defun yt-feed--finish (buffer run fn)
  "Call FN to end the refresh RUN of BUFFER.
If FN signals, the refresh still ends, with the error as its message,
so that it is not left running for ever."
  (condition-case err
      (funcall fn)
    (error
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         ;; Unless a newer refresh has started meanwhile.
         (when (memql yt-feed--refreshing (list nil run))
           (yt-feed--fail (format "Refreshing failed: %s"
                                  (error-message-string err)))))))))

(defun yt-feed--sign-in ()
  "Export the cookies of the Chromium profile, then refresh the feed."
  (let* ((buffer (current-buffer))
         (profile (yt-auth-ensure-profile))
         (run (yt-feed--start (format "Signing in via Chromium profile %s…"
                                      (yt-auth-profile-label profile)))))
    (yt-feed--redisplay)
    (yt-auth-export
     (lambda (ok result)
       (when (yt-feed--current-p buffer run)
         (with-current-buffer buffer
           (if ok
               (yt-feed--fetch t)
             (yt-feed--fail (plist-get result :message)))))))))

(defun yt-feed-refresh (&optional full)
  "Fetch the newest videos of the feed and merge them into it.
The refresh stops after `yt-feed-stop-after-known' cached videos in
a row, except the first one of a session.  With prefix argument
FULL, cancel a running refresh and fetch `yt-feed-limit' videos."
  (interactive "P" yt-feed-mode)
  (cond
   ((and yt-feed--refreshing (not full))
    (message "The feed is already refreshing; %s cancels and refetches it all"
             (substitute-command-keys "\\[yt-feed-refresh-all]")))
   ((not (file-exists-p (yt-auth-cookie-file)))
    (yt-feed--sign-in))
   (t
    (yt-feed--fetch (or full (not (member yt-feed--source yt-feed--fully-refreshed))))
    (yt-feed--redisplay))))

(defun yt-feed-refresh-all ()
  "Cancel a running refresh and fetch the whole feed again."
  (interactive nil yt-feed-mode)
  (yt-feed-refresh t))

(defun yt-feed--revert (&rest _)
  "Refresh the feed, for `revert-buffer'."
  (yt-feed-refresh))

(defun yt-feed--cancel ()
  "Cancel this buffer's refresh."
  (yt-process-cancel (yt-feed--process-key)))

;;;; Commands on the feed

(defun yt-feed-mark-all-watched ()
  "Mark every video shown in the feed as watched, after confirmation.
The filters apply: hidden videos are left alone.  \\`u' right after
undoes it."
  (interactive nil yt-feed-mode)
  (let ((videos (seq-remove #'yt-video-watched (yt-feed--filtered-videos))))
    (if (not videos)
        (message "No unwatched videos are shown")
      (when (y-or-n-p (format "Mark the %d unwatched videos shown as watched? "
                              (length videos)))
        (yt-mark-watched videos)
        (set-transient-map
         (define-keymap "u" (lambda ()
                              (interactive)
                              (yt-mark-watched videos t)
                              (message "Marked %d videos as not watched again"
                                       (length videos)))))
        (message "Marked %d videos as watched; u right away undoes it"
                 (length videos))))))

;;;; Filter commands

(defun yt-feed--set-filter (&rest plist)
  "Change the filter by the properties in PLIST and print the feed again."
  (while plist
    (setq yt-feed--filter (plist-put yt-feed--filter (pop plist) (pop plist))))
  (yt-feed--redisplay)
  (force-mode-line-update))

(defvar yt-feed-filter-delay 0.15
  "Seconds of no typing after which the feed shows the filter being typed.")

(defun yt-feed--read-query ()
  "Read a filter query, showing its result in the feed as it is typed.
Quitting restores the previous query."
  (let ((buffer (current-buffer))
        (old (plist-get yt-feed--filter :query))
        (timer nil))
    (condition-case nil
        (minibuffer-with-setup-hook
            (lambda ()
              (add-hook 'after-change-functions
                        (lambda (&rest _)
                          (when timer (cancel-timer timer))
                          (let ((text (minibuffer-contents-no-properties)))
                            (setq timer
                                  (run-with-timer
                                   yt-feed-filter-delay nil
                                   (lambda ()
                                     (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (yt-feed--set-filter
                                          :query (and (not (string-blank-p text))
                                                      text)))))))))
                        nil t)
              (add-hook 'minibuffer-exit-hook
                        (lambda () (when timer (cancel-timer timer)))
                        nil t))
          (read-string "Filter (words, @channel, !exclude): " old
                       (yt-minibuffer-history 'yt-filter-history)))
      (quit (when timer (cancel-timer timer))
            (yt-feed--set-filter :query old)
            (signal 'quit nil)))))

(defun yt-feed-filter (query)
  "Show only the videos matching QUERY.
QUERY is a list of words that must all occur in the title or channel.
A word starting with @ must occur in the channel, and one starting
with ! must not occur.  Interactively, the feed follows the query as
you type it.  An empty QUERY shows all videos."
  (interactive (list (yt-feed--read-query)) yt-feed-mode)
  (yt-feed--set-filter :query (and (not (string-blank-p query)) query)))

(defun yt-feed-filter-channel (channel)
  "Show only the videos of CHANNEL, a pair (ID . NAME).
Interactively, ask for one of the channels in the feed, defaulting
to the channel of the video at point."
  (interactive
   (let* ((channels (delete-dups
                     (delq nil (mapcar (lambda (video)
                                         (when-let* ((name (yt-video-channel video)))
                                           (cons name (yt-video-channel-id video))))
                                       yt-feed--videos))))
          (here (when-let* ((video (yt-feed-video-at-point)))
                  (yt-video-channel video)))
          (name (completing-read "Channel: " channels nil t nil
                                 (yt-minibuffer-history 'yt-filter-history) here)))
     (list (cons (cdr (assoc name channels)) name)))
   yt-feed-mode)
  (yt-feed--set-filter :channel channel))

(defun yt-feed-clear-filters ()
  "Show the videos hidden by the query and channel filters."
  (interactive nil yt-feed-mode)
  (yt-feed--set-filter :query nil :channel nil))

(defun yt-feed--toggle (property what)
  "Toggle the filter PROPERTY, which hides WHAT, and say so."
  (let ((on (not (plist-get yt-feed--filter property))))
    (yt-feed--set-filter property on)
    (message "%s %s" (if on "Hiding" "Showing") what)))

(defun yt-feed-toggle-hide-watched ()
  "Toggle whether the feed hides videos you have watched."
  (interactive nil yt-feed-mode)
  (yt-feed--toggle :hide-watched "watched videos"))

(defun yt-feed-toggle-hide-shorts ()
  "Toggle whether the feed hides Shorts."
  (interactive nil yt-feed-mode)
  (yt-feed--toggle :hide-shorts "Shorts"))

(defun yt-feed-toggle-only-arrived ()
  "Toggle whether the feed shows only videos new since your last visit."
  (interactive nil yt-feed-mode)
  (let ((on (not (plist-get yt-feed--filter :only-arrived))))
    (yt-feed--set-filter :only-arrived on)
    (message (if on "Showing only videos new since your last visit" "Showing all videos"))))

(defun yt-feed-toggle-hide-muted ()
  "Toggle whether the subscription feed hides muted channels."
  (interactive nil yt-feed-mode)
  (yt-feed--toggle :hide-muted "muted channels"))

(defun yt-feed-toggle-mute (id _url name)
  "Mute the channel NAME with ID, or unmute it if it is muted.
A muted channel's videos are hidden from the subscription feed;
\\[yt-feed-toggle-hide-muted] there shows them.  Interactively,
the channel at hand."
  (interactive (yt-channel-at-point))
  (let ((muted (not (gethash id (yt-cache-muted-channels)))))
    (yt-cache-set-muted id name muted)
    (message (if muted
                 "Muted %s: its videos are hidden from the subscription feed"
               "Unmuted %s")
             name)))

(defun yt-feed--muted-changed ()
  "Show the feed buffers again after a channel was muted or unmuted."
  (dolist (buffer (yt-feed--buffers))
    (with-current-buffer buffer
      (when (eq yt-feed--source 'subscriptions)
        (yt-feed--redisplay)))))

(defun yt-feed-toggle-hide-upcoming ()
  "Toggle whether the feed hides upcoming and live streams."
  (interactive nil yt-feed-mode)
  (yt-feed--toggle :hide-upcoming "upcoming and live streams"))

;;;; Mode

(defvar-keymap yt-feed-toggle-map
  :doc "Keys toggling what the feed hides."
  "w" #'yt-feed-toggle-hide-watched
  "s" #'yt-feed-toggle-hide-shorts
  "u" #'yt-feed-toggle-hide-upcoming
  "m" #'yt-feed-toggle-hide-muted
  "n" #'yt-feed-toggle-only-arrived
  "i" #'yt-feed-toggle-thumbnails)

(defvar-keymap yt-feed-mode-map
  :doc "Keymap for `yt-feed-mode'."
  :parent (make-composed-keymap yt-video-actions-map tabulated-list-mode-map)
  "g" #'yt-feed-refresh
  "G" #'yt-feed-refresh-all
  "/" #'yt-feed-filter
  "s" #'yt-list-filter-with-s
  "j" yt-map
  "c" #'yt-feed-filter-channel
  "C" #'yt-feed-clear-filters
  "t" (cons "toggle" yt-feed-toggle-map)
  "l" #'yt-channels
  "z" #'yt-feed-shuffle
  "A" #'yt-feed-play-all-from-here
  "W" #'yt-feed-mark-all-watched
  "x" #'yt-feed-toggle-mute
  "+" #'yt-feed-add
  "-" #'yt-feed-remove
  "L" #'yt-login)

(defconst yt-feed--format
  [(" " 1 nil)
   ("Channel" 20 t)
   ("Title" 70 t)
   ("Age" 5 yt-feed--sort-age :right-align t)
   ("Dur" 8 yt-feed--sort-duration :right-align t)]
  "The columns of the feed without thumbnails.")

(defun yt-feed--set-format ()
  "Set the columns of this buffer, with a thumbnail column if shown.
The Title column fits the window; see `yt-list-fit-columns'."
  (yt-list-fit-columns
   (if (yt-feed--thumbnails-p)
       (vconcat (list (list "" (1+ (ceiling (* yt-thumbs-height 16) (* 9 (max 1 (frame-char-width)))))
                            nil))
                yt-feed--format)
     yt-feed--format)))

(defun yt-feed--visible-ids ()
  "Return the ids of the rows visible in windows, and of a few rows below."
  (let (ids)
    (dolist (window (get-buffer-window-list nil nil t))
      (save-excursion
        (goto-char (window-start window))
        (let ((end (window-end window t))
              (extra 10))
          (while (and (not (eobp)) (or (< (point) end) (>= (cl-decf extra) 0)))
            (when-let* ((id (tabulated-list-get-id)))
              (push id ids))
            (forward-line 1)))))
    (delete-dups ids)))

(defun yt-feed--request-thumbnails ()
  "Download the thumbnails of the rows about to be seen."
  (when (yt-feed--thumbnails-p)
    (yt-thumbs-fetch (yt-feed--visible-ids))))

(defun yt-feed--schedule-thumbnails (&rest _)
  "Request thumbnails shortly, after scrolling settles."
  (when (yt-feed--thumbnails-p)
    (let ((buffer (current-buffer)))
      (when (timerp yt-feed--thumbnail-timer)
        (cancel-timer yt-feed--thumbnail-timer))
      (setq yt-feed--thumbnail-timer
            (run-with-idle-timer 0.2 nil
                                 (lambda ()
                                   (when (buffer-live-p buffer)
                                     (with-current-buffer buffer
                                       (yt-feed--request-thumbnails)))))))))

(defun yt-feed--thumbnail-arrived (id)
  "Show the thumbnail of ID in the feed buffers showing thumbnails."
  (dolist (buffer (yt-feed--buffers))
    (with-current-buffer buffer
      (when (and (yt-feed--thumbnails-p) (gethash id yt-feed--table))
        (yt-feed--redraw-rows (list id))))))

(defun yt-feed-toggle-thumbnails ()
  "Toggle thumbnails in this feed."
  (interactive nil yt-feed-mode)
  (setq yt-feed--thumbnails (not yt-feed--thumbnails))
  (when (and yt-feed--thumbnails (not (yt-feed--images-p)))
    (message "This frame cannot show images"))
  (yt-feed--set-format)
  (yt-feed--redisplay)
  (message "%s thumbnails" (if yt-feed--thumbnails "Showing" "Hiding")))

(define-derived-mode yt-feed-mode tabulated-list-mode "yt"
  "Major mode for a list of YouTube videos.
The rows are in the order of the feed; \\[tabulated-list-sort] sorts by
the column at point.  The header line shows the sign-in state, when
the feed was updated, the active filters and the number of videos.

\\{yt-feed-mode-map}"
  :group 'yt-feed
  :interactive nil
  (setq tabulated-list-entries #'yt-feed--entries
        tabulated-list-sort-key nil
        tabulated-list-use-header-line nil
        header-line-format '(:eval (yt-feed--header-line))
        mode-line-process '(:eval (and yt-feed--refreshing " Refreshing…")))
  (setq-local yt-feed--filter (list :hide-watched yt-feed-hide-watched
                                    :hide-shorts yt-feed-hide-shorts
                                    :hide-upcoming yt-feed-hide-upcoming
                                    :hide-muted t))
  (setq-local revert-buffer-function #'yt-feed--revert)
  (setq-local yt-video-at-point-function #'yt-feed-video-at-point)
  (setq-local yt-list-reprint-function #'yt-feed--redisplay)
  (setq-local yt-feed--thumbnails yt-feed-thumbnails)
  (yt-feed--set-videos nil)
  (add-hook 'window-scroll-functions #'yt-feed--schedule-thumbnails nil t)
  (add-hook 'yt-thumbs-changed-functions #'yt-feed--thumbnail-arrived)
  (add-hook 'kill-buffer-hook #'yt-feed--cancel nil t)
  (add-hook 'yt-watched-changed-functions #'yt-feed--watched-changed)
  (add-hook 'yt-auth-state-change-hook #'yt-feed--auth-changed)
  (add-hook 'yt-subscriptions-changed-functions #'yt-feed--subscriptions-changed)
  (add-hook 'yt-muted-changed-hook #'yt-feed--muted-changed)
  (unless (memq yt-feed--age-timer timer-list)
    (setq yt-feed--age-timer (run-with-timer yt-feed-age-update-interval
                                             yt-feed-age-update-interval
                                             #'yt-feed--update-ages)))
  (yt-feed--set-format))

(defun yt-feed--show (source name)
  "Show the feed SOURCE in the buffer NAME, from the cache, then refreshed.
The feed is not refreshed if that happened less than
`yt-feed-refresh-interval' seconds ago.  Return the buffer."
  (let ((buffer (get-buffer name)))
    (unless (and buffer (equal (buffer-local-value 'yt-feed--source buffer) source))
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        (yt-feed-mode)
        (setq yt-feed--source source)
        (yt-feed--load-cache)
        (yt-feed--redisplay)))
    (pop-to-buffer-same-window buffer)
    (unless (or yt-feed--refreshing (yt-feed--fresh-p))
      (yt-feed-refresh))
    buffer))

;;;###autoload
(defun yt-feed-subscriptions ()
  "Show the subscription feed, from the cache at first, then refreshed.
The feed is not refreshed if that happened less than
`yt-feed-refresh-interval' seconds ago."
  (interactive)
  (let ((buffer (yt-feed--show 'subscriptions yt-feed-subscriptions-buffer)))
    (with-current-buffer buffer
      (yt-feed--note-visit)
      (yt-feed--redisplay))
    buffer))

;;;###autoload
(defun yt-feed-channel (id url name)
  "Show the uploads of the channel NAME with ID and page URL.
Like the subscription feed, they show from the cache at first."
  (yt-feed--show (list 'channel id url name) (format "*yt: %s*" name)))

(defun yt-feed-open-channel (video)
  "Show the uploads of the channel of VIDEO.
Interactively, use the video at point."
  (interactive (list (or (yt-video-at-point) (user-error "No video here"))))
  (let ((id (yt-video-channel-id video))
        (url (yt-video-channel-url video)))
    (unless (or id url)
      (user-error "The channel of this video is not known"))
    (yt-feed-channel (or id url)
                     (if id (yt-channel-page-url id) url)
                     (or (yt-video-channel video) id))))

(defun yt-channel-at-point ()
  "Return (ID URL NAME) of the channel at hand, or signal a `user-error'.
That is the channel of the video at point, the channel whose uploads
this buffer shows, or the channel at point in the channels list."
  (or (when-let* ((video (yt-video-at-point))
                  (id (or (yt-video-channel-id video) (yt-video-channel-url video))))
        (list id (if (yt-video-channel-id video)
                     (yt-channel-page-url id)
                   (yt-video-channel-url video))
              (or (yt-video-channel video) id)))
      (pcase (bound-and-true-p yt-feed--source)
        (`(channel ,id ,url ,name) (list id url name)))
      (and yt-channel-at-point-function (funcall yt-channel-at-point-function))
      (user-error "No channel here")))

;;;###autoload
(defun yt-feed-playlist (id url title)
  "Show the videos of the playlist TITLE with ID and URL, in its order."
  (yt-feed--show (list 'playlist id url title) (format "*yt: Playlist: %s*" title)))

(defun yt-feed--playlist-id ()
  "Return the id of this buffer's playlist, or nil."
  (pcase yt-feed--source
    (`(playlist ,id . ,_) id)))

(defun yt-feed--playlist ()
  "Return this buffer's playlist as a plist, or signal a `user-error'."
  (pcase yt-feed--source
    (`(playlist ,id ,url ,title)
     (let ((first (car yt-feed--videos)))
       (list :id id :url url :title title
             ;; A channel's own playlist: its videos name the channel.
             :channel (and first (yt-video-channel first))
             :channel-id (and first (yt-video-channel-id first)))))
    (_ (user-error "This is not a playlist"))))

(defun yt-feed-save-playlist ()
  "Save this playlist; \\[yt-saved-playlists] lists the saved ones."
  (interactive nil yt-feed-mode)
  (let ((playlist (yt-feed--playlist)))
    (yt-cache-save-playlist playlist)
    (yt-feed--update-kept)
    (force-mode-line-update)
    (message "Saved the playlist “%s”" (plist-get playlist :title))))

(defun yt-feed-forget-playlist ()
  "Remove this playlist from the saved playlists."
  (interactive nil yt-feed-mode)
  (let ((playlist (yt-feed--playlist)))
    (yt-cache-forget-playlist (plist-get playlist :id))
    (yt-feed--update-kept)
    (force-mode-line-update)
    (message "Removed the playlist “%s” from the saved playlists"
             (plist-get playlist :title))))

(defun yt-feed-add ()
  "Save this playlist, or subscribe to the channel at hand.
In a playlist, save it, as \\[yt-feed-save-playlist] does.
Elsewhere, subscribe to the channel of the video at point, or to
the channel whose uploads this buffer shows; see `yt-subscribe'."
  (interactive nil yt-feed-mode)
  (if (yt-feed--playlist-id)
      (yt-feed-save-playlist)
    (require 'yt-subscribe)
    (apply #'yt-subscribe (yt-channel-at-point))))

(defun yt-feed-remove ()
  "Forget this playlist, or unsubscribe from the channel at hand.
In a playlist, remove it from the saved playlists, as
\\[yt-feed-forget-playlist] does.  Elsewhere, unsubscribe from the
channel of the video at point, or from the channel whose uploads
this buffer shows, after confirmation; see `yt-unsubscribe'."
  (interactive nil yt-feed-mode)
  (if (yt-feed--playlist-id)
      (yt-feed-forget-playlist)
    (require 'yt-subscribe)
    (apply #'yt-unsubscribe (append (yt-channel-at-point) '(t)))))

(defun yt-feed-shuffle ()
  "Play the videos shown in this buffer in random order in mpv.
The filters apply: hidden videos are not played.  See `yt-player-shuffle'."
  (interactive nil yt-feed-mode)
  (yt-player-shuffle (yt-feed--filtered-videos) (yt-feed--source-name)))

(defun yt-feed--source-name ()
  "Return a description of this buffer's videos."
  (pcase yt-feed--source
    (`(playlist ,_ ,_ ,title) title)
    (`(channel ,_ ,_ ,name) name)
    (`(search ,query) query)
    (_ "the subscription feed")))

(defun yt-feed-play-all-from-here ()
  "Play the unwatched videos shown from point down, in order, in mpv.
The filters and the sort order apply.  Two are kept queued ahead; see
`yt-player-play-sequence'."
  (interactive nil yt-feed-mode)
  (unless (yt-feed-video-at-point)
    (user-error "No video here"))
  ;; The rows as shown, which may be sorted by a column.
  (let ((videos (save-excursion
                  (beginning-of-line)
                  (let (videos)
                    (while (not (eobp))
                      (when-let* ((video (yt-feed-video-at-point)))
                        (unless (yt-video-watched video)
                          (push video videos)))
                      (forward-line 1))
                    (nreverse videos)))))
    (unless videos
      (user-error "No unwatched videos from here on"))
    (yt-player-play-sequence videos (yt-feed--source-name))))

(defvar yt-search-history nil
  "History of `yt-search' queries.")

;;;###autoload
(defun yt-search (query)
  "Search YouTube for QUERY and list the results."
  (interactive (list (read-string "Search YouTube: " nil (yt-minibuffer-history 'yt-search-history))))
  (when (string-blank-p query)
    (user-error "Nothing to search for"))
  (yt-feed--show (list 'search (string-trim query))
                 (format "*yt: Search: %s*" (string-trim query))))

(provide 'yt-feed)
;;; yt-feed.el ends here
