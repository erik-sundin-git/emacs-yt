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

(declare-function yt-info "yt-info" (video))
(declare-function yt-channels "yt-channels" ())

;;;; Faces

(defface yt-feed-age '((t :inherit shadow))
  "Face for the age of a video."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-duration '((t :inherit shadow))
  "Face for the duration of a video."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-channel '((t :inherit font-lock-type-face))
  "Face for the channel of a video."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-title '((t :inherit default))
  "Face for the title of a video."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-title-unwatched '((t :inherit yt-feed-title))
  "Face for the title of a video you have not watched."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-title-watched '((t :inherit (shadow yt-feed-title)))
  "Face for the title of a video you have watched."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-live '((t :inherit error))
  "Face for videos that are live now."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-upcoming '((t :inherit warning))
  "Face for upcoming premieres and live streams."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-short '((t :inherit font-lock-comment-face))
  "Face for the badge of a Short."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defface yt-feed-new-marker '((t :inherit success))
  "Face for the marker of a video you have not watched."
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

;;;; Buffer state

(defconst yt-feed-subscriptions-buffer "*yt: Subscriptions*"
  "Name of the subscription feed buffer.")

(defvar-local yt-feed--source nil
  "The feed this buffer shows.
It is `subscriptions' for the subscription feed, (channel ID URL
NAME) for a channel's uploads, and (search QUERY) for search
results.")

(defvar yt-search-limit 20
  "Number of results of a search.")

(defvar-local yt-feed--videos nil
  "The videos of this buffer, in feed order, before filtering.")

(defvar-local yt-feed--table nil
  "Hash table mapping the ids of `yt-feed--videos' to the videos.")

(defvar-local yt-feed--filter nil
  "The active filter, a plist.
:query is the query string, see `yt-feed--parse-query'; :channel is
\(ID . NAME) of the channel shown; :hide-watched, :hide-shorts and
:hide-upcoming are booleans.")

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
    (`(channel ,id . ,_) (concat "channel:" id))))

(defun yt-feed--fetch-spec ()
  "Return how to fetch this buffer's feed, a plist.
:args are the yt-dlp arguments, :auth-source the SOURCE for
`yt-auth-run', :redact the arguments to keep out of logs, :approx
whether timestamps are approximate and :stop-early whether a
refresh may stop at cached videos."
  (pcase yt-feed--source
    ('subscriptions
     (list :args (yt-ytdlp-feed-args yt-feed-limit) :auth-source 'feed
           :approx t :stop-early t))
    (`(channel ,_id ,url . ,_)
     (list :args (yt-ytdlp-channel-args url yt-feed-limit) :approx t :stop-early t))
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

(defun yt-feed--parse-query (query)
  "Return the terms of the filter QUERY, a string, or nil.
Terms are separated by spaces and all must match.  A term matches
the title or channel; \"@term\" matches only the channel, and
\"!term\" matches videos whose title and channel lack it.  Each
term is returned as (KIND . TEXT), KIND being `any', `channel' or
`not', with TEXT in lower case."
  (delq nil
        (mapcar (lambda (word)
                  (let ((kind (pcase (aref word 0)
                                (?@ 'channel)
                                (?! 'not)
                                (_ 'any))))
                    (unless (eq kind 'any)
                      (setq word (substring word 1)))
                    (unless (string-empty-p word)
                      (cons kind (downcase word)))))
                (split-string (or query "") "[ \t]+" t))))

(defun yt-feed--match-p (video terms filter)
  "Return non-nil if VIDEO passes the query TERMS and the FILTER plist.
TERMS come from `yt-feed--parse-query'; see `yt-feed--filter' for
FILTER."
  (let ((title (downcase (or (yt-video-title video) "")))
        (channel (downcase (or (yt-video-channel video) "")))
        (shown (plist-get filter :channel)))
    (and (not (and (plist-get filter :hide-watched) (yt-video-watched video)))
         (not (and (plist-get filter :hide-shorts) (yt-video-short-p video)))
         (not (and (plist-get filter :hide-upcoming)
                   (memq (yt-video-live-status video) '(is_upcoming is_live))))
         (or (not shown)
             (if (car shown)
                 (equal (car shown) (yt-video-channel-id video))
               (equal (cdr shown) (yt-video-channel video))))
         (seq-every-p (lambda (term)
                        (let ((text (cdr term)))
                          (pcase (car term)
                            ('channel (string-search text channel))
                            ('not (not (or (string-search text title)
                                           (string-search text channel))))
                            (_ (or (string-search text title)
                                   (string-search text channel))))))
                      terms))))

(defun yt-feed--filtered-videos ()
  "Return the videos of this buffer that pass the filter, in feed order."
  (let ((terms (yt-feed--parse-query (plist-get yt-feed--filter :query))))
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
                                       "upcoming")))))
      (when hidden
        (push (concat "hiding " (string-join hidden ", ")) parts)))
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

