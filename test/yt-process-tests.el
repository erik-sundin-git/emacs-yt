;;; yt-process-tests.el --- Tests for yt-process.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Erik Sundin
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the asynchronous process runner, using sh as the program.

;;; Code:

(require 'yt-test-helpers)
(require 'yt-process)

(ert-deftest yt-process-json-with-stderr ()
  "JSON on stdout parses even when stderr has warnings."
  (pcase-let ((`(ok ,value ,info)
               (yt-test-sh "printf '{\"a\":[1,2],\"b\":null,\"c\":false}'; echo 'WARNING: x' >&2")))
    (should (equal value '(:a (1 2) :b nil :c nil)))
    (should (equal (plist-get info :stderr) "WARNING: x\n"))
    (should (= (plist-get info :exit-code) 0))))

(ert-deftest yt-process-raw-output ()
  "PARSE nil returns stdout as a string."
  (pcase-let ((`(ok ,value ,_) (yt-test-sh "echo hello" :parse nil)))
    (should (equal value "hello\n"))))

(ert-deftest yt-process-env ()
  "ENV entries reach the program."
  (pcase-let ((`(ok ,value ,_) (yt-test-sh "printf '{\"v\":\"%s\"}' \"$YT_X\""
                                           :env '("YT_X=hi"))))
    (should (equal value '(:v "hi")))))

(ert-deftest yt-process-ndjson-lines ()
  "NDJSON lines arrive in order; blank and bad lines are skipped.
The last line has no newline and is handled when the program exits."
  (let (seen)
    (pcase-let ((`(ok ,value ,info)
                 (yt-test-sh "printf '{\"n\":1}\\n\\n{\"n\":2}\\nnot json\\n{\"n\":3}'"
                             :parse 'ndjson
                             :on-line (lambda (o) (push (plist-get o :n) seen) nil))))
      (should-not value)
      (should (equal (nreverse seen) '(1 2 3)))
      (should (= (plist-get info :lines) 3))
      (should-not (plist-get info :stopped)))))

(ert-deftest yt-process-ndjson-stop ()
  "Returning `stop' from ON-LINE ends the run, which counts as success."
  (let (seen proc result)
    (setq proc (yt-process-run
                "sh" (list "-c" "i=0; while :; do i=$((i+1)); printf '{\"n\":%d}\\n' $i; sleep 0.02; done")
                :parse 'ndjson
                :on-line (lambda (o)
                           (push (plist-get o :n) seen)
                           (when (= (plist-get o :n) 3) 'stop))
                :on-success (lambda (_ info) (setq result (list 'ok info)))
                :on-error (lambda (err) (setq result (list 'error err)))))
    (yt-test-wait-until (lambda () result))
    (should (eq (car result) 'ok))
    (should (plist-get (cadr result) :stopped))
    (should (equal (nreverse seen) '(1 2 3)))
    (should-not (process-live-p proc))))

(ert-deftest yt-process-ndjson-utf8-split ()
  "A multibyte character split across two writes decodes correctly."
  (let (seen)
    (yt-test-sh "printf '{\"t\":\"caf\\303'; sleep 0.2; printf '\\251\"}\\n'"
                :parse 'ndjson
                :on-line (lambda (o) (push (plist-get o :t) seen) nil))
    (should (equal seen '("café")))))

(ert-deftest yt-process-ndjson-chunks ()
  "The NDJSON filter handles lines split across and merged in chunks.
Lines after a `stop', even in the same chunk, are dropped."
  (let* ((seen nil)
         (job (yt-process--job-create
               :parse 'ndjson
               :on-line (lambda (o)
                          (push (plist-get o :n) seen)
                          (when (= (plist-get o :n) 3) 'stop)))))
    (yt-process--ndjson-input nil job "{\"n\":1}\n{\"n\"")
    (yt-process--ndjson-input nil job "")
    (yt-process--ndjson-input nil job ":2}")
    (should (equal seen '(1)))
    (yt-process--ndjson-input nil job "\n{\"n\":3}\n{\"n\":4}\n")
    (yt-process--ndjson-input nil job "{\"n\":5}\n")
    (should (equal (nreverse seen) '(1 2 3)))
    (should (yt-process--job-stopped job))
    (should (= (yt-process--job-lines job) 3))))

(ert-deftest yt-process-exit-error ()
  "A non-zero exit is an `exit' error with stderr and the exit code."
  (pcase-let ((`(error ,err) (yt-test-sh "echo 'ERROR: boom' >&2; exit 3")))
    (should (eq (plist-get err :type) 'exit))
    (should (= (plist-get err :exit-code) 3))
    (should (equal (plist-get err :stderr) "ERROR: boom\n"))))

(ert-deftest yt-process-parse-error ()
  "Exit 0 with no JSON is a `parse' error."
  (pcase-let ((`(error ,err) (yt-test-sh "true")))
    (should (eq (plist-get err :type) 'parse))))

(ert-deftest yt-process-missing-program ()
  "A program that does not exist is a `missing' error."
  (pcase-let ((`(error ,err) (yt-test-process "yt-no-such-program-anywhere" nil)))
    (should (eq (plist-get err :type) 'missing))))

(ert-deftest yt-process-timeout ()
  "A run that takes too long is interrupted and reported as `timeout'."
  (let ((yt-process-kill-grace 0.5))
    (pcase-let ((`(error ,err) (yt-test-sh "exec sleep 100" :timeout 0.3)))
      (should (eq (plist-get err :type) 'timeout)))))

(ert-deftest yt-process-single-flight-and-cancel ()
  "Only one run per key is active; FORCE cancels the running one."
  (let (first second)
    (should (yt-process-run "sh" '("-c" "exec sleep 100") :key 'yt-test-key
                            :on-error (lambda (err) (setq first err))))
    (should (yt-process-busy-p 'yt-test-key))
    (should-not (yt-process-run "sh" '("-c" "echo '{}'") :key 'yt-test-key))
    (should (yt-process-run "sh" '("-c" "echo '{}'") :key 'yt-test-key :force t
                            :on-success (lambda (value _) (setq second (list value)))))
    (yt-test-wait-until (lambda () (and first second)))
    (should (eq (plist-get first :type) 'cancelled))
    (should (equal second '(nil)))
    (should-not (yt-process-busy-p 'yt-test-key))))

(ert-deftest yt-process-cancel-by-key ()
  "`yt-process-cancel' stops a keyed run and reports `cancelled'."
  (let (err)
    (yt-process-run "sh" '("-c" "exec sleep 100") :key 'yt-test-cancel
                    :on-error (lambda (e) (setq err e)))
    (should (yt-process-cancel 'yt-test-cancel))
    (yt-test-wait-until (lambda () err))
    (should (eq (plist-get err :type) 'cancelled))
    (should-not (yt-process-cancel 'yt-test-cancel))))

(ert-deftest yt-process-queue-of-jobs-that-finish-at-once ()
  "Jobs that call `done' at once do not nest one call per job."
  (let ((queue (yt-process-queue-create 1))
        (ran 0))
    (dotimes (_ 2000)
      (yt-process-queue-run queue (lambda (done) (cl-incf ran) (funcall done))))
    (should (= ran 2000))
    (should (zerop (yt-process-queue-running queue)))))

(ert-deftest yt-process-many-runs-at-once ()
  "Hundreds of runs finishing together do not nest their sentinels."
  (let ((done 0) (failed 0))
    (dotimes (_ 200)
      (yt-process-run "sh" '("-c" "echo '{}'")
                      :on-success (lambda (_ _) (cl-incf done))
                      :on-error (lambda (_) (cl-incf failed))))
    (yt-test-wait-until (lambda () (= (+ done failed) 200)) "200 runs")
    (should (= done 200))))

(ert-deftest yt-process-missing-program-says-a-callback-follows ()
  "A missing program delivers `on-error' and returns non-nil, so that
callers do not clean up twice; a busy key returns nil with no callback."
  (let (errors)
    (should (yt-process-run "yt-test-no-such-program" nil
                            :on-error (lambda (err) (push (plist-get err :type) errors))))
    (yt-test-wait-until (lambda () errors) "missing")
    (should (equal errors '(missing)))
    (let ((first (yt-process-run "sleep" '("10") :key 'yt-test-busy :parse nil
                                 :on-error #'ignore)))
      (unwind-protect
          (should-not (yt-process-run "true" nil :key 'yt-test-busy
                                      :on-success (lambda (&rest _) (push 'called errors))))
        (yt-process-cancel 'yt-test-busy)
        (yt-test-wait-until (lambda () (not (process-live-p first))) "cancel")))
    (should-not (memq 'called errors))))

(ert-deftest yt-process-log-redacts-and-stays-small ()
  "*yt-log* never holds stream URLs or credentials, and keeps a bounded size."
  (with-current-buffer (get-buffer-create "*yt-log*")
    (let ((inhibit-read-only t)) (erase-buffer)))
  (yt-process-log "run mpv https://rr1---fake.googlevideo.com/videoplayback?%s=1"
                  "expire")
  (yt-process-log "header Authorization: SAPISIDHASH 1793500000_abcdef0123")
  (yt-process-log "sent SAPISID3PHASH 1793500000_abcdef0123 and Cookie: SID=FAKE-sid")
  (let ((text (with-current-buffer "*yt-log*" (buffer-string))))
    (should (string-match-p "run mpv <stream URL>" text))
    (should (string-match-p "Authorization: <redacted>" text))
    (should (string-match-p "sent SAPISIDHASH <redacted> and Cookie: <redacted>" text))
    (should-not (string-match-p "googlevideo\\|abcdef0123\\|FAKE-sid" text)))
  (let ((yt-process-log-size 2000))
    (dotimes (n 300)
      (yt-process-log "line %d of the log" n))
    (with-current-buffer "*yt-log*"
      (should (<= (buffer-size) 2100))
      (should (string-match-p "line 299 of the log\n\\'" (buffer-string)))
      (goto-char (point-min))
      (should (looking-at-p "[0-9:.]+ line [0-9]+ of the log")))))

(ert-deftest yt-process-prompts-stay-out-of-savehist ()
  "yt's prompt histories are kept from savehist unless asked otherwise."
  (require 'savehist)
  (let ((savehist-ignored-variables nil))
    (yt-minibuffer-history 'yt-search-history)
    (should (memq 'yt-search-history savehist-ignored-variables))
    (setq savehist-ignored-variables nil)
    (let ((yt-save-minibuffer-history t))
      (yt-minibuffer-history 'yt-search-history))
    (should-not savehist-ignored-variables)))

(provide 'yt-process-tests)
;;; yt-process-tests.el ends here
