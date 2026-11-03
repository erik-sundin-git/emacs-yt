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
;; player's playlist) share:
;;
;; - Columns that fit the window: the Title column takes the width the
;;   other columns leave, so that age and duration stay visible in a
;;   narrow window and long titles use a wide one.
;; - Loading the embark and marginalia integrations of yt-select.el as
;;   soon as either package is loaded, so that embark acts on the rows
;;   of every yt buffer without yt-select having been used first.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

;;;; Columns that fit the window

(defvar yt-list-title-width-range '(20 . 150)
  "The narrowest and widest the Title column gets, in characters.")

(defvar-local yt-list--base-format nil
  "This buffer's columns at their nominal widths, or nil.
`yt-list-fit-columns' fits them to the window.")

(defvar-local yt-list-reprint-function nil
  "Function that prints this buffer again after its columns changed.
nil means `tabulated-list-print' keeping point.")

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
            (if yt-list-reprint-function
                (funcall yt-list-reprint-function)
              (tabulated-list-print t))))))))

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
