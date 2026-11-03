;;; yt-process.el --- Asynchronous subprocesses for yt -*- lexical-binding: t; -*-

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

;; A small runner for external programs such as yt-dlp.  It never
;; blocks Emacs: `yt-process-run' starts the program and calls back
;; when it is done.  Standard error is collected separately, so
;; warnings cannot corrupt JSON on standard output.  Output can be
;; parsed as one JSON document, as newline-delimited JSON delivered
;; line by line (with early stopping), or returned as a string.
;; Runs can have a timeout, can be cancelled, and can be keyed so
;; that only one run per key is active.
;;
;; This file knows nothing about YouTube.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yt)

(defvar yt-process-kill-grace 5.0
  "Seconds between interrupting a process and killing it.")

(defvar yt-process-stderr-grace 0.5
  "Seconds to wait for standard error to close after a process exits.")

(defvar yt-process--running (make-hash-table :test #'equal)
  "Hash table mapping run keys to their processes.")

(cl-defstruct (yt-process--job (:constructor yt-process--job-create)
                               (:copier nil))
  "State of one `yt-process-run' invocation."
  key parse on-success on-error on-line
  stdout (partial "") (lines 0) (bad-lines 0) stderr-proc
  exited stderr-closed stopped finished outcome timers)

(defun yt-process-parse-json (string)
  "Parse the JSON in STRING the way yt does everywhere.
Objects become plists, arrays become lists, and null and false
become nil."
  (json-parse-string string :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun yt-process-log (format-string &rest args)
  "Append a line made from FORMAT-STRING and ARGS to the *yt-log* buffer."
  (with-current-buffer (get-buffer-create "*yt-log*")
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "%T ") (apply #'format format-string args)
              "\n"))))

(defun yt-process-deliver (fn &rest args)
  "Call FN with ARGS from a timer, unless FN is nil.
Calling from a timer keeps errors in FN out of process sentinels."
  (when fn
    (run-at-time 0 nil (lambda () (apply fn args)))))

(defun yt-process-busy-p (key)
  "Return non-nil if a run with KEY has not finished yet."
  (and key (gethash key yt-process--running) t))

(cl-defstruct (yt-process-queue (:constructor yt-process-queue-create (limit))
                                (:copier nil))
  "A queue that runs at most LIMIT jobs at once.
STARTING is non-nil while the queue starts jobs, so that a job that
is done at once does not start the next one from inside itself."
  limit (running 0) (waiting nil) (starting nil))

(defun yt-process-queue-run (queue job)
  "Run JOB through QUEUE, now if fewer than its limit are running.
JOB is a function called with one argument, a function that JOB must
call once when it is done, successful or not."
  (setf (yt-process-queue-waiting queue)
        (append (yt-process-queue-waiting queue) (list job)))
  (yt-process--queue-next queue))

(defun yt-process--queue-next (queue)
  "Start waiting jobs of QUEUE while it is below its limit.
A job done at once only frees its place; the loop already running
starts the next one."
  (unless (yt-process-queue-starting queue)
    (setf (yt-process-queue-starting queue) t)
    (unwind-protect
        (while (and (yt-process-queue-waiting queue)
                    (< (yt-process-queue-running queue) (yt-process-queue-limit queue)))
          (let ((job (pop (yt-process-queue-waiting queue)))
                (done nil))
            (cl-incf (yt-process-queue-running queue))
            (funcall job (lambda ()
                           (unless done
                             (setq done t)
                             (cl-decf (yt-process-queue-running queue))
                             (yt-process--queue-next queue))))))
      (setf (yt-process-queue-starting queue) nil))))

