;;; yt-list.el --- Shared parts of the yt list buffers -*- lexical-binding: t; -*-

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

;; What the yt list buffers (feed, channels, playlists, history, the
;; queue) share:
;;
;; - The faces of their columns.
;; - `yt-list-mode', the base of the channels, playlists and history
;;   lists: a header line and an empty-list message built from parts,
;;   a filter in the feed's syntax (words, @channel, !exclude), and the
;;   state of a fetch in progress.
;; - Columns that fit the window: the Title column takes the width the
;;   other columns leave, so that age and duration stay visible in a
;;   narrow window and long titles use a wide one.
;; - Loading the embark and marginalia integrations of yt-select.el as
;;   soon as either package is loaded, so that embark acts on the rows
;;   of every yt buffer without yt-select having been used first.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'yt)
(require 'yt-video)

(declare-function yt-login "yt-auth" (&optional choose))

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

(defface yt-feed-arrived-marker '((t :inherit warning))
  "Face for the marker of a video that arrived since your last visit."
  :group 'yt-feed
  :package-version '(yt . "0.3.0"))


;;;; Columns that fit the window

(defvar yt-list-title-width-range '(20 . 150)
  "The narrowest and widest the Title column gets, in characters.")

(defvar-local yt-list--base-format nil
  "This buffer's columns at their nominal widths, or nil.
`yt-list-fit-columns' fits them to the window.")

(defvar-local yt-list-reprint-function nil
  "Function that prints this buffer again, after its columns or filter changed.
nil means `yt-list-print'.")

(defvar-local yt-list--fit-timer nil
  "Timer that fits this buffer's columns to its window, or nil.")

(defun yt-list-column-widths (format width)
  "Return FORMAT, a `tabulated-list-format', fitted to WIDTH characters.
The Title column gets what the others leave, within
`yt-list-title-width-range'; in a narrow window the Channel column
shrinks first, down to 12.  FORMAT is not modified.  Without a Title
column, or with WIDTH nil, return FORMAT."
  (let* ((columns (mapcar #'copy-sequence (append format nil)))
         (title (cl-position "Title" columns :key #'car :test #'equal)))
    (if (not (and title width))
        format
      (let* ((channel (cl-position "Channel" columns :key #'car :test #'equal))
             (others (- (apply #'+ (mapcar #'cadr columns)) (nth 1 (nth title columns))))
             ;; One space between columns, and one spare at the end.
             (free (- width others (length columns))))
        (when (and channel (< free (car yt-list-title-width-range)))
          (let* ((column (nth channel columns))
                 (shrink (max 0 (min (- (nth 1 column) 12)
                                     (- (car yt-list-title-width-range) free)))))
            (setf (nth 1 column) (- (nth 1 column) shrink))
            (cl-incf free shrink)))
        (setf (nth 1 (nth title columns))
              (max (car yt-list-title-width-range)
                   (min (cdr yt-list-title-width-range) free)))
        (vconcat columns)))))

(defun yt-list--window-width ()
  "Return the width of the window showing this buffer, or nil.
The selected window wins when several show it."
  (when-let* ((window (if (eq (window-buffer) (current-buffer))
                          (selected-window)
                        (get-buffer-window nil t))))
    (window-max-chars-per-line window)))

(defun yt-list-fit-columns (format)
  "Make FORMAT this buffer's columns, fitted to its window.
They are fitted again whenever the window changes size."
  (setq yt-list--base-format format
        tabulated-list-format (yt-list-column-widths format (yt-list--window-width)))
  (add-hook 'window-size-change-functions #'yt-list--refit-soon nil t)
  (add-hook 'window-buffer-change-functions #'yt-list--refit-soon nil t)
  (tabulated-list-init-header))

(defun yt-list--refit-soon (&optional window)
  "Fit the columns of WINDOW's buffer, or this buffer's, to its window shortly."
  (with-current-buffer (if (windowp window) (window-buffer window) (current-buffer))
    (unless (timerp yt-list--fit-timer)
      (setq yt-list--fit-timer
            (run-with-timer 0.1 nil #'yt-list--refit (current-buffer))))))

(defun yt-list--refit (buffer)
  "Fit the columns of BUFFER to its window, and print it again if they changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq yt-list--fit-timer nil)
      (when yt-list--base-format
        (let ((format (yt-list-column-widths yt-list--base-format
                                             (yt-list--window-width))))
          (unless (equal format tabulated-list-format)
            (setq tabulated-list-format format)
            (tabulated-list-init-header)
            (yt-list-reprint)))))))

;;;; The base mode of the lists

(defvar-local yt-list--query nil
  "The filter of this list, a string, or nil.")

(defvar-local yt-list--refreshing nil
  "Non-nil while this list is being fetched.")

(defvar-local yt-list--error nil
  "The message of this list's last failed fetch, or nil.")

(defvar-local yt-list-header-function nil
  "Function returning the parts of this list's header line, in order.
Parts that are nil are left out.")

(defvar-local yt-list-empty-function nil
  "Function returning what an empty list says, or nil.")

(defun yt-list-count (n thing)
  "Return N followed by THING, in the plural unless N is 1."
  (format "%d %s%s" n thing (if (= n 1) "" "s")))

(defun yt-list-ago (time)
  "Return how long ago TIME was, for a header line."
  (let ((age (yt-video-format-age time)))
    (if (equal age "now") "just now" (concat age " ago"))))

(defun yt-list-parse-query (query)
  "Return the terms of the filter QUERY, a string, or nil.
Terms are separated by spaces and all must match.  A term matches
the title or channel; \"@term\" matches only the channel, and
\"!term\" matches what lacks it in both.  Each term is returned as
\(KIND . TEXT), KIND being `any', `channel' or `not', with TEXT in
lower case."
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

(defun yt-list-match-p (terms title channel)
  "Return non-nil if TITLE and CHANNEL, in lower case, pass the TERMS.
TERMS come from `yt-list-parse-query'."
  (seq-every-p (lambda (term)
                 (let ((text (cdr term)))
                   (pcase (car term)
                     ('channel (string-search text channel))
                     ('not (not (or (string-search text title)
                                    (string-search text channel))))
                     (_ (or (string-search text title)
                            (string-search text channel))))))
               terms))

