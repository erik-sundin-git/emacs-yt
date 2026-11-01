;;; yt-thumbs-tests.el --- Tests for thumbnails -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for downloading thumbnails with the fake curl: the queue
;; limit, deduplication, the ".part" rename, failures, and the feed
;; showing them without blocking.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-thumbs)
(require 'yt-feed)

(defmacro yt-thumbs-test--with (dirs &rest body)
  "Run BODY in a scenario with the fake curl and a fresh thumbnail cache.
DIRS is (YTDLP-DIR CURL-DIR), bound to the fake yt-dlp's scenario
directory and the fake curl's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,(car dirs) _export)
     (ignore _export)
     (let* ((,(cadr dirs) (expand-file-name "curl" ,(car dirs)))
            (yt-curl-program (expand-file-name "fake-curl" yt-test-bin-dir))
            (process-environment (cons (concat "FAKE_CURL_DIR=" ,(cadr dirs))
                                       process-environment))
            (process-environment (cons (concat "XDG_CACHE_HOME="
                                               (expand-file-name "cache" ,(car dirs)))
                                       process-environment))
            (yt-thumbs--queue (yt-process-queue-create 4))
            (yt-thumbs--pending (make-hash-table :test #'equal))
            (yt-thumbs--failed (make-hash-table :test #'equal))
            (yt-thumbs--directory nil)
            (yt-thumbs--curl-missing nil)
            (yt-thumbs-changed-functions nil))
       (make-directory ,(cadr dirs) t)
       ,@body)))

(defun yt-thumbs-test--calls (dir)
  "Return the argument lines of the fake curl calls in DIR."
  (let ((file (expand-file-name "calls" dir)))
    (and (file-exists-p file)
         (split-string (yt-test-file-string file) "\n" t))))

(ert-deftest yt-thumbs-download-renames-part-file ()
  "A thumbnail is written to a .part file and renamed when complete."
  (yt-thumbs-test--with (_ytdlp curl)
    (let (arrived)
      (add-hook 'yt-thumbs-changed-functions (lambda (id) (push id arrived)))
      (should (yt-test-under-root-p (yt-thumbs-directory)))
      (should (= (file-modes (yt-thumbs-directory)) #o700))
      (yt-thumbs-fetch '("abcdefghijk"))
      (yt-test-wait-until (lambda () arrived) "thumbnail")
      (should (equal arrived '("abcdefghijk")))
      (should (equal (yt-test-file-string (yt-thumbs-file "abcdefghijk")) "FAKEJPEG"))
      (should-not (file-exists-p (concat (yt-thumbs-file "abcdefghijk") ".part")))
      (let ((call (car (yt-thumbs-test--calls curl))))
        (should (string-match-p "--fail" call))
        (should (string-match-p "--proto =https" call))
        (should (string-suffix-p "-- https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg" call))
        (should-not (string-match-p "cookie" call)))
      (should (eq (car (yt-thumbs-image "abcdefghijk")) 'image))
      ;; A cached thumbnail is not fetched again.
      (yt-thumbs-fetch '("abcdefghijk"))
      (yt-test-sleep 0.1)
      (should (= (length (yt-thumbs-test--calls curl)) 1)))))

(ert-deftest yt-thumbs-failure-leaves-nothing-and-is-not-retried ()
  "A failed download leaves no file and is not retried in the session."
  (yt-thumbs-test--with (_ytdlp curl)
    (yt-test-write (expand-file-name "fail" curl) "")
    (yt-thumbs-fetch '("failedvideo"))
    (yt-test-wait-until (lambda () (gethash "failedvideo" yt-thumbs--failed)) "failure")
    (should-not (file-exists-p (yt-thumbs-file "failedvideo")))
    (should-not (file-exists-p (concat (yt-thumbs-file "failedvideo") ".part")))
    (should-not (yt-thumbs-image "failedvideo"))
    (yt-thumbs-fetch '("failedvideo"))
    (yt-test-sleep 0.1)
    (should (= (length (yt-thumbs-test--calls curl)) 1))))

(ert-deftest yt-thumbs-queue-limit-and-dedup ()
  "At most four downloads run at once, and each video is fetched once."
  (yt-thumbs-test--with (_ytdlp curl)
    (yt-test-write (expand-file-name "hang" curl) "")
    (let ((ids (mapcar (lambda (n) (format "video%06d" n)) (number-sequence 1 6))))
      (yt-thumbs-fetch ids)
      (yt-thumbs-fetch ids)
      (yt-test-wait-until (lambda () (= (length (yt-thumbs-test--calls curl)) 4)) "4 downloads")
      (yt-test-sleep 0.2)
      (should (= (length (yt-thumbs-test--calls curl)) 4))
      (should (= (yt-process-queue-running yt-thumbs--queue) 4))
      (should (= (length (yt-process-queue-waiting yt-thumbs--queue)) 2))
      ;; A half-written download is never shown.
      (should-not (yt-thumbs-image "video000001"))
      ;; Cancelling starts the waiting two, which now finish at once.
      (delete-file (expand-file-name "hang" curl))
      (dolist (id ids)
        (yt-process-cancel (cons 'yt-thumbs id)))
      (yt-test-wait-until (lambda () (zerop (hash-table-count yt-thumbs--pending)))
                          "cancelled"))))

(ert-deftest yt-thumbs-ignores-unsafe-ids ()
  "Ids that are not plain video ids are never used in file names or URLs."
  (yt-thumbs-test--with (_ytdlp curl)
    (yt-thumbs-fetch '("../../etc" "a b" nil))
    (yt-test-sleep 0.1)
    (should-not (yt-thumbs-test--calls curl))
    (should-not (yt-thumbs-image "../../etc"))))

(ert-deftest yt-thumbs-feed-shows-them-without-blocking ()
  "With thumbnails on, \\[yt] returns at once and rows get their images."
  (yt-thumbs-test--with (ytdlp curl)
    (yt-test-install-cookies)
    (yt-cache-put-feed "subscriptions"
                       (mapcar (lambda (line) (yt-video-from-json (yt-process-parse-json line) t))
                               (split-string (yt-test-fixture-string "feed.ndjson") "\n" t)))
    (yt-test-step ytdlp 1 :mode "hang")
    (yt-test-write (expand-file-name "hang" curl) "")
    (cl-letf (((symbol-function 'yt-feed--images-p) (lambda () t))
              ((symbol-function 'yt-feed--visible-ids)
               (lambda () (yt-feed--printed-ids))))
      (let* ((yt-feed-thumbnails t)
             (start (float-time))
             (buffer (save-window-excursion (yt)))
             (elapsed (- (float-time) start)))
        (unwind-protect
            (with-current-buffer buffer
              (should (< elapsed 0.2))
              (should (= (length (aref tabulated-list-format 0)) 3))
              (yt-test-wait-until (lambda () (= (length (yt-thumbs-test--calls curl)) 4))
                                  "thumbnail downloads")
              ;; Let the downloads finish: the rows are redrawn with images.
              (delete-file (expand-file-name "hang" curl))
              (dolist (id (yt-feed--printed-ids))
                (yt-process-cancel (cons 'yt-thumbs id)))
              (yt-test-wait-until (lambda () (zerop (hash-table-count yt-thumbs--pending)))
                                  "cancelled")
              (yt-thumbs-fetch (yt-feed--printed-ids))
              (yt-test-wait-until
               (lambda ()
                 (seq-every-p #'file-exists-p
                              (mapcar #'yt-thumbs-file (yt-feed--printed-ids))))
               "thumbnails")
              (yt-test-wait-until
               (lambda ()
                 (save-excursion
                   (goto-char (gethash "fakevideo01" (yt-feed--row-positions)))
                   (eq (car-safe (get-text-property (point) 'display)) 'image)))
               "image in row")
              (yt-feed-toggle-thumbnails)
              (should (equal (aref tabulated-list-format 0) '(" " 1 nil))))
          (kill-buffer buffer))))))

(provide 'yt-thumbs-tests)
;;; yt-thumbs-tests.el ends here
