(in-package #:acp-backend-stdio/tests)

;;; A real subprocess on every OS: SPAWN-ACP-AGENT runs a child SBCL (this
;;; image's runtime and core, --script tests/fixtures/agent-main.lisp) that
;;; serves the scripted agent on its stdin / stdout. The child loads
;;; acp-backend-stdio first, so its first answer gets *CHILD-START-SECONDS*.

(defun %alive-p (connection)
  (let ((process (stdio:acp-stdio-connection-process connection)))
    (and process (process-protocol:alive-p process))))

(deftest child-full-flow
  (with-child (conn ra :env (("ACP_FIXTURE_VALUE" . "from-the-parent")))
    (ok (typep conn 'stdio:acp-stdio-connection))
    (ok (stdio:acp-stdio-connection-process conn) "the process handle")
    (let ((res (initialize-child ra)))
      (ok (typep res 'acp:initialize-response) "initialize answered by the child")
      (ok (and res (equal "scripted-agent" (acp:name (acp:agent-info res))))))
    (let* ((client (client-remote-owner ra))
           (sid (new-session ra)))
      (setf (gethash "/w/a.txt" (client-files client)) "old")
      ;; the turn: updates, permission (allow_once), fs, terminal; the agent also
      ;; PRINTs to its *standard-output* and logs to stderr
      (multiple-value-bind (res condition finished) (call-within 60 (lambda () (prompt ra sid "work")))
        (ok finished)
        (ok (null condition) (d condition))
        (ok (and res (equal "end_turn" (acp:stop-reason res)))))
      (ok (equal *work-tags* (update-tags client)) (d (update-tags client)))
      (ok (equal "permission allow-once read old" (car (last (update-texts client))))
          "permission and fs read round trips through the child")
      (ok (equal "new" (gethash "/w/a.txt" (client-files client))))
      (ok (equal '("session/request_permission" "fs/read_text_file" "fs/write_text_file"
                   "terminal/create" "terminal/wait_for_exit" "terminal/release")
                 (client-calls client)))
      ;; the environment
      (prompt ra sid "env")
      (ok (equal "from-the-parent" (car (last (update-texts client)))) "ENV reached the child")
      ;; non-ASCII through the child's real stdin / stdout
      (let ((text "héllo ✓ 日本"))
        (prompt ra sid (concatenate 'string "text:" text))
        (ok (equal text (car (last (update-texts client)))) "UTF-8 both ways"))
      ;; cancel a running prompt
      (let ((turn (in-background (lambda () (prompt ra sid "wait")))))
        (ok (wait-until 30 (lambda () (equal "waiting" (car (last (update-texts client)))))))
        (cancel ra sid)
        (ok (await turn 30) "session/cancel ends the child's turn")
        (let ((r (first (outcome-values turn))))
          (ok (and r (equal "cancelled" (acp:stop-reason r))) (d (outcome-condition turn))))))
    ;; a clean exit at EOF
    (multiple-value-bind (code condition finished)
        (call-within 30 (lambda () (stdio:close-acp-connection conn :timeout 10)))
      (ok finished "close returns")
      (ok (null condition) (d condition))
      (ok (eql 0 code) "the child exits 0 at EOF"))
    (ok (not (%alive-p conn)))
    (ok (eql 0 (stdio:close-acp-connection conn)) "idempotent")))

(defun client-remote-owner (ra)
  "The TEST-CLIENT behind RA's connection."
  (acp:acp-connection-local (acp:remote-connection ra)))

(deftest child-directory-and-stderr
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "acp-stdio-child-~36r/" (random (expt 36 6)))
                                (uiop:temporary-directory))))
         (log (merge-pathnames "stderr.log" dir)))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-child (conn ra :directory dir :error-output log)
             (ok (initialize-child ra))
             (let* ((client (client-remote-owner ra))
                    (sid (new-session ra)))
               (prompt ra sid "pwd")
               (let ((pwd (car (last (update-texts client)))))
                 (ok (and pwd (uiop:pathname-equal
                               (truename dir)
                               (truename (uiop:ensure-directory-pathname
                                          (uiop:parse-native-namestring pwd)))))
                     (d pwd)))
               (setf (gethash "/w/a.txt" (client-files client)) "old")
               (prompt ra sid "work"))
             (ok (eql 0 (values (call-within 30 (lambda ()
                                                  (stdio:close-acp-connection conn :timeout 10)))))))
           (let ((text (and (probe-file log) (uiop:read-file-string log))))
             (ok (and text (search "scripted-agent: permission allow-once" text))
                 "the child's stderr went to :ERROR-OUTPUT, unparsed")
             (ok (and text (search "STRAY-OUTPUT-ON-STDOUT" text))
                 "a PRINT in a handler went to stderr, not into the ACP stream")))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest child-killed-gives-a-condition-not-a-hang
  (with-child (conn ra)
    (ok (initialize-child ra))
    (let* ((client (client-remote-owner ra))
           (sid (new-session ra))
           (turn (in-background (lambda () (prompt ra sid "wait")))))
      (ok (wait-until 30 (lambda () (equal "waiting" (car (last (update-texts client)))))))
      (process-protocol:kill (stdio:acp-stdio-connection-process conn) :force t)
      (ok (await turn 15) "the waiting prompt ends")
      (let ((c (outcome-condition turn)))
        (ok (typep c 'acp:acp-internal-error) (d c))
        (ok (and (typep c 'acp:acp-error) (search "exited" (acp:acp-error-message c)))
            "the message says the agent exited")
        (let ((data (and (typep c 'acp:acp-error) (acp:acp-error-data c))))
          (ok (and (hash-table-p data) (nth-value 1 (gethash "exitCode" data))))))
      (multiple-value-bind (v condition finished) (call-within 15 (lambda () (new-session ra)))
        (declare (ignore v))
        (ok finished "a later call does not hang either")
        (ok (typep condition 'acp:acp-internal-error)))
      (ok (nth-value 2 (call-within 15 (lambda () (stdio:close-acp-connection conn))))
          "close returns"))))

(deftest child-hung-agent-is-killed-after-the-grace-period
  (with-child (conn ra :env (("ACP_FIXTURE_MODE" . "hang")))
    (ok (initialize-child ra))
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (v condition finished)
          (call-within 30 (lambda () (stdio:close-acp-connection conn :timeout 2)))
        (declare (ignore v))
        (ok finished "close returns")
        (ok (null condition) (d condition)))
      (ok (< (elapsed-since start) 15) "within TIMEOUT + 10 s")
      (ok (not (%alive-p conn)) "the hung child was killed"))))

(deftest child-wait-sees-the-exit
  (with-child (conn ra)
    (ok (initialize-child ra))
    (new-session ra)
    (ok (typep (acp:acp-logout ra (acp:make-acp 'acp:logout-request)) 'acp:logout-response))
    ;; logout → STOP-ACP-AGENT → the child's serve returns and it exits 0
    (ok (eql 0 (values (call-within 30 (lambda () (stdio:wait-acp-connection conn :timeout 20)))))
        "WAIT-ACP-CONNECTION → the exit code")
    (ok (not (%alive-p conn)))))
