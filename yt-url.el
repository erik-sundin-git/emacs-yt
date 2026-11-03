;;; yt-url.el --- Open YouTube links in yt -*- lexical-binding: t; -*-

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

;; `yt-url-handler-mode' makes `browse-url' open YouTube links in yt:
;; a video plays in mpv (from its t= time, if the link has one), and a
;; playlist or a channel opens in a yt buffer.  So do links clicked in
;; mail, org or help buffers; eww hands only the links that match
;; `eww-use-browse-url' to `browse-url'.  With a prefix argument, or
;; when yt cannot open a link, it goes to the browser as before.
;;
;; Links come from untrusted text, so `yt-url-parse' accepts only the
;; YouTube hosts, with no user name or port, and yt rebuilds a canonical
;; URL from the validated id; the link itself is never handed to yt-dlp,
;; and tracking parameters such as si= are dropped.

;;; Code:

(require 'cl-lib)
(require 'url-parse)
(require 'url-util)
(require 'seq)
(require 'yt)
(require 'yt-video)

(declare-function yt-play "yt-player" (video &optional backend from-start))
(declare-function yt-play-at "yt-player" (video start &optional backend))
(declare-function yt-feed-channel "yt-feed" (id url name))
(declare-function yt-feed-playlist "yt-feed" (id url title))
(declare-function yt-cache-get "yt-cache" (id))
(declare-function yt-cache-channels "yt-cache" ())
(defvar browse-url-handlers)

(defconst yt-url-hosts
  '("youtube.com" "www.youtube.com" "m.youtube.com" "music.youtube.com"
    "youtu.be" "youtube-nocookie.com" "www.youtube-nocookie.com")
  "The hosts of the links yt opens.")

(defconst yt-url--max-start (* 48 3600)
  "The latest start time accepted from a link, in seconds.")

(defun yt-url-parse-time (string)
  "Return the seconds of a t= value STRING such as 90, 90s or 1h2m3s, or nil."
  (when (and (stringp string)
             (string-match "\\`\\(?:\\([0-9]+\\)h\\)?\\(?:\\([0-9]+\\)m\\)?\\(?:\\([0-9]+\\)s?\\)?\\'"
                           string)
             (not (string-empty-p string)))
    (let ((seconds (+ (* 3600 (string-to-number (or (match-string 1 string) "0")))
                      (* 60 (string-to-number (or (match-string 2 string) "0")))
                      (string-to-number (or (match-string 3 string) "0")))))
      (and (<= seconds yt-url--max-start) seconds))))

(defun yt-url--query (url)
  "Return the query parameters of the parsed URL as an alist of strings."
  (let ((query (cdr (url-path-and-query url))))
    (and query
         (mapcar (lambda (pair) (cons (car pair) (cadr pair)))
                 (url-parse-query-string query)))))

