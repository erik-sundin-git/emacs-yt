;;; yt-subscribe-tests.el --- Tests for subscribing to channels -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for subscribing and unsubscribing with the fake curl: the
;; authorization header, the request, keeping cookies out of the
;; process list, the cache and buffers afterwards, an expired session,
;; and opening the channel in Chromium when YouTube refuses.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-subscribe)
(require 'yt-channels)

(defconst yt-subscribe-test--id "UCfakechannel00000000002"
  "A channel id of the fixtures.")

(defconst yt-subscribe-test--other "UCfakechannel00000000001"
  "Another channel id.")

(defmacro yt-subscribe-test--with (dirs &rest body)
  "Run BODY in a scenario with cookies and the fake curl.
DIRS is (EXPORT-DIR CURL-DIR), bound to the fake exporter's scenario
directory and the fake curl's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (ytdlp ,(car dirs))
     (let* ((,(cadr dirs) (expand-file-name "curl" ytdlp))
            (yt-curl-program (expand-file-name "fake-curl" yt-test-bin-dir))
            (process-environment (cons (concat "FAKE_CURL_DIR=" ,(cadr dirs))
                                       process-environment))
            (yt--now-function (lambda () 1793500000))
            (yt-feed--fully-refreshed (list 'subscriptions))
            (yt-subscriptions-changed-functions nil))
       (make-directory ,(cadr dirs) t)
       (yt-test-install-cookies)
       (unwind-protect
           (save-window-excursion ,@body)
         (dolist (buffer (buffer-list))
           (when (string-prefix-p "*yt: " (buffer-name buffer))
             (kill-buffer buffer)))))))

(defun yt-subscribe-test--respond (dir n status &optional subscribed)
  "Make the Nth API call of the fake curl in DIR answer with STATUS.
With SUBSCRIBED `yes' or `no', the response confirms that state."
  (yt-test-write (expand-file-name (format "%02d.status" n) dir) (format "%d" status))
  (yt-test-write (expand-file-name (format "%02d.response" n) dir)
                 (pcase subscribed
                   ('yes "{\"actions\":[{\"x\":1},{\"updateSubscribeButtonAction\":{\"subscribed\":true}}]}")
                   ('no "{\"actions\":[{\"updateSubscribeButtonAction\":{\"subscribed\":false}}]}")
                   (_ "{\"error\":{\"code\":400,\"message\":\"Error subscribing, try again\"}}"))))

(defun yt-subscribe-test--api-calls (dir)
  "Return how many API calls the fake curl in DIR received."
  (let ((file (expand-file-name "api-count" dir)))
    (if (file-exists-p file) (string-to-number (yt-test-file-string file)) 0)))

(defun yt-subscribe-test--channel (id)
  "Return the channel plist of ID."
  (list :id id :name (format "Channel %s" (substring id -1))
        :url (format "https://www.youtube.com/channel/%s" id)))

(defun yt-subscribe-test--video (id channel-id)
  "Return a video ID of the channel CHANNEL-ID."
  (yt-video--make :id id :title id :channel-id channel-id :timestamp 1793400000))

(ert-deftest yt-subscribe-authorization ()
  "The header hashes each SAPISID cookie with the time and the origin."
  (let ((file (make-temp-file (expand-file-name "cookies-" yt-test-root))))
    (unwind-protect
        (progn
          (yt-test-write
           file
           (concat "# Netscape HTTP Cookie File\n"
                   ".youtube.com\tTRUE\t/\tTRUE\t1830000000\tSAPISID\tFAKE-sapisid\n"
                   "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1830000000\t__Secure-3PAPISID\tFAKE-3p\n"
                   ".youtube.com\tTRUE\t/\tTRUE\t1830000000\t__Secure-1PAPISID\tFAKE-1p\n"
                   ".example.com\tTRUE\t/\tTRUE\t1830000000\tSAPISID\tFAKE-other\n"))
          (let ((cookies (yt-subscribe--read-sid-cookies file)))
            (should (equal (sort (mapcar #'car cookies) #'string<)
                           '("SAPISID" "__Secure-1PAPISID" "__Secure-3PAPISID")))
            (should (equal (yt-subscribe--authorization cookies 1793500000)
                           (concat "SAPISIDHASH 1793500000_b3d149290e7d1c7f1df8e4b70c66b660c76529df "
                                   "SAPISID1PHASH 1793500000_37db15d69bc7caa847f3712de6289ed66b2a2b23 "
                                   "SAPISID3PHASH 1793500000_af0d2ed52b93a3fa119362cc0dae586ce05c1de6")))
            ;; Without SAPISID, __Secure-3PAPISID stands in for it.
            (should (string-prefix-p
                     "SAPISIDHASH 1793500000_af0d2ed52b93a3fa119362cc0dae586ce05c1de6 "
                     (yt-subscribe--authorization (assoc-delete-all "SAPISID" cookies)
                                                  1793500000)))
            (should-not (yt-subscribe--authorization nil 1793500000))))
      (delete-file file)))
  (should (equal (yt-subscribe--quote "a\"b\\c") "\"a\\\"b\\\\c\""))
  (should (yt-subscribe--channel-id-p yt-subscribe-test--id))
  (should-not (yt-subscribe--channel-id-p "https://www.youtube.com/@fake")))

(ert-deftest yt-subscribe-request-and-cache ()
  "Subscribing sends the request with a private cookie copy and updates yt."
  (yt-subscribe-test--with (_export curl)
    (yt-cache-put-channels (list (yt-subscribe-test--channel yt-subscribe-test--other)))
    (yt-cache-set-meta "refreshed:channels" 1793400000)
    (yt-subscribe-test--respond curl 1 200 'yes)
    (let (changes)
      (add-hook 'yt-subscriptions-changed-functions
                (lambda (channel subscribed) (push (list (plist-get channel :id) subscribed) changes)))
      (with-current-buffer (get-buffer-create "*yt: Channel 2*")
        (yt-feed-mode)
        (setq yt-feed--source (list 'channel yt-subscribe-test--id
                                    (format "https://www.youtube.com/channel/%s" yt-subscribe-test--id)
                                    "Channel 2"))
        (should (string-match-p "+ subscribes" (yt-feed--header-line)))
        (cl-letf (((symbol-function 'yt-subscribe--offer-browser)
                   (lambda (&rest args) (ert-fail (list "Offered the browser" args)))))
          (call-interactively #'yt-feed-add)
          (yt-test-wait-until (lambda () changes) "subscription"))
        (should (string-match-p "subscribed" (yt-feed--header-line))))
      (should (equal changes (list (list yt-subscribe-test--id t))))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) (yt-cache-channels))
                     (list yt-subscribe-test--id yt-subscribe-test--other)))
      (should-not (memq 'subscriptions yt-feed--fully-refreshed))
      (should (eq (yt-auth-state) 'ok)))
    (let ((config (yt-test-file-string (expand-file-name "config-01" curl)))
          (calls (yt-test-file-string (expand-file-name "calls" curl))))
      (should (string-match-p
               "^url = \"https://www.youtube.com/youtubei/v1/subscription/subscribe\\?prettyPrint=false\"$"
               config))
      (should (string-match-p
               "^header = \"Authorization: SAPISIDHASH 1793500000_b3d149290e7d1c7f1df8e4b70c66b660c76529df\"$"
               config))
      (should (string-match-p "^header = \"X-Origin: https://www.youtube.com\"$" config))
      (should (string-match-p
               (regexp-quote (format "\\\"channelIds\\\":[\\\"%s\\\"]" yt-subscribe-test--id))
               config))
      (should (string-match-p "FAKE-sapisid"
                              (yt-test-file-string (expand-file-name "cookies-01" curl))))
      ;; Neither the cookies nor the hash are in the process list.
      (should-not (string-match-p "FAKE\\|SAPISID\\|youtube" calls))
      (should (string-match-p "--proto =https" calls)))
    ;; The cookie copy and the config are deleted.
    (should-not (directory-files (yt-ensure-runtime-directory) nil "\\`\\(curl\\|cookies\\)-"))))

(ert-deftest yt-subscribe-unsubscribe-removes-videos ()
  "Unsubscribing removes the channel and its videos from yt's buffers."
  (yt-subscribe-test--with (_export curl)
    (yt-cache-put-channels (list (yt-subscribe-test--channel yt-subscribe-test--id)
                                 (yt-subscribe-test--channel yt-subscribe-test--other)))
    (yt-cache-set-meta "refreshed:channels" 1793500000)
    (yt-cache-put-feed "subscriptions"
                       (list (yt-subscribe-test--video "fakevideo01" yt-subscribe-test--id)
                             (yt-subscribe-test--video "fakevideo02" yt-subscribe-test--other)
                             (yt-subscribe-test--video "fakevideo03" yt-subscribe-test--id)))
    (yt-cache-set-meta "refreshed:subscriptions" 1793500000)
    (yt-subscribe-test--respond curl 1 200 'no)
    (let ((feed (yt-feed-subscriptions))
          prompts)
      (with-current-buffer feed
        (should (equal (yt-feed--printed-ids) '("fakevideo01" "fakevideo02" "fakevideo03"))))
      (with-current-buffer (yt-channels)
        (should (equal (yt-feed--printed-ids)
                       (list yt-subscribe-test--id yt-subscribe-test--other)))
        (goto-char (point-min))
        (while (not (equal (tabulated-list-get-id) yt-subscribe-test--id))
          (forward-line 1))
        (should (eq (keymap-lookup yt-channels-mode-map "-") #'yt-channels-unsubscribe))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt prompts) t)))
          (call-interactively #'yt-channels-unsubscribe))
        (should (equal prompts '("Unsubscribe from Channel 2? ")))
        (yt-test-wait-until (lambda () (not (yt-cache-subscribed-p yt-subscribe-test--id)))
                            "unsubscribe")
        (should (equal (yt-feed--printed-ids) (list yt-subscribe-test--other))))
      (should (string-match-p "subscription/unsubscribe\\?"
                              (yt-test-file-string (expand-file-name "config-01" curl))))
      (should (equal (mapcar #'yt-video-id (yt-cache-feed "subscriptions")) '("fakevideo02")))
      (with-current-buffer feed
        (should (equal (yt-feed--printed-ids) '("fakevideo02")))))))

(ert-deftest yt-subscribe-expired-session-retries ()
  "A 401 exports the cookies again and sends the request once more."
  (yt-subscribe-test--with (export curl)
    (let ((yt-cookie-profile "Profile 1")
          done)
      (yt-test-step export 1 :out (yt-test-export-summary) :cookies (yt-test-cookies))
      (yt-subscribe-test--respond curl 1 401)
      (yt-subscribe-test--respond curl 2 200 'yes)
      (yt-subscribe--request 'subscribe yt-subscribe-test--id
                             :on-success (lambda () (setq done 'ok))
                             :on-error (lambda (message) (setq done message)))
      (yt-test-wait-until (lambda () done) "retried request")
      (should (eq done 'ok))
      (should (= (yt-test-calls export) 1))
      (should (= (yt-subscribe-test--api-calls curl) 2))
      ;; A second 401 is not retried again.
      (setq done nil)
      (yt-subscribe-test--respond curl 3 401)
      (yt-subscribe--request 'subscribe yt-subscribe-test--id
                             :on-success (lambda () (setq done 'ok))
                             :on-error (lambda (message) (setq done message))
                             :retried t)
      (yt-test-wait-until (lambda () done) "expired request")
      (should (string-match-p "session has expired" done))
      (should (eq (yt-auth-state) 'expired)))))

(ert-deftest yt-subscribe-refused-offers-browser ()
  "When YouTube refuses, or the channel id is unknown, offer Chromium."
  (yt-subscribe-test--with (_export curl)
    (let (prompts browsed)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt prompts) t))
                ((symbol-function 'yt-subscribe-browse) (lambda (url) (push url browsed))))
        (yt-subscribe-test--respond curl 1 400)
        (yt-subscribe yt-subscribe-test--id "https://www.youtube.com/channel/x" "Channel 2")
        (yt-test-wait-until (lambda () browsed) "browser")
        (should (string-match-p "HTTP 400: Error subscribing, try again).  Open Channel 2 in Chromium to subscribe there"
                                (car prompts)))
        (should (equal browsed '("https://www.youtube.com/channel/x")))
        (should-not (yt-cache-channels))
        ;; A channel known only by its URL is not sent to YouTube.
        (yt-subscribe "https://www.youtube.com/@fake" "https://www.youtube.com/@fake" "Fake")
        (should (equal (car browsed) "https://www.youtube.com/@fake"))
        (should (= (yt-subscribe-test--api-calls curl) 1))
        ;; A contradicting confirmation is a failure too.
        (yt-subscribe-test--respond curl 2 200 'no)
        (yt-subscribe yt-subscribe-test--id "https://www.youtube.com/channel/x" "Channel 2")
        (yt-test-wait-until (lambda () (= (length browsed) 3)) "browser")
        (should (string-match-p "did not change" (car prompts)))
        (should-not (yt-cache-channels))))))

(ert-deftest yt-subscribe-rate-limit-backs-off ()
  "A 429 stops further requests for a while."
  (yt-subscribe-test--with (_export curl)
    (let (done)
      (yt-subscribe-test--respond curl 1 429)
      (dotimes (_ 2)
        (setq done nil)
        (yt-subscribe--request 'subscribe yt-subscribe-test--id
                               :on-success #'ignore
                               :on-error (lambda (message) (setq done message)))
        (yt-test-wait-until (lambda () done) "rate limit"))
      (should (string-match-p "waiting until" done))
      (should (= (yt-subscribe-test--api-calls curl) 1)))))

(ert-deftest yt-subscribe-browse-uses-the-profile ()
  "Chromium opens the URL in yt's profile, on the frame's display."
  (yt-subscribe-test--with (_export _curl)
    (let ((yt-cookie-profile "Profile 1")
          (yt-chromium-program "fake-chromium")
          call)
      (cl-letf (((symbol-function 'call-process)
                 (lambda (&rest args)
                   (setq call (list args (getenv "WAYLAND_DISPLAY")))
                   0))
                ((symbol-function 'yt-player-display-environment)
                 (lambda () '("WAYLAND_DISPLAY=wayland-9"))))
        (yt-subscribe-browse "https://www.youtube.com/@fake"))
      (should (equal call
                     (list (list "fake-chromium" nil 0 nil
                                 (concat "--user-data-dir=" yt-chromium-directory)
                                 "--profile-directory=Profile 1"
                                 "--" "https://www.youtube.com/@fake")
                           "wayland-9"))))))

(ert-deftest yt-subscribe-feed-keys ()
  "+ and - save and forget a playlist, and act on the channel elsewhere."
  (yt-subscribe-test--with (_export _curl)
    (let (calls)
      (cl-letf (((symbol-function 'yt-subscribe) (lambda (&rest args) (push (cons 'sub args) calls)))
                ((symbol-function 'yt-unsubscribe) (lambda (&rest args) (push (cons 'unsub args) calls))))
        (with-temp-buffer
          (yt-feed-mode)
          (setq yt-feed--source (list 'channel yt-subscribe-test--id "https://x/c" "Channel 2"))
          (should (eq (keymap-lookup yt-feed-mode-map "+") #'yt-feed-add))
          (should (eq (keymap-lookup yt-feed-mode-map "-") #'yt-feed-remove))
          (yt-feed-add)
          (yt-feed-remove)
          (setq yt-feed--source (list 'playlist "PLfake" "https://x/p" "Fake"))
          (yt-feed-add)
          (should (yt-cache-playlist-saved-p "PLfake"))
          (yt-feed-remove)
          (should-not (yt-cache-playlist-saved-p "PLfake"))))
      (should (equal (nreverse calls)
                     (list (list 'sub yt-subscribe-test--id "https://x/c" "Channel 2")
                           (list 'unsub yt-subscribe-test--id "https://x/c" "Channel 2" t)))))))

(provide 'yt-subscribe-tests)
;;; yt-subscribe-tests.el ends here
