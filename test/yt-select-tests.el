;;; yt-select-tests.el --- Tests for yt-select.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for choosing videos with completion, their annotations, and
;; the embark and marginalia integrations.  embark and marginalia are
;; on the test Emacs's load path, but only these tests load them.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-select)

(defconst yt-select-test--now 1793500000
  "The fixed current time of these tests.")

(defun yt-select-test--videos ()
  "Return the videos of the feed fixture, in order."
  (mapcar (lambda (line) (yt-video-from-json (yt-process-parse-json line) t))
          (split-string (yt-test-fixture-string "feed.ndjson") "\n" t)))

(ert-deftest yt-select-candidates ()
  "Candidates are titles carrying their video, made unique by the id."
  (clrhash yt-select--videos)
  (let* ((a (yt-video--make :id "aaaaaaaaaaa" :title "Same title"))
         (b (yt-video--make :id "bbbbbbbbbbb" :title "Same title"))
         (ca (yt-select-candidate a))
         (cb (yt-select-candidate b)))
    (should (equal ca "Same title"))
    (should (equal cb "Same title (bbbbbbbbbbb)"))
    (should (eq (yt-select-candidate-video ca) a))
    ;; Without text properties, the table still finds the video.
    (should (eq (yt-select-candidate-video (substring-no-properties cb)) b))
    (should-not (yt-select-candidate-video "unknown"))))

(ert-deftest yt-select-annotation ()
  "Annotations show the channel, age and duration."
  (clrhash yt-select--videos)
  (let ((yt--now-function (lambda () yt-select-test--now)))
    (pcase-let ((`(,normal ,upcoming ,_live ,short)
                 (mapcar #'yt-select-candidate (yt-select-test--videos))))
      (should (equal (substring-no-properties (yt-select-annotate normal))
                     "  Fake Channel One         5h  12:34"))
      (should (string-suffix-p "SOON" (substring-no-properties (yt-select-annotate upcoming))))
      ;; A Short has no channel, time or duration in the feed.
      (should (string-blank-p (yt-select-annotate short)))
      (should (eq (get-text-property 2 'face (yt-select-annotate normal)) 'yt-feed-channel)))))

(ert-deftest yt-select-video-completes ()
  "`yt-select-video' offers yt-video candidates in feed order and returns one."
  (yt-test-with-scenario (_ _)
    (yt-cache-put-feed "subscriptions" (yt-select-test--videos))
    (let (metadata offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq metadata (funcall table "" nil 'metadata)
                         offered (all-completions "" table))
                   (nth 2 offered))))
        (let ((video (yt-select-video)))
          (should (equal (yt-video-id video) "fakevideo03"))))
      (should (eq (alist-get 'category (cdr metadata)) 'yt-video))
      (should (eq (alist-get 'display-sort-function (cdr metadata)) #'identity))
      (should (equal offered '("A normal video with ünïcode" "An upcoming premiere"
                               "A past live stream" "A short")))
      (let ((yt-select-group-by-channel t))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (setq metadata (funcall table "" nil 'metadata))
                     "A short")))
          (yt-select-video)))
      (should (eq (alist-get 'group-function (cdr metadata)) #'yt-select--group))
      (should (equal (yt-select--group "A normal video with ünïcode" nil) "Fake Channel One"))
      (should (equal (yt-select--group "A short" nil) "Unknown channel")))))

(ert-deftest yt-select-actions-run-commands-on-candidates ()
  "Each video key has an embark action running its command on the candidate."
  (dolist (key '("RET" "v" "m" "a" "i" "o" "w" "u" "b" "y" "Y"))
    (should (functionp (keymap-lookup yt-embark-video-map key))))
  (should (eq (keymap-lookup yt-embark-video-map "RET") 'yt-select-act-play))
  (clrhash yt-select--videos)
  (let* ((video (yt-video--make :id "ccccccccccc" :title "Candidate"
                                :url "https://www.youtube.com/watch?v=ccccccccccc"))
         (candidate (yt-select-candidate video))
         played)
    (cl-letf (((symbol-function 'yt-player--start)
               (lambda (backend v &optional start) (setq played (list backend v start)))))
      (let ((yt-player-backend 'vlc)
            (yt-player-resume nil))
        ;; In a feed buffer the candidate wins over the row at point.
        (with-temp-buffer
          (setq-local yt-video-at-point-function
                      (lambda () (yt-video--make :id "rowatpoint1")))
          (funcall (keymap-lookup yt-embark-video-map "RET")
                   (substring-no-properties candidate)))))
    (should (equal played (list 'vlc video nil)))
    (let ((kill-ring nil))
      (funcall (keymap-lookup yt-embark-video-map "y") candidate)
      (should (equal (car kill-ring) "https://www.youtube.com/watch?v=ccccccccccc")))))

(ert-deftest yt-select-embark-integration ()
  "Loading embark registers yt's keymap and target finder."
  (skip-unless (locate-library "embark"))
  (require 'embark)
  (should (eq (alist-get 'yt-video embark-keymap-alist) 'yt-embark-video-map))
  (should (memq #'yt-select-embark-target embark-target-finders))
  (should (eq (keymap-parent yt-embark-video-map) embark-general-map))
  ;; In a yt buffer, the video at point is a target.
  (clrhash yt-select--videos)
  (let ((video (yt-video--make :id "ddddddddddd" :title "At point")))
    (with-temp-buffer
      (setq-local yt-video-at-point-function (lambda () video))
      (let ((target (yt-select-embark-target)))
        (should (eq (car target) 'yt-video))
        (should (eq (yt-select-candidate-video (cdr target)) video))))
    (with-temp-buffer
      (should-not (yt-select-embark-target)))))

(defun yt-select-test--child (forms)
  "Evaluate FORMS in a fresh Emacs with this load path; return its output."
  (with-temp-buffer
    (let ((status (call-process
                   (expand-file-name invocation-name invocation-directory) nil t nil
                   "-Q" "--batch"
                   "--eval" (prin1-to-string `(setq load-path ',load-path))
                   "--eval" (prin1-to-string `(progn ,@forms)))))
      (should (equal (list status (buffer-string)) (list 0 (buffer-string))))
      (buffer-string))))

(ert-deftest yt-select-embark-without-yt-select ()
  "Embark acts on yt rows without yt-select loaded first, in either order."
  (skip-unless (locate-library "embark"))
  (dolist (order '((embark yt-feed) (yt-feed embark)))
    (should (string-match-p
             "registered: t"
             (yt-select-test--child
              `((dolist (feature ',order) (require feature))
                (accept-process-output nil 0.1)
                (princ (format "registered: %s"
                               (and (memq 'yt-select-embark-target
                                          (bound-and-true-p embark-target-finders))
                                    t)))))))))

(ert-deftest yt-select-marginalia-integration ()
  "Loading marginalia registers yt's annotations."
  (skip-unless (locate-library "marginalia"))
  (require 'marginalia)
  (should (equal (assq 'yt-video marginalia-annotators)
                 '(yt-video yt-select-annotate builtin none))))

(provide 'yt-select-tests)
;;; yt-select-tests.el ends here
