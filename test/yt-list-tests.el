;;; yt-list-tests.el --- Tests for the shared list code -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for columns that fit the window.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-list)
(require 'yt-feed)
(require 'yt-history)

(defun yt-list-test--total (format)
  "Return the characters a row of FORMAT takes, with one space between columns."
  (+ (apply #'+ (mapcar #'cadr (append format nil))) (1- (length format))))

(defun yt-list-test--width (format name)
  "Return the width of the column NAME in FORMAT."
  (nth 1 (seq-find (lambda (column) (equal (car column) name)) format)))

(ert-deftest yt-list-column-widths ()
  "The Title column takes what the others leave; Channel shrinks when narrow."
  (dolist (width '(50 60 100 200))
    (let ((format (yt-list-column-widths yt-feed--format width)))
      (should (<= (yt-list-test--total format) width))
      (should (equal (mapcar #'car format) (mapcar #'car yt-feed--format)))))
  (should (= (yt-list-test--width (yt-list-column-widths yt-feed--format 100) "Title")
             (- 100 (yt-list-test--total yt-feed--format)
                (- (yt-list-test--width yt-feed--format "Title")) 1)))
  ;; Narrow: the channel gives way before the title goes under 20.
  (let ((narrow (yt-list-column-widths yt-feed--format 50)))
    (should (< (yt-list-test--width narrow "Channel") 20))
    (should (>= (yt-list-test--width narrow "Title") 20)))
  ;; Wide: the title stops at 150.
  (should (= (yt-list-test--width (yt-list-column-widths yt-feed--format 400) "Title") 150))
  ;; The format passed in is never changed.
  (should (= (yt-list-test--width yt-feed--format "Title") 70))
  (should (eq (yt-list-column-widths yt-feed--format nil) yt-feed--format))
  (should (equal (yt-list-column-widths [("Playlist" 40 t)] 100) [("Playlist" 40 t)])))

(ert-deftest yt-list-columns-follow-the-window ()
  "A buffer's columns are fitted again, and it is reprinted, when its width changes."
  (yt-test-with-scenario (_ _)
    (with-temp-buffer
      (yt-history-mode)
      (let ((width 80) (prints 0))
        (setq-local yt-list-reprint-function (lambda () (cl-incf prints)))
        (cl-letf (((symbol-function 'yt-list--window-width) (lambda () width)))
          (yt-list--refit (current-buffer))
          (should (<= (yt-list-test--total tabulated-list-format) 80))
          (setq prints 0 width 200)
          (yt-list--refit (current-buffer))
          (should (= prints 1))
          (should (> (yt-list-test--width tabulated-list-format "Title") 100))
          ;; The same width again: nothing to do.
          (yt-list--refit (current-buffer))
          (should (= prints 1)))))))

(provide 'yt-list-tests)
;;; yt-list-tests.el ends here
