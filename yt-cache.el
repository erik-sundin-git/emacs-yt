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

(defvar yt-cache--db nil
  "The open cache database, or nil.")

(defconst yt-cache--schema-version 1
  "Version of the cache schema, stored as SQLite's user_version.")

(defconst yt-cache--fields
  '(id title channel channel-id channel-url duration timestamp
       timestamp-approx-p views live-status thumbnail url short-p)
  "The `yt-video' slots stored in the cache.
Local state (watched, position, fetched-at) has its own columns,
and the feed index its own table.")

(defun yt-cache-file-name ()
  "Return the name of the cache database file, see `yt-cache-file'."
  (or yt-cache-file (expand-file-name "yt.sqlite" yt-state-directory)))

;;;; Opening

(defun yt-cache--create-schema (db)
  "Create the tables in the empty database DB."
  (dolist (sql '("CREATE TABLE IF NOT EXISTS videos (
                   id TEXT PRIMARY KEY, data TEXT NOT NULL,
                   fetched_at INTEGER, watched INTEGER NOT NULL DEFAULT 0,
                   position REAL)"
                 "CREATE TABLE IF NOT EXISTS feed (
                   source TEXT NOT NULL, id TEXT NOT NULL, pos INTEGER NOT NULL,
                   PRIMARY KEY (source, id))"
                 "CREATE INDEX IF NOT EXISTS feed_order ON feed (source, pos)"
                 "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value)"))
    (sqlite-execute db sql))
  (sqlite-execute db (format "PRAGMA user_version = %d" yt-cache--schema-version)))

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
          (sqlite-execute db "BEGIN IMMEDIATE")
          (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
            (cond ((eql version 0) (yt-cache--create-schema db))
                  ((> version yt-cache--schema-version)
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
    (dolist (field yt-cache--fields)
      (let ((value (cl-struct-slot-value 'yt-video field video)))
        (when value
          (push (intern (format ":%s" field)) plist)
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
    (dolist (field yt-cache--fields)
      (let ((value (plist-get plist (intern (format ":%s" field)))))
        (when (and value (memq field '(live-status timestamp-approx-p))
                   (stringp value))
          (setq value (intern value)))
        (setf (cl-struct-slot-value 'yt-video field video) value)))
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
  (dolist (field yt-cache--fields)
    (unless (cl-struct-slot-value 'yt-video field new)
      (setf (cl-struct-slot-value 'yt-video field new)
            (cl-struct-slot-value 'yt-video field old))))
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

(defun yt-cache-put-feed (source videos)
  "Merge the freshly fetched VIDEOS, in feed order, into the feed SOURCE.
The new order is VIDEOS followed by the previously cached videos that
are not among them, in their old order, up to `yt-cache-feed-max'.
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
                            (seq-remove (lambda (v) (gethash (yt-video-id v) ids))
                                        (yt-cache-feed source)))
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
  "Remember POSITION, in seconds or nil, as the resume position of ID."
  (sqlite-execute (yt-cache-db) "UPDATE videos SET position = ? WHERE id = ?"
                  (list position id)))

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

;;;###autoload
(defun yt-forget-history ()
  "Forget which videos you watched and where you stopped."
  (interactive)
  (when (yes-or-no-p "Forget all watched marks and resume positions? ")
    (let ((ids (mapcar #'car (sqlite-select (yt-cache-db)
                                            "SELECT id FROM videos WHERE watched <> 0"))))
      (sqlite-execute (yt-cache-db) "UPDATE videos SET watched = 0, position = NULL")
      (when ids
        (run-hook-with-args 'yt-watched-changed-functions ids nil))
      (message "Forgot the watch history of %d videos" (length ids)))))

(provide 'yt-cache)
;;; yt-cache.el ends here
