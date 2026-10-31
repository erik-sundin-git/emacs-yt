;;; checkdoc-batch.el --- Run checkdoc on files and fail on warnings -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Usage: emacs -Q --batch -l scripts/checkdoc-batch.el FILE...
;; Checks each FILE with `checkdoc-file', which prints its warnings,
;; and exits with status 1 if any file had one.

;;; Code:

(require 'checkdoc)

(let ((failed 0))
  (dolist (file command-line-args-left)
    (setq checkdoc-pending-errors nil)
    (checkdoc-file file)
    (when checkdoc-pending-errors
      (setq failed (1+ failed))))
  (setq command-line-args-left nil)
  (message "checkdoc: %d file(s) with warnings" failed)
  (kill-emacs (if (zerop failed) 0 1)))

;;; checkdoc-batch.el ends here
