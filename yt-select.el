;;; yt-select.el --- Choose a video with completion -*- lexical-binding: t; -*-

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

;; `yt-select-video' reads a video with `completing-read', offering the
;; videos of the feed buffer at hand or of the cached subscription
;; feed.  Candidates have the completion category `yt-video' and are
;; annotated with their channel, age and duration.
;;
;; With marginalia, the same annotations are registered for the
;; category.  With embark, `yt-embark-video-map' offers every key of
;; `yt-video-actions-map' on a candidate (and on the video at point in
;; yt buffers): each action runs the same command, with the candidate
;; as the video at point.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'yt)
(require 'yt-video)
(require 'yt-cache)
(require 'yt-player)
(require 'yt-feed)
(require 'yt-info)
(require 'yt-playlists)

(defcustom yt-select-group-by-channel nil
  "Non-nil means `yt-select-video' groups the videos by channel."
  :type 'boolean
  :group 'yt-feed
  :package-version '(yt . "0.1.0"))

(defvar yt-select--videos (make-hash-table :test #'equal)
  "The videos of the candidates made last, by candidate string.
Completion frameworks may drop text properties, so candidates are
also looked up here.")

(defvar yt-select-history nil
  "History of `yt-select-video'.")

;;;; Candidates

(defun yt-select-candidate (video)
  "Return the completion candidate for VIDEO, a string.
It is the title, followed by the video id if another video already
has that title.  The video is in the text property `yt-video'."
  (let* ((title (or (yt-video-title video) (yt-video-id video)))
         (other (gethash title yt-select--videos))
         (candidate (if (and other (not (equal (yt-video-id other) (yt-video-id video))))
                        (format "%s (%s)" title (yt-video-id video))
                      title)))
    (puthash candidate video yt-select--videos)
    (propertize candidate 'yt-video video)))

(defun yt-select-candidate-video (candidate)
  "Return the `yt-video' of the completion CANDIDATE, or nil."
  (and (stringp candidate)
       (or (get-text-property 0 'yt-video candidate)
           (gethash (substring-no-properties candidate) yt-select--videos))))

(defun yt-select-annotate (candidate)
  "Return the annotation of CANDIDATE: its channel, age and duration."
  (when-let* ((video (yt-select-candidate-video candidate)))
    (concat "  "
            (propertize (truncate-string-to-width (or (yt-video-channel video) "") 20
                                                  nil ?\s "…")
                        'face 'yt-feed-channel)
            "  "
            (propertize (string-pad (yt-video-format-age (yt-video-timestamp video)) 5 nil t)
                        'face 'yt-feed-age)
            "  "
            (propertize (pcase (yt-video-live-status video)
                          ('is_live "LIVE")
                          ('is_upcoming "SOON")
                          (_ (yt-video-format-duration (yt-video-duration video))))
                        'face 'yt-feed-duration)
            (if (yt-video-watched video) (propertize "  watched" 'face 'shadow) ""))))

(defun yt-select--group (candidate transform)
  "Group CANDIDATE by its channel; with TRANSFORM, return CANDIDATE."
  (if transform
      candidate
    (or (yt-video-channel (yt-select-candidate-video candidate)) "Unknown channel")))

(defun yt-select--default-videos ()
  "Return the videos to choose from: the feed at hand, or the subscriptions."
  (or (and (derived-mode-p 'yt-feed-mode) (bound-and-true-p yt-feed--videos))
      (yt-cache-feed "subscriptions")))

(defun yt-select-video (&optional prompt videos)
  "Read one of VIDEOS with completion, showing PROMPT, and return it.
VIDEOS default to those of the current feed buffer, or of the cached
subscription feed."
  (let* ((videos (or videos (yt-select--default-videos)
                     (user-error "No videos to choose from: open the feed with M-x yt")))
         (candidates (progn (clrhash yt-select--videos)
                            (mapcar #'yt-select-candidate videos)))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (category . yt-video)
                                 (annotation-function . yt-select-annotate)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity)
                                 ,@(and yt-select-group-by-channel
                                        '((group-function . yt-select--group))))
                    (complete-with-action action candidates string predicate))))
         (choice (completing-read (or prompt "Video: ") table nil t nil 'yt-select-history)))
    (or (yt-select-candidate-video choice)
        (user-error "No such video: %s" choice))))

;;;###autoload
(defun yt-select-play (video)
  "Choose a VIDEO of the feed with completion and play it."
  (interactive (list (yt-select-video "Play video: ")))
  (yt-play video))

;;;; embark and marginalia

(defun yt-select--action-name (command)
  "Return the name of the embark action running COMMAND."
  (intern (format "yt-select-act-%s" (string-remove-prefix "yt-" (symbol-name command)))))

(defun yt-select--define-action (command)
  "Define the embark action for COMMAND, and return its name.
The action is a function of one argument, the candidate, since
`embark' calls such functions with the target.  It calls COMMAND
interactively with the candidate's video as the video at point."
  (let ((name (yt-select--action-name command)))
    (defalias name
      (lambda (candidate)
        (let* ((video (or (yt-select-candidate-video candidate)
                          (yt-video-from-url candidate)
                          (user-error "Not a yt video: %s" candidate)))
               (yt-video-at-point-function (lambda () video)))
          (deactivate-mark)
          (call-interactively command)))
      (format "Run `%s' on the video of an embark CANDIDATE." command))
    name))

(defun yt-select--embark-map ()
  "Return a keymap of embark actions for the keys of `yt-video-actions-map'."
  (let ((map (make-sparse-keymap)))
    (map-keymap (lambda (key binding)
                  (when (and (symbolp binding) (commandp binding))
                    (define-key map (vector key) (yt-select--define-action binding))))
                yt-video-actions-map)
    map))

(defvar yt-embark-video-map (yt-select--embark-map)
  "Keymap of embark actions on yt videos.
It holds the keys of `yt-video-actions-map'; when embark is loaded,
its general actions are added as a parent.")

(defun yt-select-embark-target ()
  "Return the video at point as an embark target, or nil."
  (when-let* ((video (yt-video-at-point)))
    (cons 'yt-video (yt-select-candidate video))))

(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar embark-general-map)
(defvar marginalia-annotators)
(defvar marginalia-annotator-registry)

(defun yt-select--setup-embark ()
  "Register yt's actions and target finder with embark."
  (set-keymap-parent yt-embark-video-map embark-general-map)
  (add-to-list 'embark-keymap-alist '(yt-video . yt-embark-video-map))
  (add-to-list 'embark-target-finders #'yt-select-embark-target))

(defun yt-select--marginalia-registry ()
  "Return the name of marginalia's annotator registry.
It was renamed from `marginalia-annotator-registry' to
`marginalia-annotators'."
  (if (boundp 'marginalia-annotators)
      'marginalia-annotators
    'marginalia-annotator-registry))

(defun yt-select--setup-marginalia ()
  "Register yt's annotations with marginalia."
  (add-to-list (yt-select--marginalia-registry)
               '(yt-video yt-select-annotate builtin none)))

(defun yt-select--setup-integrations (&rest _)
  "Register with embark and marginalia once they are loaded.
This runs from `after-load-functions', so the order in which yt,
embark and marginalia are loaded does not matter."
  (when (and (featurep 'embark)
             (not (assq 'yt-video embark-keymap-alist)))
    (yt-select--setup-embark))
  (when (and (featurep 'marginalia)
             (not (assq 'yt-video (symbol-value (yt-select--marginalia-registry)))))
    (yt-select--setup-marginalia)))

(yt-select--setup-integrations)
(add-hook 'after-load-functions #'yt-select--setup-integrations)

(provide 'yt-select)
;;; yt-select.el ends here
