;;; yt-subscribe.el --- Subscribe to channels -*- lexical-binding: t; -*-

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

;; `yt-subscribe' and `yt-unsubscribe' change your YouTube
;; subscriptions.  yt-dlp only reads from YouTube, so yt sends the
;; request that the Subscribe button of youtube.com sends to YouTube's
;; internal API itself, with curl.  curl gets a private copy of the
;; cookie file, like yt-dlp, and a config file in the runtime directory
;; holding the request headers, so that neither the cookies nor the
;; authorization header derived from them appear in the process list.
;; Both files are deleted when curl exits.
;;
;; The API is not documented and may change.  When a request fails, yt
;; offers to open the channel in the Chromium profile it signs in with,
;; to subscribe there.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yt)
(require 'yt-process)
(require 'yt-ytdlp)
(require 'yt-auth)
(require 'yt-cache)
(require 'yt-player)
(require 'yt-feed)

(defvar yt-subscribe-client-version "2.20260708.00.00"
  "The version of YouTube's web client that the requests name.")

(defvar yt-subscribe-user-agent
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  "The User-Agent header of the requests.")

(defconst yt-subscribe--origin "https://www.youtube.com"
  "The origin of the requests, which the authorization hash covers.")

(defconst yt-subscribe--sid-cookies
  '("SAPISID" "__Secure-1PAPISID" "__Secure-3PAPISID")
  "The cookies from which the authorization header is computed.")

;;;; The request

(defun yt-subscribe--channel-id-p (id)
  "Return non-nil if ID is a YouTube channel id."
  (and (stringp id) (string-match-p "\\`UC[[:alnum:]_-]\\{22\\}\\'" id)))

(defun yt-subscribe--read-sid-cookies (file)
  "Return an alist (NAME . VALUE) of the SAPISID cookies in FILE.
FILE is a Netscape cookie file; only youtube.com cookies count."
  (with-temp-buffer
    (insert-file-contents file)
    (let (cookies)
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((fields (split-string (string-remove-prefix "#HttpOnly_" line) "\t")))
          (when (and (= (length fields) 7)
                     (string-suffix-p "youtube.com" (car fields))
                     (member (nth 5 fields) yt-subscribe--sid-cookies))
            (push (cons (nth 5 fields) (nth 6 fields)) cookies))))
      cookies)))

(defun yt-subscribe--authorization (cookies time)
  "Return the Authorization header for COOKIES at TIME, or nil.
COOKIES is an alist from `yt-subscribe--read-sid-cookies'.  The
header is what YouTube's web client sends: for each SAPISID cookie,
TIME and a SHA-1 hash of TIME, the cookie and the origin."
  (let ((sapisid (or (cdr (assoc "SAPISID" cookies))
                     (cdr (assoc "__Secure-3PAPISID" cookies)))))
    (when sapisid
      (string-join
       (cl-loop for (scheme . value)
                in `(("SAPISIDHASH" . ,sapisid)
                     ("SAPISID1PHASH" . ,(cdr (assoc "__Secure-1PAPISID" cookies)))
                     ("SAPISID3PHASH" . ,(cdr (assoc "__Secure-3PAPISID" cookies))))
                when value
                collect (format "%s %d_%s" scheme time
                                (secure-hash 'sha1 (format "%d %s %s" time value
                                                           yt-subscribe--origin))))
       " "))))

(defun yt-subscribe--quote (string)
  "Return STRING as a quoted value of a curl config file."
  (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" string) "\""))

(defun yt-subscribe--write-config (action channel-id cookie-file authorization)
  "Write a curl config file for ACTION on CHANNEL-ID and return its name.
ACTION is `subscribe' or `unsubscribe'.  The request sends the
cookies in COOKIE-FILE and the header AUTHORIZATION.  The file is
created with mode 0600 in the runtime directory."
  (let ((file (with-file-modes #o600
                (make-temp-file (expand-file-name "curl-" (yt-ensure-runtime-directory))
                                nil ".conf")))
        (body (json-serialize
               `(:context (:client (:clientName "WEB"
                                    :clientVersion ,yt-subscribe-client-version
                                    :hl "en"))
                 :channelIds [,channel-id]))))
    (with-temp-file file
      (insert "url = " (yt-subscribe--quote
                        (format "%s/youtubei/v1/subscription/%s?prettyPrint=false"
                                yt-subscribe--origin action))
              "\n")
      (insert "cookie = " (yt-subscribe--quote cookie-file) "\n")
      (dolist (header `(("Content-Type" . "application/json")
                        ("Authorization" . ,authorization)
                        ("Origin" . ,yt-subscribe--origin)
                        ("X-Origin" . ,yt-subscribe--origin)
                        ("X-Goog-AuthUser" . "0")
                        ("X-YouTube-Client-Name" . "1")
                        ("X-YouTube-Client-Version" . ,yt-subscribe-client-version)
                        ("User-Agent" . ,yt-subscribe-user-agent)))
        (insert "header = " (yt-subscribe--quote (format "%s: %s" (car header) (cdr header)))
                "\n"))
      (insert "data-binary = " (yt-subscribe--quote body) "\n"))
    file))

