;;; yt-playlists-tests.el --- Tests for channel and saved playlists -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for listing a channel's playlists, opening one in playlist
;; order, saving and forgetting playlists, and the saved list.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-playlists)
(require 'yt-channels)

(defmacro yt-playlists-test--with (ytdlp &rest body)
  "Run BODY in a scenario with cookies; YTDLP is the fake yt-dlp's directory."
  (declare (indent 1))
  `(yt-test-with-scenario (,ytdlp _export)
     (ignore _export)
     (yt-test-install-cookies)
     (let ((yt--now-function (lambda () 1793500000))
           (yt-feed-refresh-interval 900))
       (unwind-protect
           (save-window-excursion ,@body)
         (dolist (buffer (buffer-list))
           (when (string-prefix-p "*yt: " (buffer-name buffer))
             (kill-buffer buffer)))))))

(defun yt-playlists-test--wait (buffer)
  "Wait until BUFFER, a playlists or feed buffer, is not fetching."
  (yt-test-wait-until
   (lambda () (not (or (buffer-local-value 'yt-list--refreshing buffer)
                       (buffer-local-value 'yt-feed--refreshing buffer))))
   "fetch")
  buffer)

(defun yt-playlists-test--goto (id)
  "Move point to the row of ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
    (forward-line 1))
  (should (equal (tabulated-list-get-id) id)))

(defconst yt-playlists-test--channel
  '("UCfakechannel00000000002" "https://www.youtube.com/channel/UCfakechannel00000000002"
    "Fake Channel Two")
  "The channel of the playlist fixtures.")

(ert-deftest yt-playlists-args ()
  "Playlists come from the channel's playlists tab, videos from the playlist."
  (should (equal (yt-ytdlp-channel-playlists-args "https://www.youtube.com/channel/UC1/")
                 '("--flat-playlist" "-J" "--" "https://www.youtube.com/channel/UC1/playlists")))
  (should (equal (last (yt-ytdlp-playlist-args "https://www.youtube.com/playlist?list=PL1" 300) 4)
                 '("youtubetab:approximate_date" "-j" "--"
                   "https://www.youtube.com/playlist?list=PL1"))))

(ert-deftest yt-playlists-cache ()
  "Saved playlists keep their fields, newest first, and can be forgotten."
  (yt-test-with-scenario (_ _)
    (let ((yt--now-function (lambda () 100)))
      (yt-cache-save-playlist '(:id "PL1" :title "One" :url "https://x/1" :secret "no")))
    (let ((yt--now-function (lambda () 200)))
      (yt-cache-save-playlist '(:id "PL2" :title "Two" :channel "C" :url "https://x/2")))
    (should (equal (yt-cache-saved-playlists)
                   '((:id "PL2" :title "Two" :channel "C" :url "https://x/2")
                     (:id "PL1" :title "One" :url "https://x/1"))))
    (should (yt-cache-playlist-saved-p "PL1"))
    (yt-cache-forget-playlist "PL1")
    (should-not (yt-cache-playlist-saved-p "PL1"))
    (should (= (length (yt-cache-saved-playlists)) 1))))

(ert-deftest yt-playlists-channel-list-open-and-save ()
  "A channel's playlists list, open in playlist order, and save with +."
  (yt-playlists-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "channel-playlists.json"))
    (yt-test-step ytdlp 2 :mode "stream" :out (yt-test-fixture-string "playlist.ndjson"))
    (with-current-buffer (yt-playlists-test--wait
                          (apply #'yt-channel-playlists yt-playlists-test--channel))
      (should (equal (buffer-name) "*yt: Fake Channel Two playlists*"))
      (should (equal (yt-feed--printed-ids)
                     '("PLfakeplaylist000000000001" "PLfakeplaylist000000000002")))
      (should (string-match-p "Fake series one +Fake Channel Two" (buffer-string)))
      (should (equal (car (last (yt-test-argv ytdlp 1)))
                     "https://www.youtube.com/channel/UCfakechannel00000000002/playlists"))
      (yt-playlists-test--goto "PLfakeplaylist000000000002")
      (call-interactively #'yt-playlists-save)
      (should (yt-cache-playlist-saved-p "PLfakeplaylist000000000002"))
      (yt-playlists-test--goto "PLfakeplaylist000000000002")
      (should (looking-at-p "★"))
      (yt-playlists-test--goto "PLfakeplaylist000000000001")
      (call-interactively #'yt-playlists-open))
    (with-current-buffer (yt-playlists-test--wait (get-buffer "*yt: Playlist: Fake series one*"))
      ;; Playlist order, not newest first.
      (should (equal (yt-feed--printed-ids) '("fakeplvid01" "fakeplvid02" "fakeplvid03")))
      (should (equal (car (last (yt-test-argv ytdlp 2)))
                     "https://www.youtube.com/playlist?list=PLfakeplaylist000000000001"))
      (should (string-match-p "saves this playlist" (yt-feed--header-line)))
      (should (eq (keymap-lookup yt-feed-mode-map "+") #'yt-feed-add))
      (yt-feed-save-playlist)
      (should (string-match-p "saved playlist" (yt-feed--header-line)))
      (should (equal (car (yt-cache-saved-playlists))
                     '(:id "PLfakeplaylist000000000001" :title "Fake series one"
                           :channel "Fake Channel Two" :channel-id "UCfakechannel00000000002"
                           :url "https://www.youtube.com/playlist?list=PLfakeplaylist000000000001"))))))

(ert-deftest yt-playlists-refetch-replaces-the-playlist ()
  "A playlist fetched again shows exactly its current videos."
  (yt-playlists-test--with ytdlp
    (yt-test-step ytdlp 1 :out (yt-test-fixture-string "playlist.ndjson"))
    (yt-test-step ytdlp 2 :out (car (last (split-string (yt-test-fixture-string "playlist.ndjson")
                                                        "\n" t))))
    (with-current-buffer (yt-playlists-test--wait
                          (yt-feed-playlist "PLfakeplaylist000000000001"
                                            "https://www.youtube.com/playlist?list=PLfakeplaylist000000000001"
                                            "Fake series one"))
      (should (= (length (yt-feed--printed-ids)) 3))
      (yt-feed-refresh)
      (yt-playlists-test--wait (current-buffer))
      (should (equal (yt-feed--printed-ids) '("fakeplvid03")))
      (should (equal (mapcar #'yt-video-id (yt-cache-feed "playlist:PLfakeplaylist000000000001"))
                     '("fakeplvid03"))))
    ;; + outside a playlist explains itself.
    (with-temp-buffer
      (yt-feed-mode)
      (setq yt-feed--source 'subscriptions)
      (should-error (yt-feed-save-playlist) :type 'user-error))))

(ert-deftest yt-playlists-saved-list ()
  "The saved list shows saved playlists with unwatched counts, and forgets."
  (yt-playlists-test--with ytdlp
    (yt-cache-save-playlist '(:id "PLfakeplaylist000000000001" :title "Fake series one"
                                  :channel "Fake Channel Two"
                                  :url "https://www.youtube.com/playlist?list=PLfakeplaylist000000000001"))
    (yt-cache-put-feed "playlist:PLfakeplaylist000000000001"
                       (mapcar (lambda (line) (yt-video-from-json (yt-process-parse-json line) t))
                               (split-string (yt-test-fixture-string "playlist.ndjson") "\n" t))
                       t)
    (yt-mark-watched "fakeplvid01")
    (should (eq (keymap-lookup yt-map "P") #'yt-saved-playlists))
    (with-current-buffer (yt-saved-playlists)
      (should (equal (yt-feed--printed-ids) '("PLfakeplaylist000000000001")))
      (should (string-match-p "★ Fake series one +Fake Channel Two +2" (buffer-string)))
      (yt-playlists-test--goto "PLfakeplaylist000000000001")
      (call-interactively #'yt-playlists-forget)
      (should-not (yt-feed--printed-ids))
      (should (string-match-p "No saved playlists" (buffer-string))))
    (should (= (yt-test-calls ytdlp) 0))))

(ert-deftest yt-playlists-shuffle-keys ()
  "\`z' shuffles the shown videos of a feed, and a playlist from the list."
  (yt-playlists-test--with ytdlp
    (let (shuffled)
      (cl-letf (((symbol-function 'yt-player-shuffle)
                 (lambda (videos &optional name)
                   (setq shuffled (list (mapcar #'yt-video-id videos) name)))))
        (yt-test-step ytdlp 1 :out (yt-test-fixture-string "channel-playlists.json"))
        (yt-test-step ytdlp 2 :mode "stream" :out (yt-test-fixture-string "playlist.ndjson"))
        (with-current-buffer (yt-playlists-test--wait
                              (apply #'yt-channel-playlists yt-playlists-test--channel))
          (should (eq (keymap-lookup yt-playlists-mode-map "z") #'yt-playlists-shuffle))
          (yt-playlists-test--goto "PLfakeplaylist000000000001")
          ;; Never fetched: the shuffle waits for the videos.
          (call-interactively #'yt-playlists-shuffle)
          (should-not shuffled))
        (yt-test-wait-until (lambda () shuffled) "shuffle after refresh")
        (should (equal shuffled '(("fakeplvid01" "fakeplvid02" "fakeplvid03")
                                  "Fake series one")))
        ;; In the feed, only the videos passing the filter.
        (with-current-buffer "*yt: Playlist: Fake series one*"
          (should (eq (keymap-lookup yt-feed-mode-map "z") #'yt-feed-shuffle))
          (yt-mark-watched "fakeplvid02")
          (yt-feed-toggle-hide-watched)
          (yt-feed-shuffle)
          (should (equal shuffled '(("fakeplvid01" "fakeplvid03") "Fake series one"))))))))

(ert-deftest yt-playlists-from-video-and-channels-list ()
  "\\`O' lists the playlists of the channel at hand."
  (yt-playlists-test--with ytdlp
    (should (eq (keymap-lookup yt-feed-mode-map "O") #'yt-channel-playlists))
    (should (eq (keymap-lookup yt-channels-mode-map "O") #'yt-channel-playlists))
    (with-temp-buffer
      (let* ((video (yt-video--make :id "x" :channel "Fake Channel Two"
                                    :channel-id "UCfakechannel00000000002"))
             (yt-video-at-point-function (lambda () video)))
        (should (equal (yt-channel-at-point) yt-playlists-test--channel))))
    (with-temp-buffer
      (yt-feed-mode)
      (setq yt-feed--source (cons 'channel yt-playlists-test--channel))
      (should (equal (yt-channel-at-point) yt-playlists-test--channel)))
    (with-temp-buffer
      (should-error (yt-channel-at-point) :type 'user-error))))

(provide 'yt-playlists-tests)
;;; yt-playlists-tests.el ends here