(defun yt-url-parse (string)
  "Return what the YouTube link STRING points to, or nil if it is none.
The result is (video :id ID :url URL :start SECONDS-OR-NIL),
\(playlist :id ID :url URL) or (channel :id ID-OR-NIL :url URL), with
URL rebuilt from the validated parts."
  (let ((url (ignore-errors (url-generic-parse-url (string-trim string)))))
    (when (and url
               (member (url-type url) '("http" "https"))
               (member (downcase (or (url-host url) "")) yt-url-hosts)
               (not (url-user url)) (not (url-password url))
               (memq (url-portspec url) '(nil 80 443)))
      (let* ((host (downcase (url-host url)))
             (path (or (car (url-path-and-query url)) "/"))
             (query (yt-url--query url))
             (start (yt-url-parse-time (or (cdr (assoc "t" query))
                                           (cdr (assoc "start" query))))))
        (cl-flet ((video (id)
                    (and (string-match-p "\\`[A-Za-z0-9_-]\\{11\\}\\'" id)
                         (list 'video :id id
                               :url (concat "https://www.youtube.com/watch?v=" id)
                               :start start))))
          (cond
           ((equal host "youtu.be")
            (and (string-match "\\`/\\([^/]+\\)/?\\'" path)
                 (video (match-string 1 path))))
           ((equal path "/watch")
            (when-let* ((id (cdr (assoc "v" query))))
              (video id)))
           ((string-match "\\`/\\(?:shorts\\|live\\|embed\\)/\\([^/]+\\)/?\\'" path)
            (video (match-string 1 path)))
           ((equal path "/playlist")
            (when-let* ((id (cdr (assoc "list" query)))
                        ((string-match-p "\\`[A-Za-z0-9_-]+\\'" id)))
              (list 'playlist :id id
                    :url (concat "https://www.youtube.com/playlist?list=" id))))
           ((string-match "\\`/channel/\\(UC[A-Za-z0-9_-]\\{22\\}\\)\\(?:/.*\\)?\\'" path)
            (let ((id (match-string 1 path)))
              (list 'channel :id id :url (concat "https://www.youtube.com/channel/" id))))
           ((string-match "\\`/\\(@[A-Za-z0-9._-]+\\)\\(?:/.*\\)?\\'" path)
            (list 'channel :id nil
                  :url (concat "https://www.youtube.com/" (match-string 1 path))))))))))

(defun yt-url-open (string)
  "Open the YouTube link STRING in yt; return nil if it is not one."
  (pcase (yt-url-parse string)
    (`(video :id ,id :url ,url :start ,start)
     (require 'yt-player)
     (let ((video (or (and (fboundp 'yt-cache-get) (yt-cache-get id))
                      (yt-video-from-url url))))
       (if start (yt-play-at video start) (yt-play video)))
     t)
    (`(playlist :id ,id :url ,url)
     (require 'yt-feed)
     (yt-feed-playlist id url (format "Playlist %s" id))
     t)
    (`(channel :id ,id :url ,url)
     (require 'yt-feed)
     (let ((known (seq-find (lambda (channel)
                              (or (equal (plist-get channel :id) id)
                                  (equal (plist-get channel :url) url)))
                            (yt-cache-channels))))
       (yt-feed-channel (or id (plist-get known :id) url) url
                        (or (plist-get known :name)
                            id (substring url (length "https://www.youtube.com/")))))
     t)))

;;;; browse-url

(defvar yt-url--bypass nil
  "Non-nil while yt opens a link in the browser itself.")

(defun yt-url-handler-p (url)
  "Return non-nil if yt should open URL, for `browse-url-handlers'."
  (and (not yt-url--bypass) (not current-prefix-arg) (yt-url-parse url) t))

(defun yt-url-browse (url &rest args)
  "Open URL in yt, or with the browser if yt cannot.
ARGS are passed on to `browse-url'."
  (unless (condition-case err
              (yt-url-open url)
            (error (message "yt could not open the link: %s" (error-message-string err))
                   nil))
    (apply #'yt-url-browse-externally url args)))

(function-put 'yt-url-browse 'browse-url-browser-kind 'external)

(defun yt-url-browse-externally (url &rest args)
  "Open URL with `browse-url', but not in yt, passing ARGS on."
  (let ((yt-url--bypass t))
    (apply #'browse-url url args)))

(defun yt-browse-url (url)
  "Open the YouTube page URL in a web browser, never in yt.
yt's own \"open in browser\" commands use this; it refuses anything but
a YouTube link, since URLs in the cache came from the network."
  (unless (yt-url-parse url)
    (user-error "Not a YouTube link: %s" url))
  (yt-url-browse-externally url))

;;;###autoload
(define-minor-mode yt-url-handler-mode
  "Open YouTube links in yt instead of the browser.
Videos play in mpv, from their t= time if they have one; playlists
and channels open in yt buffers.  With a prefix argument, a link
opens in the browser as before."
  :global t
  :group 'yt
  :package-version '(yt . "0.2.0")
  (require 'browse-url)
  (setq browse-url-handlers
        (cl-remove #'yt-url-browse browse-url-handlers :key #'cdr))
  (when yt-url-handler-mode
    (push (cons #'yt-url-handler-p #'yt-url-browse) browse-url-handlers)))

(provide 'yt-url)
;;; yt-url.el ends here