(defun yt-list-query-terms ()
  "Return the terms of this list's filter."
  (yt-list-parse-query yt-list--query))

(defun yt-list-header-line ()
  "Return this list's header line, from `yt-list-header-function'.
The state of a fetch and the filter come first."
  (concat " "
          (string-join
           (delq nil (append (list (and yt-list--refreshing "Fetching…")
                                   (and yt-list--error
                                        (propertize yt-list--error 'face 'warning))
                                   (and yt-list--query
                                        (format "filter “%s”" yt-list--query)))
                             (and yt-list-header-function
                                  (funcall yt-list-header-function))))
           "  ·  ")))

(defun yt-list--rows-p ()
  "Return non-nil if this list shows a row."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (setq found (tabulated-list-get-id))
        (forward-line 1))
      found)))

(defun yt-list-print ()
  "Print this list again, keeping point, and explain it if empty."
  (tabulated-list-print t)
  (unless (or yt-list--refreshing (yt-list--rows-p))
    (when-let* ((message (cond (yt-list--error)
                               (yt-list--query
                                (substitute-command-keys
                                 (format "Nothing matches the filter “%s”.  \\[yt-list-filter] changes it."
                                         yt-list--query)))
                               (yt-list-empty-function (funcall yt-list-empty-function)))))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert "\n  " message "\n")))))
  (force-mode-line-update))

(defun yt-list-reprint ()
  "Print this buffer again, with `yt-list-reprint-function' if it has one."
  (if yt-list-reprint-function
      (funcall yt-list-reprint-function)
    (yt-list-print)))

(defun yt-list-filter (query)
  "Show only the rows that match QUERY; an empty QUERY shows them all.
Words must all be in the title or the channel; @word matches only the
channel, and !word excludes."
  (interactive (list (read-string "Filter (words, @channel, !exclude): " yt-list--query
                                  (yt-minibuffer-history 'yt-filter-history)))
               yt-list-mode)
  (setq yt-list--query (and (not (string-blank-p query)) query))
  (yt-list-reprint))

(defun yt-list-clear-filter ()
  "Show every row again."
  (interactive nil yt-list-mode)
  (yt-list-filter ""))

(defun yt-list-filter-with-s ()
  "Filter, as \\`/' does.  \\`s' will stop filtering in yt 0.4."
  (interactive)
  (message "s will stop filtering in yt 0.4; use /")
  (call-interactively (keymap-lookup nil "/")))

(defvar-keymap yt-list-mode-map
  :doc "Keymap shared by the yt lists derived from `yt-list-mode'.
\\`j' is `yt-map' and \\`P' the player keys, as in every yt buffer."
  :parent tabulated-list-mode-map
  "/" #'yt-list-filter
  "s" #'yt-list-filter-with-s
  "C" #'yt-list-clear-filter
  "g" #'revert-buffer
  "j" yt-map
  "P" yt-player-map
  "L" #'yt-login)

(define-derived-mode yt-list-mode tabulated-list-mode "yt-list"
  "Base mode of yt's lists of channels, playlists and played videos."
  :group 'yt-feed
  :interactive nil
  (setq tabulated-list-use-header-line nil
        tabulated-list-sort-key nil
        header-line-format '(:eval (yt-list-header-line))))

;;;; Integrations

(defvar yt-list--integrations-scheduled nil
  "Non-nil once loading yt-select for embark or marginalia was scheduled.")

(defun yt-list--load-integrations (&rest _)
  "Load yt-select once embark or marginalia is loaded.
yt-select registers yt's embark target finder and actions and its
marginalia annotations.  It is loaded from a timer, because this runs
from `after-load-functions', possibly while yt's own files are still
loading, and yt-select requires most of them."
  (when (and (not yt-list--integrations-scheduled)
             (not (featurep 'yt-select))
             (or (featurep 'embark) (featurep 'marginalia)))
    (setq yt-list--integrations-scheduled t)
    (run-at-time 0 nil #'require 'yt-select)))

(yt-list--load-integrations)
(add-hook 'after-load-functions #'yt-list--load-integrations)

(provide 'yt-list)
;;; yt-list.el ends here
