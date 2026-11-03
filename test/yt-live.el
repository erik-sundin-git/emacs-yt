;;; yt-live.el --- Smoke test against the real YouTube -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `nix run .#smoke' runs this in batch, with the sandbox's state, to
;; check that yt still works with the real YouTube and the installed
;; yt-dlp.  It is not part of `make test', which never uses the
;; network.  It refuses to run unless YT_LIVE=1, and under CI.
;;
;; It prints counts and booleans only: never ids, titles, channels,
;; URLs or anything from the cookie file.  It sends no plays to the
;; YouTube history and changes nothing in the account.  It exits with
;; status 1 if a check failed.

;;; Code:

(require 'yt)
(require 'yt-auth)
(require 'yt-ytdlp)
(require 'yt-video)
(require 'yt-player)
(require 'yt-sponsorblock)

(unless (equal (getenv "YT_LIVE") "1")
  (error "Set YT_LIVE=1 to run checks against the real YouTube"))
(when (getenv "CI")
  (error "The live checks never run under CI"))
(unless (string-match-p "/yt-sandbox/" (file-name-as-directory yt-state-directory))
  (error "The live checks run only on the sandbox's state, not %s" yt-state-directory))

(setq yt-player-youtube-history nil)

(defconst yt-live-feed-keys '(:id :title :url :duration :channel :channel_id)
  "Keys of a subscription feed entry yt relies on.")

(defconst yt-live-resolve-keys '(:video :duration :title)
  "Keys of resolved streams yt relies on.")

(defvar yt-live--failed nil
  "Non-nil once a check failed.")

(defun yt-live--report (name ok &optional detail)
  "Print the result of the check NAME, OK or not, with DETAIL."
  (unless ok (setq yt-live--failed t))
  (princ (format "%-12s %s%s\n" name (if ok "ok" "FAILED")
                 (if detail (concat "  " detail) ""))))

(defun yt-live--wait (fn)
  "Call FN with a callback and wait, up to two minutes, for its value."
  (let ((result 'yt-live--waiting)
        (deadline (+ (float-time) 120)))
    (funcall fn (lambda (&rest values) (setq result values)))
    (while (and (eq result 'yt-live--waiting) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (unless (eq result 'yt-live--waiting) result)))

(defun yt-live--missing (plist keys)
  "Return the KEYS that PLIST has no value for."
  (seq-remove (lambda (key) (plist-get plist key)) keys))

;; yt-dlp
(let ((version (string-trim (shell-command-to-string
                             (concat (shell-quote-argument yt-ytdlp-program) " --version")))))
  (yt-live--report "yt-dlp" (yt-ytdlp-parse-version version) version))

;; Sign-in
(let ((result (yt-live--wait
               (lambda (done)
                 (yt-auth-run (yt-ytdlp-verify-args) :source 'verify :ignore-backoff t
                              :on-success (lambda (_ _) (funcall done t))
                              :on-error (lambda (err) (funcall done nil (plist-get err :class))))))))
  (yt-live--report "sign-in" (car result)
                   (format "state %s" (or (cadr result) (yt-auth-state)))))

;; Feed
(let* ((entries nil)
       (result (yt-live--wait
                (lambda (done)
                  (yt-auth-run (yt-ytdlp-feed-args 5) :parse 'ndjson :source 'feed
                               :on-line (lambda (entry) (push entry entries) nil)
                               :on-success (lambda (_ _) (funcall done t))
                               :on-error (lambda (err) (funcall done nil (plist-get err :class)))))))
       (missing (delete-dups (mapcan (lambda (entry) (yt-live--missing entry yt-live-feed-keys))
                                     (copy-sequence entries))))
       (video (seq-some (lambda (entry)
                          (let ((video (yt-video-from-json entry t)))
                            (and video (not (yt-video-short-p video))
                                 (not (yt-video-live-status video)) video)))
                        entries)))
  (yt-live--report "feed" (and (car result) entries)
                   (format "%d entries; keys missing in some: %S" (length entries) missing))
  ;; Resolving a stream, without playing it
  (if (not video)
      (yt-live--report "resolve" nil "no ordinary video in the feed")
    (let ((result (yt-live--wait
                   (lambda (done)
                     (yt-player-resolve video (lambda (streams _) (funcall done streams))
                                        (lambda (err) (funcall done nil (plist-get err :class))))))))
      (yt-live--report "resolve" (car result)
                       (if (car result)
                           (format "audio separate %s; available-at %s; chapters %d; keys missing: %S"
                                   (and (plist-get (car result) :audio) t)
                                   (and (plist-get (car result) :available-at) t)
                                   (length (plist-get (car result) :chapters))
                                   (yt-live--missing (car result) yt-live-resolve-keys))
                         (format "%s" (cadr result))))))
  ;; SponsorBlock, which answers for any video, with or without segments
  (when video
    (let ((result (yt-live--wait
                   (lambda (done)
                     (let ((yt-sponsorblock-categories '(sponsor)))
                       (yt-sponsorblock-fetch (yt-video-id video) done))))))
      (yt-live--report "sponsorblock" result
                       (format "%d segments" (length (car result)))))))

(kill-emacs (if yt-live--failed 1 0))

;;; yt-live.el ends here
