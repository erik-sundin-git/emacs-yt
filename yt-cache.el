;;; yt-cache.el --- SQLite cache of videos and watched state -*- lexical-binding: t; -*-

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

;; yt keeps the videos it has seen, their order in each feed, and the
;; watched state and resume position of each video in a SQLite file
;; (mode 0600) in `yt-state-directory'.  The feed buffer shows the
;; cache at once and merges each refresh into it.
;;
;; Only an allowlisted set of `yt-video' fields is stored, never raw
;; yt-dlp JSON, which can hold signed stream URLs naming the user's IP
;; address.  `yt-mark-watched' is the only way to change the watched
;; state; it runs `yt-watched-changed-functions' afterwards.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'yt)
(require 'yt-video)

(defvar yt-cache-feed-max 500
  "Maximum number of videos remembered in the order of each feed.
Older videos drop out of the feed but keep their watched state.")

(defvar yt-watched-changed-functions nil
  "Abnormal hook run after the watched state of videos changed.
Each function is called with a list of video ids and the new state,
non-nil for watched.")

(defvar yt-history-changed-hook nil
  "Hook run after the list of videos you played, or a resume position, changed.")

(defvar yt-subscriptions-changed-functions nil
  "Abnormal hook run after you subscribed to a channel or unsubscribed.
Each function is called with the channel, a plist with :id, :name
and :url, and non-nil if you are now subscribed.")

(defvar yt-cache--db nil
  "The open cache database, or nil.")

(defconst yt-cache--schema-version 4
  "Version of the cache schema, stored as SQLite's user_version.")

(defconst yt-cache--min-reader-version 4
  "The oldest schema version whose code can use a cache of this version.
It is kept in the cache's meta table as \"min_reader\".  A version that
only adds tables or columns keeps it, so that after a rollback an older
yt still opens the cache; one that changes what is there raises it.")

(defvar yt-cache-backups 3
  "Number of cache backups `yt-cache-backup' keeps.")

(eval-and-compile
  (defconst yt-cache--fields
    '(id title channel channel-id channel-url duration timestamp
         timestamp-approx-p views live-status thumbnail url short-p)
    "The `yt-video' slots stored in the cache.
Local state (watched, position, fetched-at) has its own columns,
and the feed index its own table."))

(defconst yt-cache--slots
  (eval-when-compile
    (mapcar (lambda (field)
              (list field (intern (format ":%s" field))
                    (cl-struct-slot-offset 'yt-video field)))
            yt-cache--fields))
  "(FIELD KEYWORD OFFSET) for each of `yt-cache--fields'.
The offsets are computed when this file is compiled, so that reading
and writing the fields needs neither cl-macs nor a lookup at run time.")

(defun yt-cache-file-name ()
  "Return the name of the cache database file, see `yt-cache-file'."
  (or yt-cache-file (expand-file-name "yt.sqlite" yt-state-directory)))

;;;; Opening

(defun yt-cache--create-schema (db)
  "Create the tables missing from DB and record the schema version.
Version 2 added the channels table, version 3 the playlists table."
  (dolist (sql '("CREATE TABLE IF NOT EXISTS videos (
                   id TEXT PRIMARY KEY, data TEXT NOT NULL,
                   fetched_at INTEGER, watched INTEGER NOT NULL DEFAULT 0,
                   position REAL)"
                 "CREATE TABLE IF NOT EXISTS feed (
                   source TEXT NOT NULL, id TEXT NOT NULL, pos INTEGER NOT NULL,
                   PRIMARY KEY (source, id))"
                 "CREATE INDEX IF NOT EXISTS feed_order ON feed (source, pos)"
                 "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value)"
                 "CREATE TABLE IF NOT EXISTS channels (
                   id TEXT PRIMARY KEY, pos INTEGER NOT NULL, data TEXT NOT NULL)"
                 "CREATE TABLE IF NOT EXISTS playlists (
                   id TEXT PRIMARY KEY, saved_at INTEGER NOT NULL, data TEXT NOT NULL)"
                 "CREATE TABLE IF NOT EXISTS history (
                   id TEXT PRIMARY KEY, played_at INTEGER NOT NULL)"
                 "CREATE INDEX IF NOT EXISTS history_order ON history (played_at)"))
    (sqlite-execute db sql))
  (sqlite-execute db (format "PRAGMA user_version = %d" yt-cache--schema-version))
  (sqlite-execute db "INSERT OR REPLACE INTO meta (key, value) VALUES ('min_reader', ?)"
                  (list yt-cache--min-reader-version)))

(defun yt-cache--backup-files (file)
  "Return the backups of the cache FILE, the newest first."
  (sort (file-expand-wildcards (concat file ".backup-*")) #'string>))

(defun yt-cache--write-backup (db file)
  "Write a copy of DB, the cache FILE, next to it; return its name.
Only `yt-cache-backups' backups are kept."
  (let ((backup (format "%s.backup-%s" file (format-time-string "%Y%m%d-%H%M%S"))))
    (with-file-modes #o600
      (sqlite-execute db (format "VACUUM INTO '%s'" (string-replace "'" "''" backup))))
    (set-file-modes backup #o600)
    (dolist (old (nthcdr yt-cache-backups (yt-cache--backup-files file)))
      (ignore-errors (delete-file old)))
    backup))

(defun yt-cache-backup ()
  "Write a copy of the cache next to it, keeping `yt-cache-backups' of them.
It holds the watch history, the resume positions and the saved
playlists.  yt also does this before it changes the cache's format."
  (interactive)
  (let ((backup (yt-cache--write-backup (yt-cache-db) (yt-cache-file-name))))
    (when (called-interactively-p 'any)
      (message "Wrote %s" (abbreviate-file-name backup)))
    backup))

(defun yt-cache--readable-p (db)
  "Return non-nil if this yt can use DB, written by a newer one.
That is when the newer schema says its min_reader is ours or older."
  (let ((min (ignore-errors
               (caar (sqlite-select db "SELECT value FROM meta WHERE key = 'min_reader'")))))
    (and (numberp min) (<= min yt-cache--schema-version))))

(defun yt-cache--open (file)
  "Open the cache database FILE, creating it with mode 0600 if needed."
  (unless (sqlite-available-p)
    (user-error "This Emacs was built without SQLite support, which yt needs"))
  (yt--ensure-private-directory (file-name-directory file))
  (unless (file-exists-p file)
    (with-file-modes #o600
      (write-region "" nil file nil 'silent)))
  (set-file-modes file #o600)
  (let ((db (sqlite-open file)))
    (condition-case err
        (progn
          (sqlite-pragma db "busy_timeout = 3000")
          (sqlite-pragma db "journal_mode = WAL")
          (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
            ;; A copy first, whenever an existing cache changes format.
            (when (< 0 version yt-cache--schema-version)
              (yt-cache--write-backup db file))
            (sqlite-execute db "BEGIN IMMEDIATE")
            (cond ((< version yt-cache--schema-version) (yt-cache--create-schema db))
                  ((and (> version yt-cache--schema-version)
                        (not (yt-cache--readable-p db)))
                   (user-error "The yt cache %s was written by a newer yt" file))))
          (sqlite-execute db "COMMIT")
          db)
      (error (ignore-errors (sqlite-execute db "ROLLBACK"))
             (sqlite-close db)
             (signal (car err) (cdr err))))))

(defun yt-cache-db ()
  "Return the cache database, opening it if needed."
  (or yt-cache--db
      (prog1 (setq yt-cache--db (yt-cache--open (yt-cache-file-name)))
        (add-hook 'kill-emacs-hook #'yt-cache-close 90))))

(defun yt-cache-close ()
  "Close the cache database."
  (when yt-cache--db
    (ignore-errors (sqlite-close yt-cache--db))
    (setq yt-cache--db nil)))

(defmacro yt-cache--with-transaction (db &rest body)
  "Run BODY in a write transaction on DB, rolling back on error."
  (declare (indent 1) (debug t))
  (let ((d (make-symbol "db")))
    `(let ((,d ,db))
       (sqlite-execute ,d "BEGIN IMMEDIATE")
       (condition-case err
           (prog1 (progn ,@body)
             (sqlite-execute ,d "COMMIT"))
         (t (ignore-errors (sqlite-execute ,d "ROLLBACK"))
            (signal (car err) (cdr err)))))))

;;;; Encoding videos

(defun yt-cache--encode (video)
  "Return the allowlisted fields of VIDEO as a JSON string."
  (let (plist)
    (pcase-dolist (`(,_ ,keyword ,offset) yt-cache--slots)
      (let ((value (aref video offset)))
        (when value
          (push keyword plist)
          (push (if (and (symbolp value) (not (eq value t)))
                    (symbol-name value)
                  value)
                plist))))
    (json-serialize (nreverse plist))))

(defun yt-cache--decode (data fetched-at watched position)
  "Return a `yt-video' from the JSON DATA and local state.
FETCHED-AT, WATCHED and POSITION come from the row's own columns."
  (let ((plist (json-parse-string data :object-type 'plist
                                  :null-object nil :false-object nil))
        (video (yt-video--make)))
    (pcase-dolist (`(,field ,keyword ,offset) yt-cache--slots)
      (let ((value (plist-get plist keyword)))
        (when (and value (memq field '(live-status timestamp-approx-p))
                   (stringp value))
          (setq value (intern value)))
        (aset video offset value)))
    (setf (yt-video-fetched-at video) fetched-at
          (yt-video-watched video) (and watched (/= watched 0))
          (yt-video-position video) position)
    video))

(defun yt-cache--timestamp-rank (video)
  "Return how trustworthy the timestamp of VIDEO is, from 0 to 3."
  (cond ((null (yt-video-timestamp video)) 0)
        ((eq (yt-video-timestamp-approx-p video) 'inherited) 1)
        ((yt-video-timestamp-approx-p video) 2)
        (t 3)))

(defun yt-cache--merge (old new)
  "Return NEW with the fields it lacks taken from the cached video OLD.
NEW's timestamp replaces OLD's only if it is more exact, since an
approximate time gets less precise the later it is fetched."
  (when (<= (yt-cache--timestamp-rank new) (yt-cache--timestamp-rank old))
    (setf (yt-video-timestamp new) (yt-video-timestamp old)
          (yt-video-timestamp-approx-p new) (yt-video-timestamp-approx-p old)))
  ;; The approximate flag belongs to the timestamp, decided above.
  (pcase-dolist (`(,field ,_ ,offset) yt-cache--slots)
    (unless (or (eq field 'timestamp-approx-p) (aref new offset))
      (aset new offset (aref old offset))))
  new)

;;;; Videos

(defun yt-cache-get (id)
  "Return the cached `yt-video' with ID, or nil."
  (when-let* ((row (car (sqlite-select
                         (yt-cache-db)
                         "SELECT data, fetched_at, watched, position FROM videos WHERE id = ?"
                         (list id)))))
    (apply #'yt-cache--decode row)))

(defun yt-cache--merge-cached (videos)
  "Return VIDEOS merged with their cached copies and local state."
  (mapcar (lambda (video)
            (if-let* ((old (yt-cache-get (yt-video-id video))))
                (let ((merged (yt-cache--merge old video)))
                  (setf (yt-video-fetched-at merged) (yt-video-fetched-at old)
                        (yt-video-watched merged) (yt-video-watched old)
                        (yt-video-position merged) (yt-video-position old))
                  merged)
              video))
          videos))

(defun yt-cache--write (db videos)
  "Write the fields of VIDEOS to DB, leaving their local state alone."
  (let ((now (truncate (yt--now))))
    (dolist (video videos)
      (unless (yt-video-fetched-at video)
        (setf (yt-video-fetched-at video) now))
      (sqlite-execute
       db "INSERT INTO videos (id, data, fetched_at) VALUES (?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET data = excluded.data"
       (list (yt-video-id video) (yt-cache--encode video)
             (yt-video-fetched-at video))))))

(defun yt-cache-put-videos (videos)
  "Store VIDEOS in the cache, keeping their watched state and position.
Fields a video lacks are kept from the cached copy; see
`yt-cache--merge'.  Return the merged videos."
  (let ((db (yt-cache-db)))
    (yt-cache--with-transaction db
      (let ((merged (yt-cache--merge-cached videos)))
        (yt-cache--write db merged)
        merged))))

(defun yt-cache--inherit-timestamps (videos)
  "Give each of VIDEOS without a timestamp the one of the video before it.
The first videos take the timestamp of the first video that has one.
Shorts carry no timestamp in the feed; without this, sorting by age
would put them all at one end.  Upcoming and live streams are left
alone, since a borrowed time would look like their start time."
  (let ((previous (seq-some #'yt-video-timestamp videos)))
    (dolist (video videos)
      (cond
       ((memq (yt-video-live-status video) '(is_upcoming is_live)))
       ((yt-video-timestamp video)
        (setq previous (yt-video-timestamp video)))
       (previous
        (setf (yt-video-timestamp video) previous
              (yt-video-timestamp-approx-p video) 'inherited))))))

;;;; Feeds

(defun yt-cache-feed (source &optional limit)
  "Return the cached videos of the feed SOURCE, a string, in feed order.
Return at most LIMIT videos, or `yt-cache-feed-max'."
  (let ((index -1))
    (mapcar (lambda (row)
              (let ((video (apply #'yt-cache--decode row)))
                (setf (yt-video-feed-index video) (cl-incf index))
                video))
            (sqlite-select
             (yt-cache-db)
             "SELECT v.data, v.fetched_at, v.watched, v.position
              FROM feed f JOIN videos v ON v.id = f.id
              WHERE f.source = ? ORDER BY f.pos LIMIT ?"
             (list source (or limit yt-cache-feed-max))))))

(defun yt-cache-put-feed (source videos &optional replace)
  "Merge the freshly fetched VIDEOS, in feed order, into the feed SOURCE.
The new order is VIDEOS followed by the previously cached videos that
are not among them, in their old order, up to `yt-cache-feed-max'.
With REPLACE non-nil, the feed becomes VIDEOS alone, as for a
playlist, which was fetched whole.
Videos without a timestamp inherit one; see
`yt-cache--inherit-timestamps'.  Return the merged feed, as
`yt-cache-feed' would."
  (let ((db (yt-cache-db))
        (ids (make-hash-table :test #'equal)))
    (dolist (video videos)
      (puthash (yt-video-id video) t ids))
    (yt-cache--with-transaction db
      (let* ((merged (yt-cache--merge-cached videos))
             (feed (seq-take
                    (append merged
                            (unless replace
                              (seq-remove (lambda (v) (gethash (yt-video-id v) ids))
                                          (yt-cache-feed source))))
                    yt-cache-feed-max))
             (pos -1))
        ;; Inherit after merging, so that only videos the cache has no
        ;; time for borrow one from their neighbour.
        (yt-cache--inherit-timestamps merged)
        (yt-cache--write db merged)
        (sqlite-execute db "DELETE FROM feed WHERE source = ?" (list source))
        (dolist (video feed)
          (setf (yt-video-feed-index video) (cl-incf pos))
          (sqlite-execute db "INSERT INTO feed (source, id, pos) VALUES (?, ?, ?)"
                          (list source (yt-video-id video) pos)))
        feed))))

;;;; Channels

(defconst yt-cache--channel-fields '(:id :name :url :followers)
  "The channel properties stored in the cache.")

(defun yt-cache-channels ()
  "Return the cached subscribed channels, as plists, in their order.
Each has :id, :name, :url and :followers; see `yt-cache-put-channels'."
  (mapcar (lambda (row)
            (json-parse-string (car row) :object-type 'plist
                               :null-object nil :false-object nil))
          (sqlite-select (yt-cache-db) "SELECT data FROM channels ORDER BY pos")))

(defun yt-cache-put-channels (channels)
  "Replace the cached subscribed channels with CHANNELS, a list of plists.
Only the properties in `yt-cache--channel-fields' are stored."
  (let ((db (yt-cache-db))
        (pos -1))
    (yt-cache--with-transaction db
      (sqlite-execute db "DELETE FROM channels")
      (dolist (channel channels)
        (sqlite-execute
         db "INSERT OR REPLACE INTO channels (id, pos, data) VALUES (?, ?, ?)"
         (list (plist-get channel :id) (cl-incf pos)
               (json-serialize
                (yt-cache--prune-plist
                 (cl-loop for key in yt-cache--channel-fields
                          append (list key (plist-get channel key)))))))))
    channels))

(defun yt-cache-subscribed-p (id)
  "Return non-nil if the channel ID is among the cached subscribed channels."
  (and (sqlite-select (yt-cache-db) "SELECT 1 FROM channels WHERE id = ?" (list id))
       t))

(defun yt-cache-add-channel (channel)
  "Add CHANNEL, a plist, first among the cached subscribed channels.
Then run `yt-subscriptions-changed-functions'."
  (let ((id (plist-get channel :id)))
    (yt-cache-put-channels
     (cons channel (seq-remove (lambda (c) (equal (plist-get c :id) id))
                               (yt-cache-channels)))))
  (run-hook-with-args 'yt-subscriptions-changed-functions channel t))

(defun yt-cache-remove-channel (channel)
  "Remove CHANNEL, a plist, from the cached subscribed channels.
Its videos leave the cached subscription feed too.  Then run
`yt-subscriptions-changed-functions'."
  (let ((db (yt-cache-db))
        (id (plist-get channel :id)))
    (yt-cache--with-transaction db
      (sqlite-execute db "DELETE FROM channels WHERE id = ?" (list id))
      (dolist (video (yt-cache-feed "subscriptions"))
        (when (equal (yt-video-channel-id video) id)
          (sqlite-execute db "DELETE FROM feed WHERE source = ? AND id = ?"
                          (list "subscriptions" (yt-video-id video)))))))
  (run-hook-with-args 'yt-subscriptions-changed-functions channel nil))

(defun yt-cache--prune-plist (plist)
  "Return PLIST without the properties whose value is nil."
  (cl-loop for (key value) on plist by #'cddr
           when value append (list key value)))

;;;; Saved playlists

(defconst yt-cache--playlist-fields '(:id :title :channel :channel-id :url)
  "The playlist properties stored in the cache.")

(defun yt-cache-saved-playlists ()
  "Return the saved playlists, as plists, the most recently saved first.
Each has :id, :title, :channel, :channel-id and :url."
  (mapcar (lambda (row)
            (json-parse-string (car row) :object-type 'plist
                               :null-object nil :false-object nil))
          (sqlite-select (yt-cache-db)
                         "SELECT data FROM playlists ORDER BY saved_at DESC, rowid DESC")))

(defun yt-cache-playlist-saved-p (id)
  "Return non-nil if the playlist ID is saved."
  (and (sqlite-select (yt-cache-db) "SELECT 1 FROM playlists WHERE id = ?" (list id)) t))

(defun yt-cache-save-playlist (playlist)
  "Save PLAYLIST, a plist with at least :id; see `yt-cache-saved-playlists'."
  (sqlite-execute
   (yt-cache-db)
   "INSERT INTO playlists (id, saved_at, data) VALUES (?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET data = excluded.data"
   (list (plist-get playlist :id) (truncate (yt--now))
         (json-serialize
          (yt-cache--prune-plist
           (cl-loop for key in yt-cache--playlist-fields
                    append (list key (plist-get playlist key)))))))
  playlist)

(defun yt-cache-forget-playlist (id)
  "Remove the playlist ID from the saved playlists."
  (sqlite-execute (yt-cache-db) "DELETE FROM playlists WHERE id = ?" (list id)))

;;;; Local state

(defun yt-cache-meta (key)
  "Return the value stored for the string KEY, or nil."
  (caar (sqlite-select (yt-cache-db) "SELECT value FROM meta WHERE key = ?"
                       (list key))))

(defun yt-cache-set-meta (key value)
  "Store VALUE, a number or string, for the string KEY."
  (sqlite-execute (yt-cache-db)
                  "INSERT INTO meta (key, value) VALUES (?, ?)
                   ON CONFLICT (key) DO UPDATE SET value = excluded.value"
                  (list key value))
  value)

(defun yt-cache-set-position (id position)
  "Remember POSITION, in seconds or nil, as the resume position of ID.
Then run `yt-history-changed-hook', since the history shows it."
  (sqlite-execute (yt-cache-db) "UPDATE videos SET position = ? WHERE id = ?"
                  (list position id))
  (run-hooks 'yt-history-changed-hook))

(defun yt-cache--id (video-or-id)
  "Return the id of VIDEO-OR-ID, a `yt-video' or an id string."
  (if (yt-video-p video-or-id) (yt-video-id video-or-id) video-or-id))

(defun yt-mark-watched (videos &optional unwatched)
  "Mark VIDEOS as watched, or as not watched if UNWATCHED is non-nil.
VIDEOS is a `yt-video', an id, or a list of them.  Videos not in the
cache yet are added with only their id.  Run
`yt-watched-changed-functions' afterwards."
  (let ((db (yt-cache-db))
        (ids (mapcar #'yt-cache--id (if (listp videos) videos (list videos))))
        (now (truncate (yt--now))))
    (yt-cache--with-transaction db
      (dolist (id ids)
        (sqlite-execute
         db "INSERT INTO videos (id, data, fetched_at, watched) VALUES (?, ?, ?, ?)
             ON CONFLICT (id) DO UPDATE SET watched = excluded.watched"
         (list id (json-serialize (list :id id)) now (if unwatched 0 1)))))
    (run-hook-with-args 'yt-watched-changed-functions ids (not unwatched))
    ids))

;;;; Played videos

(defun yt-cache-add-history (video)
  "Note that VIDEO started to play now, and run `yt-history-changed-hook'.
VIDEO is cached too, if it is not yet."
  (when-let* ((id (yt-video-id video)))
    (unless (yt-cache-get id)
      (yt-cache-put-videos (list video)))
    (sqlite-execute (yt-cache-db)
                    "INSERT OR REPLACE INTO history (id, played_at) VALUES (?, ?)"
                    (list id (truncate (yt--now))))
    (run-hooks 'yt-history-changed-hook)))

(defun yt-cache-history (&optional limit)
  "Return the videos you played, the most recent first, at most LIMIT.
Each element is (VIDEO . PLAYED-AT), PLAYED-AT in seconds since the epoch."
  (mapcar (lambda (row)
            (cons (apply #'yt-cache--decode (butlast row)) (car (last row))))
          (sqlite-select
           (yt-cache-db)
           "SELECT v.data, v.fetched_at, v.watched, v.position, h.played_at
            FROM history h JOIN videos v ON v.id = h.id
            ORDER BY h.played_at DESC, h.rowid DESC LIMIT ?"
           (list (or limit yt-cache-feed-max)))))

(defun yt-cache-remove-history (ids)
  "Remove the videos with IDS from the played videos."
  (let ((db (yt-cache-db)))
    (yt-cache--with-transaction db
      (dolist (id ids)
        (sqlite-execute db "DELETE FROM history WHERE id = ?" (list id)))))
  (run-hooks 'yt-history-changed-hook))

(defun yt-cache-clear-history ()
  "Forget every played video, but not what was watched or where you stopped."
  (sqlite-execute (yt-cache-db) "DELETE FROM history")
  (run-hooks 'yt-history-changed-hook))

;;;###autoload
(defun yt-forget-history ()
  "Forget the videos you played and watched, and where you stopped."
  (interactive)
  (when (yes-or-no-p "Forget the played videos, watched marks and resume positions? ")
    (let ((ids (mapcar #'car (sqlite-select (yt-cache-db)
                                            "SELECT id FROM videos WHERE watched <> 0"))))
      (sqlite-execute (yt-cache-db) "UPDATE videos SET watched = 0, position = NULL")
      (yt-cache-clear-history)
      (when ids
        (run-hook-with-args 'yt-watched-changed-functions ids nil))
      (message "Forgot the watch history of %d videos" (length ids)))))

(provide 'yt-cache)
;;; yt-cache.el ends here