(defun yt-subscribe--parse-response (output)
  "Return (STATUS . JSON) for the OUTPUT of curl.
STATUS is the HTTP status, which curl prints after the body, and
JSON the body as a plist, with false as `:false', or nil."
  (if (string-match "\n\\([0-9]\\{3\\}\\)\\'" output)
      (cons (string-to-number (match-string 1 output))
            (condition-case nil
                (json-parse-string (substring output 0 (match-beginning 0))
                                   :object-type 'plist :array-type 'list
                                   :null-object nil :false-object :false)
              (json-error nil)))
    (cons 0 nil)))

(defun yt-subscribe--confirmed (json)
  "Return the subscription state YouTube reports in JSON.
That is t for subscribed, `:false' for not subscribed, or nil if
the response does not say."
  (cl-loop for action in (plist-get json :actions)
           for update = (plist-get action :updateSubscribeButtonAction)
           when update return (plist-get update :subscribed)))

(defun yt-subscribe--error-message (status json)
  "Return a message for a failed request with STATUS and the body JSON."
  (let ((detail (plist-get (plist-get json :error) :message)))
    (format "YouTube refused the request (HTTP %d%s)" status
            (if detail (format ": %s" detail) ""))))

(cl-defun yt-subscribe--request (action channel-id &key on-success on-error retried)
  "Send YouTube the request ACTION, `subscribe' or `unsubscribe', for CHANNEL-ID.
Call ON-SUCCESS with no arguments once YouTube confirmed it, or
ON-ERROR with a message.  When the session has expired, the cookies
are exported again and the request is sent once more; RETRIED is
for internal use."
  (let ((master (yt-auth-cookie-file))
        (backoff (yt-auth--backing-off)))
    (cond
     (backoff
      (yt-process-deliver on-error
                          (format "%s (waiting until %s)"
                                  (yt-ytdlp-error-message (car backoff))
                                  (format-time-string "%H:%M" (cdr backoff)))))
     ((not (file-exists-p master))
      (yt-auth--set-state 'no-cookies)
      (yt-process-deliver on-error (yt-ytdlp-error-message 'no-cookies)))
     (t
      (let* ((copy (yt-auth--copy-cookies master))
             (authorization (yt-subscribe--authorization
                             (yt-subscribe--read-sid-cookies copy)
                             (truncate (yt--now))))
             (config (and authorization
                          (yt-subscribe--write-config action channel-id copy authorization)))
             (cleanup (lambda ()
                        (ignore-errors (delete-file copy))
                        (when config
                          (ignore-errors (delete-file config)))))
             (retry (lambda ()
                      (yt-subscribe--request action channel-id :on-success on-success
                                             :on-error on-error :retried t))))
        (if (not config)
            (progn (funcall cleanup)
                   (yt-auth--set-state 'expired)
                   (yt-process-deliver on-error (yt-ytdlp-error-message 'expired)))
          (unless (yt-process-run
                   yt-curl-program
                   (list "--silent" "--show-error" "--proto" "=https" "--max-time" "20"
                         "--write-out" "\n%{http_code}" "--config" config)
                   :parse nil :key (list 'yt-subscribe channel-id) :timeout 30
                   :on-success
                   (lambda (output _info)
                     (funcall cleanup)
                     (yt-subscribe--handle-response action output retried retry
                                                    on-success on-error))
                   :on-error
                   (lambda (err)
                     (funcall cleanup)
                     (funcall on-error
                              (if (eq (plist-get err :type) 'missing)
                                  (format "%s not found: install curl or set `yt-curl-program'"
                                          yt-curl-program)
                                (format "curl failed: %s"
                                        (string-trim (or (plist-get err :stderr)
                                                         (format "%s" (plist-get err :type)))))))))
            (funcall cleanup))))))))

(defun yt-subscribe--handle-response (action output retried retry on-success on-error)
  "Handle the OUTPUT of curl for the request ACTION.
RETRIED is non-nil if the request was already sent again, and RETRY
sends it again.  ON-SUCCESS and ON-ERROR are as for
`yt-subscribe--request'."
  (pcase-let ((`(,status . ,json) (yt-subscribe--parse-response output)))
    (cond
     ((= status 200)
      (let ((confirmed (yt-subscribe--confirmed json)))
        (if (or (null confirmed)
                (eq (eq confirmed t) (eq action 'subscribe)))
            (progn (yt-auth--set-state 'ok)
                   (funcall on-success))
          (funcall on-error "YouTube did not change the subscription"))))
     ((= status 401)
      (if (and (not retried) (yt-auth-profile))
          (yt-auth-export (lambda (ok _result)
                            (if ok
                                (funcall retry)
                              (yt-auth--set-state 'expired)
                              (funcall on-error (yt-ytdlp-error-message 'expired)))))
        (yt-auth--set-state 'expired)
        (funcall on-error (yt-ytdlp-error-message 'expired))))
     ((= status 429)
      (yt-auth--set-state 'rate-limit)
      (yt-auth--start-backoff 'rate-limit)
      (funcall on-error (yt-ytdlp-error-message 'rate-limit)))
     (t
      (funcall on-error (yt-subscribe--error-message status json))))))

;;;; Opening the channel in Chromium

(defun yt-subscribe-browse (url)
  "Open URL in Chromium, in the profile yt signs in with.
That profile is signed in to your YouTube account, unlike the
browser `browse-url' may choose."
  (interactive (list (nth 1 (yt-channel-at-point))))
  (unless (yt-url-parse url)
    (user-error "Not a YouTube link: %s" url))
  (let ((profile (or (yt-auth-profile)
                     (user-error "No Chromium profile chosen: run M-x yt-login")))
        (process-environment (append (yt-player-display-environment)
                                     process-environment)))
    (condition-case nil
        (call-process yt-chromium-program nil 0 nil
                      (concat "--user-data-dir=" (expand-file-name yt-chromium-directory))
                      (concat "--profile-directory=" profile)
                      ;; Nothing after this is read as an option.
                      "--" url)
      (file-error
       (user-error "%s not found: set `yt-chromium-program'" yt-chromium-program)))))

(defun yt-subscribe--offer-browser (channel message action)
  "Show MESSAGE, and offer to open CHANNEL in Chromium to do ACTION there."
  (when (y-or-n-p (format "%s.  Open %s in Chromium to %s there? "
                          message (plist-get channel :name) action))
    (yt-subscribe-browse (plist-get channel :url))))

;;;; Commands

(defun yt-subscribe--change (action channel)
  "Do ACTION, `subscribe' or `unsubscribe', for CHANNEL, a plist.
On success update the cache, which updates the yt buffers."
  (let ((id (plist-get channel :id))
        (name (plist-get channel :name)))
    (if (not (yt-subscribe--channel-id-p id))
        (yt-subscribe--offer-browser channel "The id of this channel is not known" action)
      (message "%s %s…" (if (eq action 'subscribe) "Subscribing to" "Unsubscribing from")
               name)
      (yt-subscribe--request
       action id
       :on-success
       (lambda ()
         (if (eq action 'subscribe)
             (yt-cache-add-channel channel)
           (yt-cache-remove-channel channel))
         (message "%s %s" (if (eq action 'subscribe) "Subscribed to" "Unsubscribed from")
                  name))
       :on-error
       (lambda (message)
         (yt-subscribe--offer-browser channel message action))))))

;;;###autoload
(defun yt-subscribe (id url name)
  "Subscribe to the channel NAME with ID and page URL.
Interactively, the channel of the video at point, of the channel
buffer, or at point in the channels list.  If YouTube refuses,
offer to open the channel in Chromium instead."
  (interactive (yt-channel-at-point))
  (yt-subscribe--change 'subscribe (list :id id :name name :url url)))

;;;###autoload
(defun yt-unsubscribe (id url name &optional confirm)
  "Unsubscribe from the channel NAME with ID and page URL.
Interactively, the channel of the video at point, of the channel
buffer, or at point in the channels list.  With CONFIRM non-nil, as
interactively, ask first.  Its videos leave the subscription feed."
  (interactive (append (yt-channel-at-point) '(t)))
  (when (or (not confirm)
            (y-or-n-p (format "Unsubscribe from %s? " name)))
    (yt-subscribe--change 'unsubscribe (list :id id :name name :url url))))

(provide 'yt-subscribe)
;;; yt-subscribe.el ends here