(defun yt-feed--entry (video now)
  "Return the tabulated-list entry of VIDEO, with ages relative to NOW."
  (let ((watched (yt-video-watched video))
        (live (yt-video-live-status video)))
    (list (yt-video-id video)
          (vector
           (if watched " " (propertize "●" 'face 'yt-feed-new-marker))
           (propertize (yt-video-format-age (yt-video-timestamp video) now)
                       'face 'yt-feed-age)
           (pcase live
             ('is_live (propertize "LIVE" 'face 'yt-feed-live))
             ('is_upcoming (propertize "SOON" 'face 'yt-feed-upcoming))
             (_ (propertize (yt-video-format-duration (yt-video-duration video))
                            'face 'yt-feed-duration)))
           (propertize (or (yt-video-channel video) "") 'face 'yt-feed-channel)
           (concat (yt-feed--badge video)
                   (propertize (or (yt-video-title video) (yt-video-id video))
                               'face (if watched
                                         'yt-feed-title-watched
                                       'yt-feed-title-unwatched)))))))

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
                    ((and yt-feed--videos (yt-feed--filter-description))
                     "No videos match the filter.  Press C to clear it.")
                    (t (substitute-command-keys
                        "No videos yet.  Press \\[yt-feed-refresh] to refresh.")))
              "\n"))))

(defun yt-feed--redisplay ()
  "Print the feed again, keeping each window on the same video.
The row at point in each window showing the buffer, and the number
of lines above it in the window, are restored.  A row that was
filtered out is replaced by its nearest neighbour."
  (let* ((old-ids (yt-feed--printed-ids))
         (point-id (tabulated-list-get-id))
         (windows (mapcar (lambda (window)
                            (with-selected-window window
                              (list window (tabulated-list-get-id)
                                    (count-lines (window-start)
                                                 (line-beginning-position)))))
                          (get-buffer-window-list nil nil t))))
    (tabulated-list-print)
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

(defun yt-feed--ago (time)
  "Return how long ago TIME was, for the header line."
  (let ((age (yt-video-format-age time)))
    (if (equal age "now") "just now" (concat age " ago"))))

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
           (cond (yt-feed--status (propertize yt-feed--status 'face 'shadow))
                 (yt-feed--error (propertize yt-feed--error 'face 'warning)))
           (if yt-feed--refreshed-at
               (format "updated %s" (yt-feed--ago yt-feed--refreshed-at))
             "never updated")
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
            (progn (yt-feed--set-videos (yt-cache-put-feed source videos))
                   (yt-cache-set-meta (concat "refreshed:" source) now))
          (let ((index -1))
            (dolist (video (setq videos (yt-cache-put-videos videos)))
              (setf (yt-video-feed-index video) (cl-incf index))))
          (yt-feed--set-videos videos)
          (setq new nil))
        (when (and full (not (plist-get info :stopped)))
          (cl-pushnew yt-feed--source yt-feed--fully-refreshed :test #'equal))
        (setq yt-feed--refreshed-at now
              yt-feed--refreshing nil
              yt-feed--status nil)
        (yt-feed--redisplay)
        (force-mode-line-update)
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
                   (yt-feed--fetched buffer run (nreverse videos) info full))
     :on-error (lambda (err)
                 (when (and (yt-feed--current-p buffer run)
                            (not (eq (plist-get err :type) 'cancelled)))
                   (with-current-buffer buffer
                     (yt-feed--fail (yt-feed--failure-message err))))))))

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
  "Mark every video shown in the feed as watched."
  (interactive nil yt-feed-mode)
  (let ((videos (seq-remove #'yt-video-watched (yt-feed--filtered-videos))))
    (if (not videos)
        (message "No unwatched videos are shown")
      (when (yes-or-no-p (format "Mark %d videos as watched? " (length videos)))
        (yt-mark-watched videos)))))

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
          (read-string "Filter (words, @channel, !exclude): " old))
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
          (name (completing-read "Channel: " channels nil t nil nil here)))
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

(defun yt-feed-toggle-hide-upcoming ()
  "Toggle whether the feed hides upcoming and live streams."
  (interactive nil yt-feed-mode)
  (yt-feed--toggle :hide-upcoming "upcoming and live streams"))

;;;; Mode

(defvar-keymap yt-feed-toggle-map
  :doc "Keys toggling what the feed hides."
  "w" #'yt-feed-toggle-hide-watched
  "s" #'yt-feed-toggle-hide-shorts
  "u" #'yt-feed-toggle-hide-upcoming)

(defvar-keymap yt-feed-mode-map
  :doc "Keymap for `yt-feed-mode'."
  :parent (make-composed-keymap yt-video-actions-map tabulated-list-mode-map)
  "g" #'yt-feed-refresh
  "G" #'yt-feed-refresh-all
  "s" #'yt-feed-filter
  "/" #'yt-feed-filter
  "c" #'yt-feed-filter-channel
  "C" #'yt-feed-clear-filters
  "t" (cons "toggle" yt-feed-toggle-map)
  "l" #'yt-channels
  "L" #'yt-login)

(define-derived-mode yt-feed-mode tabulated-list-mode "yt"
  "Major mode for a list of YouTube videos.
The rows are in the order of the feed; \\[tabulated-list-sort] sorts by
the column at point.  The header line shows the sign-in state, when
the feed was updated, the active filters and the number of videos.

\\{yt-feed-mode-map}"
  :group 'yt-feed
  :interactive nil
  (setq tabulated-list-format
        [(" " 1 nil)
         ("Age" 5 yt-feed--sort-age :right-align t)
         ("Dur" 8 yt-feed--sort-duration :right-align t)
         ("Channel" 20 t)
         ("Title" 60 t)]
        tabulated-list-entries #'yt-feed--entries
        tabulated-list-sort-key nil
        tabulated-list-use-header-line nil
        header-line-format '(:eval (yt-feed--header-line))
        mode-line-process '(:eval (and yt-feed--refreshing " Refreshing…")))
  (setq-local yt-feed--filter (list :hide-watched yt-feed-hide-watched
                                    :hide-shorts yt-feed-hide-shorts
                                    :hide-upcoming yt-feed-hide-upcoming))
  (setq-local revert-buffer-function #'yt-feed--revert)
  (setq-local yt-video-at-point-function #'yt-feed-video-at-point)
  (yt-feed--set-videos nil)
  (add-hook 'kill-buffer-hook #'yt-feed--cancel nil t)
  (add-hook 'yt-watched-changed-functions #'yt-feed--watched-changed)
  (add-hook 'yt-auth-state-change-hook #'yt-feed--auth-changed)
  (unless (memq yt-feed--age-timer timer-list)
    (setq yt-feed--age-timer (run-with-timer yt-feed-age-update-interval
                                             yt-feed-age-update-interval
                                             #'yt-feed--update-ages)))
  (tabulated-list-init-header))

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
  (yt-feed--show 'subscriptions yt-feed-subscriptions-buffer))

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
                     (if id (format "https://www.youtube.com/channel/%s" id) url)
                     (or (yt-video-channel video) id))))

(defvar yt-search-history nil
  "History of `yt-search' queries.")

;;;###autoload
(defun yt-search (query)
  "Search YouTube for QUERY and list the results."
  (interactive (list (read-string "Search YouTube: " nil 'yt-search-history)))
  (when (string-blank-p query)
    (user-error "Nothing to search for"))
  (yt-feed--show (list 'search (string-trim query))
                 (format "*yt: Search: %s*" (string-trim query))))

(provide 'yt-feed)
;;; yt-feed.el ends here
