;;; yt-sponsorblock-tests.el --- Tests for SponsorBlock -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for fetching SponsorBlock segments with the fake curl (the
;; hash prefix, parsing, caching, failures), choosing the segments to
;; skip, skipping them in mpv with undo and the toggle, fetching them
;; while a video is resolved, and listing them in the info buffer.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-sponsorblock)
(require 'yt-mpv)
(require 'yt-info)

(defconst yt-sponsorblock-test--response
  (concat
   "[{\"videoID\":\"othervideo1\",\"segments\":[{\"segment\":[1,2],\"category\":\"sponsor\","
   "\"actionType\":\"skip\",\"UUID\":\"u0\",\"videoDuration\":100}]},"
   "{\"videoID\":\"fakevideo01\",\"segments\":["
   "{\"segment\":[30.5,75.0],\"category\":\"sponsor\",\"actionType\":\"skip\","
   "\"UUID\":\"u1\",\"videoDuration\":754.2},"
   "{\"segment\":[0,8],\"category\":\"intro\",\"actionType\":\"skip\","
   "\"UUID\":\"u2\",\"videoDuration\":754},"
   "{\"segment\":[100,110],\"category\":\"sponsor\",\"actionType\":\"mute\","
   "\"UUID\":\"u3\",\"videoDuration\":754},"
   "{\"segment\":[200,210],\"category\":\"unknown_kind\",\"actionType\":\"skip\","
   "\"UUID\":\"u4\",\"videoDuration\":754},"
   "{\"segment\":[300,320],\"category\":\"selfpromo\",\"actionType\":\"skip\","
   "\"UUID\":\"u5\",\"videoDuration\":600}]}]")
  "A SponsorBlock answer for the hash prefix of fakevideo01.")

(defmacro yt-sponsorblock-test--with (curl &rest body)
  "Run BODY in a scenario with SponsorBlock on and the fake curl.
CURL is bound to the fake curl's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (ytdlp _export)
     (ignore _export)
     (let* ((,curl (expand-file-name "curl" ytdlp))
            (yt-curl-program (expand-file-name "fake-curl" yt-test-bin-dir))
            (yt-sponsorblock-categories '(sponsor selfpromo interaction))
            (process-environment (cons (concat "FAKE_CURL_DIR=" ,curl)
                                       process-environment)))
       (make-directory ,curl t)
       ,@body)))

(defun yt-sponsorblock-test--respond (dir n status &optional body)
  "Make the Nth request to the fake curl in DIR answer BODY with STATUS."
  (yt-test-write (expand-file-name (format "%02d.status" n) dir) (format "%d" status))
  (when body
    (yt-test-write (expand-file-name (format "%02d.response" n) dir) body)))

(defun yt-sponsorblock-test--count (dir)
  "Return how many requests the fake curl in DIR received."
  (let ((file (expand-file-name "api-count" dir)))
    (if (file-exists-p file) (string-to-number (yt-test-file-string file)) 0)))

(defun yt-sponsorblock-test--fetch (id)
  "Fetch the segments of ID and wait for them."
  (let ((result 'waiting))
    (yt-sponsorblock-fetch id (lambda (segments) (setq result segments)))
    (yt-test-wait-until (lambda () (not (eq result 'waiting))) "segments")
    result))

(ert-deftest yt-sponsorblock-fetch-parses-and-caches ()
  "Only a hash prefix is sent; the video's skip segments are kept."
  (yt-sponsorblock-test--with curl
    (yt-sponsorblock-test--respond curl 1 200 yt-sponsorblock-test--response)
    (let ((segments (yt-sponsorblock-test--fetch "fakevideo01")))
      (should (equal (mapcar (lambda (s) (plist-get s :uuid)) segments) '("u1" "u2" "u5")))
      (should (equal (car segments)
                     '(:start 30.5 :end 75.0 :category sponsor :uuid "u1"
                              :video-duration 754.2))))
    (let ((call (yt-test-file-string (expand-file-name "calls" curl))))
      (should (string-match-p
               (concat "https://sponsor.ajay.app/api/skipSegments/"
                       (substring (secure-hash 'sha256 "fakevideo01") 0 4) "\\?")
               call))
      (should-not (string-match-p "fakevideo01" call))
      (should (string-match-p "--proto =https" call))
      (should-not (string-match-p "cookie" call)))
    ;; Kept for the session: no second request.
    (should (= (length (yt-sponsorblock-test--fetch "fakevideo01")) 3))
    (should (= (length (yt-sponsorblock-segments "fakevideo01")) 3))
    (should (= (yt-sponsorblock-test--count curl) 1))))

(ert-deftest yt-sponsorblock-fetch-failures ()
  "No segments are remembered; failures are tried again; off means no request."
  (yt-sponsorblock-test--with curl
    ;; 404: no video with this hash prefix has segments.
    (yt-sponsorblock-test--respond curl 1 404 "Not Found")
    (should-not (yt-sponsorblock-test--fetch "nosegments1"))
    (should-not (yt-sponsorblock-test--fetch "nosegments1"))
    (should (= (yt-sponsorblock-test--count curl) 1))
    ;; Other videos share the prefix, but not this one.
    (yt-sponsorblock-test--respond curl 2 200 yt-sponsorblock-test--response)
    (should-not (yt-sponsorblock-test--fetch "notlisted01"))
    ;; A server error is not remembered.
    (yt-sponsorblock-test--respond curl 3 502 "Bad Gateway")
    (should-not (yt-sponsorblock-test--fetch "fakevideo01"))
    (yt-sponsorblock-test--respond curl 4 200 yt-sponsorblock-test--response)
    (should (= (length (yt-sponsorblock-test--fetch "fakevideo01")) 3))
    ;; Two fetches at once share one request.
    (yt-sponsorblock-test--respond curl 5 200 yt-sponsorblock-test--response)
    (let (results)
      (yt-sponsorblock-fetch "othervideo1" (lambda (s) (push (length s) results)))
      (yt-sponsorblock-fetch "othervideo1" (lambda (s) (push (length s) results)))
      (yt-test-wait-until (lambda () (= (length results) 2)) "both callbacks")
      (should (equal results '(1 1))))
    (should (= (yt-sponsorblock-test--count curl) 5))
    (let ((yt-sponsorblock-categories nil))
      (should-not (yt-sponsorblock-test--fetch "anothervid1")))
    (should (= (yt-sponsorblock-test--count curl) 5))))

(ert-deftest yt-sponsorblock-skippable ()
  "Only chosen categories, from a cut of the same length, are skipped."
  (let ((segments '((:start 1 :end 2 :category sponsor :video-duration 754.2)
                    (:start 3 :end 4 :category intro :video-duration 754)
                    (:start 5 :end 6 :category selfpromo :video-duration 600)
                    (:start 7 :end 8 :category sponsor :video-duration 0)))
        (yt-sponsorblock-categories '(sponsor selfpromo)))
    (should (equal (mapcar (lambda (s) (plist-get s :start))
                           (yt-sponsorblock-skippable segments 754))
                   '(1 7)))
    ;; Without a known duration, every chosen segment counts.
    (should (= (length (yt-sponsorblock-skippable segments nil)) 3))
    (should (equal (yt-sponsorblock-category-name 'selfpromo) "self-promotion"))))

(ert-deftest yt-sponsorblock-mpv-skips-once-and-undoes ()
  "mpv seeks past a segment once; undo goes back; the toggle stops skipping."
  (yt-sponsorblock-test--with _curl
    (let* ((yt-mpv--entries (make-hash-table))
           (yt-mpv--current 7)
           (yt-mpv--properties nil)
           (yt-mpv--skipping t)
           (yt-player--current-backend 'mpv)
           (video (yt-video--make :id "fakevideo01" :title "Fake" :duration 754))
           (entry (yt-mpv--entry 7))
           sent messages)
      (setf (yt-mpv--entry-video entry) video)
      (puthash "fakevideo01"
               (yt-sponsorblock--parse
                "fakevideo01" (yt-process-parse-json yt-sponsorblock-test--response))
               yt-sponsorblock--segments)
      (cl-letf (((symbol-function 'yt-mpv-send) (lambda (command &rest _) (push command sent)))
                ((symbol-function 'yt-mpv--process-alive-p) (lambda () t))
                ((symbol-function 'yt-player-update-mode-line) #'ignore)
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format-message format args) messages))))
        ;; The intro is not a chosen category.
        (yt-mpv--property "time-pos" 3.0)
        (should-not sent)
        (yt-mpv--property "time-pos" 31.0)
        (should (equal sent '(("seek" 75.0 "absolute"))))
        (should (string-match-p "\\`Skipped sponsor (44 s); .* goes back\\'" (car messages)))
        (yt-player-unskip)
        (should (equal (car sent) '("seek" 30.5 "absolute")))
        (should (equal (car messages) "Back to the sponsor"))
        ;; Back in the segment, it plays.
        (yt-mpv--property "time-pos" 31.0)
        (should (= (length sent) 2))
        (should-error (yt-player-unskip) :type 'user-error)
        ;; The self-promotion was submitted for a 600 s cut: ignored.
        (yt-mpv--property "time-pos" 305.0)
        (should (= (length sent) 2))
        ;; Toggled off, nothing is skipped.
        (setf (yt-mpv--entry-skipped entry) nil)
        (yt-player-toggle-skipping)
        (should (equal (car messages) "Skipping SponsorBlock segments: off"))
        (yt-mpv--property "time-pos" 40.0)
        (should (= (length sent) 2))
        (yt-player-toggle-skipping)
        (yt-mpv--property "time-pos" 40.0)
        (should (equal (car sent) '("seek" 75.0 "absolute")))))))

(ert-deftest yt-sponsorblock-fetched-while-resolving ()
  "Playing in mpv fetches the segments while the streams are resolved."
  (yt-sponsorblock-test--with _curl
    (let ((video (yt-video--make :id "fakevideo01" :url "https://www.youtube.com/watch?v=fakevideo01"))
          fetched)
      (cl-letf (((symbol-function 'yt-sponsorblock-fetch) (lambda (id &rest _) (push id fetched)))
                ((symbol-function 'yt-player-resolve) #'ignore)
                ((symbol-function 'yt-player--load) #'ignore)
                ((symbol-function 'yt-player-display-environment) #'ignore))
        (yt-player--start 'mpv video)
        (should (equal fetched '("fakevideo01")))
        (yt-player--start 'vlc video)
        (should (equal fetched '("fakevideo01")))))))

(ert-deftest yt-sponsorblock-info-lists-segments ()
  "The info buffer lists the segments, saying which mpv skips."
  (yt-sponsorblock-test--with curl
    (yt-sponsorblock-test--respond curl 1 200 yt-sponsorblock-test--response)
    (let ((video (yt-video--make :id "fakevideo01" :title "Fake" :duration 754
                                 :url "https://www.youtube.com/watch?v=fakevideo01")))
      (cl-letf (((symbol-function 'yt-auth-run) #'ignore))
        (with-current-buffer (yt-info video)
          (yt-test-wait-until (lambda () yt-info--segments) "segments")
          (let ((text (buffer-string)))
            (should (string-match-p
                     (concat "SponsorBlock\n +0:00–0:08 +intro\n"
                             " +0:30–1:15 +sponsor  skipped in mpv\n"
                             " +5:00–5:20 +self-promotion  skipped in mpv\n")
                     text)))
          (kill-buffer))))))

(provide 'yt-sponsorblock-tests)
;;; yt-sponsorblock-tests.el ends here