(cl-defun yt-process-run (program args &key on-success on-error on-line
                                  (parse 'json) timeout key force env
                                  log-args)
  "Run PROGRAM with ARGS asynchronously and return its process.
Return non-nil exactly when one of ON-SUCCESS and ON-ERROR will be
called: t if PROGRAM is missing (ON-ERROR gets :type `missing'), or
nil, with no callback, if a run with KEY is busy.

PARSE says what to do with standard output:
  `json'    parse it as one JSON document when the program exits;
  `ndjson'  parse each line as JSON and call ON-LINE with it as it
            arrives; ON-LINE may return `stop' to end the run early,
            which then counts as a success;
  nil       return it as a string.

ON-SUCCESS is called with the parsed value (nil for `ndjson') and
a plist (:stderr STRING :exit-code N :lines N :stopped BOOL).
ON-ERROR is called with a plist whose :type is one of `exit',
`parse', `timeout', `cancelled' or `missing', plus :stderr,
:stdout and :exit-code where known.  Both are called from a timer.

TIMEOUT is in seconds and defaults to `yt-process-timeout'.  When
KEY is non-nil, only one run per KEY is active: a second run returns
nil and does nothing, unless FORCE is non-nil, in which case the
first run is cancelled.  ENV is a list of \"VAR=VALUE\" strings
added to the environment.  LOG-ARGS, if non-nil, replaces ARGS in
the *yt-log* entry, for arguments that should not be logged."
  (when (yt-process-busy-p key)
    (if force
        (yt-process-cancel key)
      (message "Already running: %s" (file-name-nondirectory program))
      (cl-return-from yt-process-run nil)))
  (let* ((name (format "yt-%s" (file-name-nondirectory program)))
         (job (yt-process--job-create :key key :parse parse
                                      :on-success on-success
                                      :on-error on-error :on-line on-line))
         (process-environment (append env process-environment))
         (stderr (make-pipe-process
                  :name (concat name "-stderr")
                  :buffer (generate-new-buffer (format " *%s-stderr*" name))
                  :coding 'utf-8-unix :noquery t
                  :sentinel #'yt-process--stderr-sentinel))
         proc)
    (setf (yt-process--job-stderr-proc job) stderr)
    (unless (eq parse 'ndjson)
      (setf (yt-process--job-stdout job)
            (generate-new-buffer (format " *%s-stdout*" name))))
    (condition-case err
        (setq proc (make-process :name name :command (cons program args)
                                 :connection-type 'pipe :coding 'utf-8-unix
                                 :noquery t :stderr stderr
                                 :filter #'yt-process--filter
                                 :sentinel #'yt-process--sentinel))
      (file-error
       (yt-process--cleanup job)
       (yt-process-deliver on-error
                           (list :type 'missing :program program
                                 :message (error-message-string err)))
       (cl-return-from yt-process-run t)))
    (process-put proc 'yt-job job)
    (process-put stderr 'yt-main proc)
    (when key
      (puthash key proc yt-process--running))
    (let ((secs (or timeout yt-process-timeout)))
      (when (and secs (> secs 0))
        (push (run-at-time secs nil #'yt-process--stop proc 'timeout)
              (yt-process--job-timers job))))
    (yt-process-log "run %s" (mapconcat #'shell-quote-argument
                                        (cons program (or log-args args)) " "))
    proc))

(defun yt-process-cancel (key-or-process)
  "Cancel the run identified by KEY-OR-PROCESS, a run key or a process.
Its ON-ERROR callback is called with :type `cancelled'.  Return
non-nil if there was a run to cancel."
  (let ((proc (if (processp key-or-process)
                  key-or-process
                (gethash key-or-process yt-process--running))))
    (when-let* ((job (and proc (process-get proc 'yt-job))))
      (when-let* ((key (yt-process--job-key job)))
        (when (eq proc (gethash key yt-process--running))
          (remhash key yt-process--running)))
      (yt-process--stop proc 'cancelled)
      t)))

(defun yt-process--stop (proc outcome)
  "Interrupt PROC and kill it if it is still alive after a grace period.
OUTCOME, if non-nil, is recorded as the reason (`timeout' or
`cancelled') unless a reason was recorded already.  PROC may be
nil, which does nothing; that simplifies testing the filter."
  (when (processp proc)
    (let ((job (process-get proc 'yt-job)))
      (when (and job outcome (not (yt-process--job-outcome job)))
        (setf (yt-process--job-outcome job) outcome))
      (when (process-live-p proc)
        (interrupt-process proc)
        (let ((timer (run-at-time yt-process-kill-grace nil
                                  (lambda ()
                                    (when (process-live-p proc)
                                      (kill-process proc))))))
          (when job
            (push timer (yt-process--job-timers job))))))))

(defun yt-process--filter (proc string)
  "Handle STRING arriving on the standard output of PROC."
  (let ((job (process-get proc 'yt-job)))
    (cond
     ((yt-process--job-stopped job))
     ((eq (yt-process--job-parse job) 'ndjson)
      (yt-process--ndjson-input proc job string))
     ((buffer-live-p (yt-process--job-stdout job))
      (with-current-buffer (yt-process--job-stdout job)
        (goto-char (point-max))
        (insert string))))))

(defun yt-process--ndjson-input (proc job string)
  "Split STRING from PROC into lines and handle the complete ones for JOB.
An incomplete last line is kept until more output arrives.  Nothing
is handled once JOB was stopped."
  (unless (yt-process--job-stopped job)
    (let ((lines (split-string (concat (yt-process--job-partial job) string)
                               "\n")))
      (setf (yt-process--job-partial job) (car (last lines)))
      (catch 'stopped
        (dolist (line (butlast lines))
          (yt-process--ndjson-line proc job line)
          (when (yt-process--job-stopped job)
            (throw 'stopped nil)))))))

(defun yt-process--ndjson-line (proc job line)
  "Parse LINE from PROC as JSON and pass it to JOB's line callback.
If the callback returns `stop', stop JOB and interrupt PROC."
  (unless (string-blank-p line)
    (let ((object (condition-case nil
                      (yt-process-parse-json line)
                    (json-error
                     (cl-incf (yt-process--job-bad-lines job))
                     nil))))
      (when object
        (cl-incf (yt-process--job-lines job))
        (when-let* ((fn (yt-process--job-on-line job)))
          (when (eq 'stop (condition-case err
                              (funcall fn object)
                            (error
                             (message "Error in yt line handler: %s"
                                      (error-message-string err))
                             nil)))
            (setf (yt-process--job-stopped job) t
                  (yt-process--job-partial job) "")
            (yt-process--stop proc nil)))))))

(defun yt-process--sentinel (proc _event)
  "Note that PROC has exited, and finish once standard error is closed."
  (unless (process-live-p proc)
    (let ((job (process-get proc 'yt-job)))
      (setf (yt-process--job-exited job) t)
      (if (yt-process--job-stderr-closed job)
          (yt-process--finish-soon proc)
        (push (run-at-time yt-process-stderr-grace nil
                           #'yt-process--finish proc)
              (yt-process--job-timers job))))))

(defun yt-process--finish-soon (proc)
  "Finish PROC from a timer, not from the sentinel that noticed it.
Finishing deletes the standard error pipe, which runs the sentinels of
other processes that ended meanwhile; from inside a sentinel, those
would nest, and hundreds of runs ending together overflow
`max-lisp-eval-depth'."
  (run-at-time 0 nil #'yt-process--finish proc))

(defun yt-process--stderr-sentinel (stderr _event)
  "Note that the standard error pipe STDERR has closed."
  (unless (process-live-p stderr)
    (when-let* ((proc (process-get stderr 'yt-main))
                (job (process-get proc 'yt-job)))
      (setf (yt-process--job-stderr-closed job) t)
      (when (yt-process--job-exited job)
        (yt-process--finish-soon proc)))))

(defun yt-process--buffer-text (buffer)
  "Return the text of BUFFER, or nil if it is dead."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun yt-process--cleanup (job)
  "Delete the standard error pipe and the buffers of JOB."
  (when-let* ((buffer (yt-process--job-stdout job)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (when-let* ((stderr (yt-process--job-stderr-proc job)))
    (let ((buffer (process-buffer stderr)))
      (delete-process stderr)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun yt-process--finish (proc)
  "Collect the results of PROC and call its callbacks, exactly once."
  (let ((job (process-get proc 'yt-job)))
    (unless (yt-process--job-finished job)
      (setf (yt-process--job-finished job) t)
      (mapc #'cancel-timer (yt-process--job-timers job))
      (let ((key (yt-process--job-key job)))
        (when (and key (eq proc (gethash key yt-process--running)))
          (remhash key yt-process--running)))
      (let (result)
        (unwind-protect
            (progn
              (when (and (eq (yt-process--job-parse job) 'ndjson)
                         (not (yt-process--job-stopped job)))
                (let ((rest (yt-process--job-partial job)))
                  (setf (yt-process--job-partial job) "")
                  (yt-process--ndjson-line proc job rest)))
              (setq result
                    (yt-process--result
                     proc job
                     (yt-process--buffer-text (yt-process--job-stdout job))
                     (or (yt-process--buffer-text
                          (process-buffer (yt-process--job-stderr-proc job)))
                         ""))))
          (yt-process--cleanup job))
        (pcase result
          (`(ok ,value ,info)
           (yt-process-deliver (yt-process--job-on-success job) value info))
          (`(error ,err)
           (yt-process-deliver (yt-process--job-on-error job) err)))))))

(defun yt-process--result (proc job stdout stderr)
  "Return (ok VALUE INFO) or (error PLIST) for the finished PROC and JOB.
STDOUT and STDERR are the collected output."
  (let* ((code (process-exit-status proc))
         (base (list :program (car (process-command proc))
                     :exit-code code :stderr stderr
                     :lines (yt-process--job-lines job))))
    (cond
     ((yt-process--job-outcome job)
      (list 'error (append (list :type (yt-process--job-outcome job)) base)))
     ((yt-process--job-stopped job)
      (list 'ok nil (append (list :stopped t) base)))
     ((not (and (eq (process-status proc) 'exit) (zerop code)))
      (list 'error (append (list :type 'exit :stdout stdout) base)))
     ((eq (yt-process--job-parse job) 'json)
      (condition-case nil
          (list 'ok (yt-process-parse-json stdout) base)
        (json-error
         (list 'error (append (list :type 'parse :stdout stdout) base)))))
     ((eq (yt-process--job-parse job) 'ndjson)
      (list 'ok nil base))
     (t
      (list 'ok stdout base)))))

(provide 'yt-process)
;;; yt-process.el ends here
