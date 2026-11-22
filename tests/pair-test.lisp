(in-package #:acp-backend-stdio/tests)

;;; The in-process pair: SERVE-ACP-AGENT on one thread, CONNECT-ACP-STREAMS
;;; on the test's, over two pipes, every message a JSON-RPC line. The same
;;; flow as acp-protocol's loopback tests: initialize → session/new → a
;;; prompt with streamed updates → request_permission answered by the client
;;; → fs read / write, terminal → cancel; plus what only a threaded
;;; transport has: cancel reaching a running prompt, $/cancel_request,
;;; concurrent requests, EOF and logout ending the agent.

(defparameter *work-tags*
  '("agent_message_chunk" "agent_thought_chunk" "tool_call" "tool_call_update"
    "plan" "available_commands_update" "agent_message_chunk"))

(deftest pair-connection-shape
  (with-pair (p)
    (ok (typep (pair-connection p) 'stdio:acp-stdio-connection))
    (ok (eq :client (acp:acp-connection-role (pair-connection p))))
    (ok (typep (pair-ra p) 'acp:remote-agent))
    (ok (eq (pair-ra p) (acp:acp-connection-remote (pair-connection p))))
    (ok (null (stdio:acp-stdio-connection-process (pair-connection p))) "no process")
    (ok (eq :reader (rbs:stdio-rpc-transport-dispatch (transport-of (pair-ra p)))))))

(deftest pair-initialize-records-both-sides
  (with-pair (p)
    (let ((res (initialize (pair-ra p))))
      (ok (typep res 'acp:initialize-response))
      (ok (eql 1 (acp:protocol-version res)))
      (ok (equal "scripted-agent" (acp:name (acp:agent-info res)))))
    (let ((client-side (pair-connection p))
          (agent-side (fx:agent-connection (pair-agent p))))
      (ok (acp:acp-connection-initialized-p client-side))
      (ok (typep agent-side 'stdio:acp-stdio-connection) "the agent's connection")
      (ok (eq :agent (acp:acp-connection-role agent-side)))
      (ok (eq :concurrent (rbs:stdio-rpc-transport-dispatch
                           (acp:acp-connection-transport agent-side)))
          "the agent's default dispatch")
      (ok (acp:client-supports-p (acp:acp-connection-client-capabilities agent-side)
                                 :read-text-file)
          "the client's capabilities crossed the wire")
      (ok (acp:agent-supports-p (acp:acp-connection-agent-capabilities client-side) :logout)))))

(deftest pair-full-turn
  (with-pair (p)
    (let ((sid (session-of p)) (client (pair-client p)) (agent (pair-agent p)))
      (setf (gethash "/w/a.txt" (client-files client)) "old")
      (let ((res (prompt (pair-ra p) sid "work")))
        (ok (typep res 'acp:prompt-response))
        (ok (equal "end_turn" (acp:stop-reason res))))
      (ok (equal '(:permission :allow-once "allow_once") (fx:agent-event agent :permission))
          "the permission round trip")
      (ok (equal '(:read "old") (fx:agent-event agent :read)) "fs read")
      (ok (equal "new" (gethash "/w/a.txt" (client-files client))) "fs write")
      (ok (equal '(:terminal "term-make" 0) (fx:agent-event agent :terminal)))
      (ok (equal '("session/request_permission" "fs/read_text_file" "fs/write_text_file"
                   "terminal/create" "terminal/wait_for_exit" "terminal/release")
                 (client-calls client)))
      (ok (equal *work-tags* (update-tags client)) (d (update-tags client)))
      (ok (every (lambda (n) (equal sid (acp:session-id n))) (client-updates client)))
      (ok (equal "permission allow-once read old" (car (last (update-texts client)))))
      (let ((tcu (fourth (client-update-objects client))))
        (ok (typep tcu 'acp:update-tool-call-update))
        (ok (typep (aref (acp:content tcu) 0) 'acp:diff))
        (ok (equal "old" (acp:old-text (aref (acp:content tcu) 0))))))))

(deftest pair-updates-precede-the-prompt-response
  (with-pair (p)
    (let* ((sid (session-of p)) (client (pair-client p)))
      (setf (gethash "/w/a.txt" (client-files client)) "old")
      (prompt (pair-ra p) sid "work")
      ;; read at once: no wait between the response and the count
      (ok (= 7 (length (client-updates client)))
          "every update was handled before ACP-PROMPT returned"))))

(deftest pair-update-order
  (with-pair (p)
    (let ((sid (session-of p)))
      (prompt (pair-ra p) sid "burst")
      (ok (equal (loop for i below 200 collect (princ-to-string i))
                 (update-texts (pair-client p)))
          "200 updates in the order they were sent"))))

(deftest-parametrize pair-permission-restarts
    ((restart args kind)
     ('acp:allow-once () "allow-once")
     ('acp:allow-always () "allow-always")
     ('acp:reject-once () "reject-once")
     ('acp:reject-always () "reject-always")
     ('acp:select-permission-option '("reject_always") "reject-always")
     ('acp:cancel-permission () "cancelled")
     (nil () "cancelled"))
  (with-pair (p :client (make-instance 'test-client :permission restart :permission-args args))
    (let ((sid (session-of p)))
      (let ((res (prompt (pair-ra p) sid "ask")))
        (ok (equal (if (equal kind "cancelled") "cancelled" "end_turn") (acp:stop-reason res))
            (d restart)))
      (ok (equal (format nil "permission ~a" kind) (car (last (update-texts (pair-client p)))))
          (d restart)))))

(deftest pair-client-without-capabilities
  (with-pair (p)
    (let ((sid (session-of p :caps nil)))
      (let ((res (prompt (pair-ra p) sid "work")))
        (ok (equal "end_turn" (acp:stop-reason res))))
      (ok (equal '("session/request_permission") (client-calls (pair-client p)))
          "no fs / terminal call to a client that advertised none")
      (ok (equal "permission allow-once read none"
                 (car (last (update-texts (pair-client p)))))))))

(deftest pair-text-round-trip
  (with-pair (p)
    (let ((sid (session-of p))
          (text (format nil "line1~%line2~c~c\"quoted\" \\ tab~c héllo ✓ 日本 ~c"
                        #\Return #\Newline #\Tab (code-char #x2028))))
      (prompt (pair-ra p) sid (concatenate 'string "text:" text))
      (ok (equal (list text) (update-texts (pair-client p)))
          "newlines, CR, quotes, backslash, tab, U+2028 and non-ASCII arrive exactly"))))

;;; --- cancellation -------------------------------------------------------------------

(deftest pair-cancel-while-prompt-in-flight
  (with-pair (p)
    (let* ((ra (pair-ra p)) (sid (session-of p))
           (turn (in-background (lambda () (prompt ra sid "wait")))))
      (ok (wait-until 10 (lambda () (member "waiting" (update-texts (pair-client p))
                                            :test #'equal)))
          "the prompt is running")
      ;; another request is answered while the prompt runs (not :serial)
      (multiple-value-bind (other condition finished) (call-within 10 (lambda () (new-session ra)))
        (declare (ignore condition))
        (ok (and finished (equal "sess-2" other)) "session/new answered during the prompt"))
      (let ((start (get-internal-real-time)))
        (cancel ra sid)
        (ok (await turn 10) "session/cancel ends the running prompt")
        (ok (< (elapsed-since start) 10)))
      (ok (null (outcome-condition turn)) (d (outcome-condition turn)))
      (let ((res (first (outcome-values turn))))
        (ok (and (typep res 'acp:prompt-response) (equal "cancelled" (acp:stop-reason res)))))
      (ok (equal (list :cancel sid) (fx:agent-event (pair-agent p) :cancel))))))

(deftest pair-cancel-while-permission-pending
  (with-pair (p :client (make-instance
                         'test-client
                         :permission 'acp:allow-once
                         ;; the user presses stop while the dialog is open: session/cancel
                         ;; goes out from the client's handler, then the dialog is answered
                         :on-permission (lambda (client request)
                                          (cancel (client-remote client) (acp:session-id request)))))
    (let ((sid (session-of p)))
      (multiple-value-bind (res condition finished)
          (call-within 20 (lambda () (prompt (pair-ra p) sid "ask")))
        (ok finished "no deadlock")
        (ok (null condition) (d condition))
        (ok (and res (equal "cancelled" (acp:stop-reason res)))))
      (ok (equal '(:permission :cancelled) (fx:agent-event (pair-agent p) :permission))
          "a cancelled session's pending permission is answered cancelled")
      (ok (wait-until 5 (lambda () (fx:agent-event (pair-agent p) :cancel)))))))

(deftest pair-cancel-request-interrupts-a-running-request
  (with-pair (p)
    (let* ((ra (pair-ra p)))
      (session-of p)
      (let ((call (in-background
                   (lambda ()
                     (rpc-protocol:rpc-call "_cl-stack.test/sleep" (js) :id "slow-1"
                                                                        :transport (transport-of ra))))))
        (ok (wait-until 10 (lambda () (fx:agent-event (pair-agent p) :sleeping))))
        (acp:acp-cancel-request ra (acp:make-acp 'acp:cancel-request-notification
                                                 :request-id "slow-1"))
        (ok (await call 10) "the handler was unwound, not waited for")
        (let ((c (outcome-condition call)))
          (ok (typep c 'rpc-protocol:rpc-error) (d c))
          (ok (and (typep c 'rpc-protocol:rpc-error) (eql -32800 (rpc-protocol:rpc-error-code c)))))
        (ok (equal '(:cancel-request "slow-1") (fx:agent-event (pair-agent p) :cancel-request))
            "the agent's ACP-CANCEL-REQUEST saw it first")))))

(deftest pair-cancel-request-on-a-prompt-is-a-stop-reason
  (with-pair (p)
    (let* ((ra (pair-ra p)) (sid (session-of p))
           (call (in-background
                  (lambda ()
                    (rpc-protocol:rpc-call "session/prompt"
                                           (acp:acp-object-table (prompt-request sid "wait"))
                                           :id "p-1" :transport (transport-of ra))))))
      (ok (wait-until 10 (lambda () (member "waiting" (update-texts (pair-client p))
                                            :test #'equal))))
      (acp:acp-cancel-request ra (acp:make-acp 'acp:cancel-request-notification :request-id "p-1"))
      (ok (await call 10))
      (let ((result (first (outcome-values call))))
        (ok (and (hash-table-p result) (equal "cancelled" (gethash "stopReason" result)))
            (d (or (outcome-condition call) result)))))))

(deftest pair-cancel-request-for-an-unknown-id-is-ignored
  (with-pair (p)
    (let ((ra (pair-ra p)))
      (session-of p)
      (acp:acp-cancel-request ra (acp:make-acp 'acp:cancel-request-notification :request-id 999))
      (ok (wait-until 5 (lambda () (fx:agent-event (pair-agent p) :cancel-request))))
      (ok (stringp (new-session ra)) "the agent keeps serving"))))

;;; --- errors: acp-protocol's mapping over the wire ------------------------------------

(deftest pair-errors-map-to-conditions
  (with-pair (p)
    (let ((ra (pair-ra p)))
      (ok (signals (new-session ra) 'acp:acp-invalid-request) "a request before initialize")
      (let ((sid (session-of p)))
        (ok (signals (prompt ra "no-such-session" "x") 'acp:acp-resource-not-found))
        (ok (signals (prompt ra sid "boom") 'acp:acp-internal-error) "a plain error → -32603")
        (ok (signals (acp:acp-set-session-mode
                      ra (acp:make-acp 'acp:set-session-mode-request :session-id sid
                                                                     :mode-id "code"))
                     'acp:acp-method-not-found)
            "a GF the agent does not implement → -32601")
        (ok (signals (rpc-protocol:rpc-call "session/new" (js "cwd" 5) :transport (transport-of ra))
                     'rpc-protocol:rpc-error)
            "invalid params")
        (handler-case (rpc-protocol:rpc-call "session/new" (js "cwd" 5) :transport (transport-of ra))
          (rpc-protocol:rpc-error (e) (ok (eql -32602 (rpc-protocol:rpc-error-code e)))))
        (handler-case (rpc-protocol:rpc-call "fs/read_text_file" (js) :transport (transport-of ra))
          (rpc-protocol:rpc-error (e)
            (ok (eql -32601 (rpc-protocol:rpc-error-code e)) "a client method sent to the agent")))
        (ok (equal "end_turn" (acp:stop-reason (prompt ra sid "other"))) "still serving")))))

(deftest pair-client-errors-reach-the-agent
  (with-pair (p)
    ;; no /w/a.txt: the client's fs read answers -32002, the agent's script fails
    (let ((sid (session-of p)))
      (ok (signals (prompt (pair-ra p) sid "work") 'acp:acp-error)
          "the agent's resource-not-found surfaces as the prompt's error")
      (ok (equal "end_turn" (acp:stop-reason (prompt (pair-ra p) sid "other")))))))

(deftest pair-extension-echo
  (with-pair (p)
    (session-of p)
    (let ((r (acp:acp-call-ext (pair-ra p) "_cl-stack.test/echo" (js "x" 1))))
      (ok (and (hash-table-p r) (eql 1 (gethash "x" (gethash "echo" r))))))))

;;; --- ending ------------------------------------------------------------------------

(deftest pair-eof-ends-serving
  (let ((p (open-pair)))
    (session-of p)
    (multiple-value-bind (value condition finished)
        (call-within 15 (lambda () (stdio:close-acp-connection (pair-connection p) :timeout 5)))
      (ok finished "close returns")
      (ok (null condition) (d condition))
      (ok (eq t value) "→ T without a process"))
    (ok (await (pair-serve p) 10) "SERVE-ACP-AGENT returned at EOF")
    (ok (null (outcome-condition (pair-serve p))) (d (outcome-condition (pair-serve p))))
    (ok (typep (first (outcome-values (pair-serve p))) 'stdio:acp-stdio-connection)
        "→ the agent's connection")
    (ok (eq t (stdio:close-acp-connection (pair-connection p))) "idempotent")))

(deftest pair-logout-stops-the-agent
  (let ((p (open-pair)))
    (unwind-protect
         (progn
           (session-of p)
           (ok (typep (acp:acp-logout (pair-ra p) (acp:make-acp 'acp:logout-request))
                      'acp:logout-response)
               "the logout request is still answered")
           (ok (await (pair-serve p) 10) "SERVE-ACP-AGENT returned after STOP-ACP-AGENT")
           (ok (null (outcome-condition (pair-serve p))))
           (ok (eq t (wait-acp p 10)) "the client sees EOF")
           (multiple-value-bind (v condition finished) (call-within 10 (lambda () (new-session (pair-ra p))))
             (declare (ignore v))
             (ok finished "no hang after the agent stopped")
             (ok (typep condition 'acp:acp-internal-error) (d condition))))
      (close-pair p))))

(defun wait-acp (pair seconds)
  (values (call-within (+ seconds 5)
                       (lambda () (stdio:wait-acp-connection (pair-connection pair)
                                                             :timeout seconds)))))

(deftest pair-agent-closing-fails-waiting-calls
  ;; the agent side closes its transport while a prompt waits: the client's
  ;; call fails with the -32603 condition, it does not hang
  (let ((p (open-pair)))
    (unwind-protect
         (let* ((sid (session-of p))
                (turn (in-background (lambda () (prompt (pair-ra p) sid "wait")))))
           (ok (wait-until 10 (lambda () (member "waiting" (update-texts (pair-client p))
                                                 :test #'equal))))
           (stdio:stop-acp-agent (fx:agent-connection (pair-agent p)))
           (ok (await turn 15))
           (ok (typep (outcome-condition turn) 'acp:acp-internal-error)
               (d (outcome-condition turn))))
      (close-pair p))))

(deftest pair-serial-dispatch-is-accepted
  (with-pair (p :agent-dispatch :serial)
    (let ((sid (session-of p)))
      (ok (eq :serial (rbs:stdio-rpc-transport-dispatch
                       (acp:acp-connection-transport (fx:agent-connection (pair-agent p))))))
      (setf (gethash "/w/a.txt" (client-files (pair-client p))) "old")
      (ok (equal "end_turn" (acp:stop-reason (prompt (pair-ra p) sid "work")))
          "a prompt still calls the client back under :serial"))))
