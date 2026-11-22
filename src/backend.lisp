(in-package #:acp-backend-stdio)

;;; ACP over stdio (contract ACP-1, 0.1.0).
;;;
;;; The package, ACP-STDIO-CONNECTION and its PROCESS reader, the dispatch
;;; defaults, SERVE-ACP-AGENT, STOP-ACP-AGENT, SPAWN-ACP-AGENT,
;;; CONNECT-ACP-STREAMS, WAIT-ACP-CONNECTION and CLOSE-ACP-CONNECTION.
;;;
;;; Framing (ACP spec, Transports / stdio). One JSON-RPC 2.0 message per
;;; line, UTF-8, LF. A message never contains a raw newline: JSON-RPC text
;;; comes from rpc-protocol-json's encoder (through acp-protocol and
;;; rpc-backend-stdio), which escapes newlines, CR and every control
;;; character inside strings. A CR before the LF of an incoming line is
;;; accepted (JSON whitespace). Nothing but ACP messages is written to the
;;; agent's stdout or the client's pipe to it. stderr is for logs: the client
;;; passes the child's stderr through (:ERROR-OUTPUT) and never reads or
;;; parses it. Blank lines are ignored. Lines of any length are read whole
;;; (no size limit; > 1 MiB is tested).
;;;
;;; Transport. Both sides are rpc-backend-stdio peer-mode transports
;;; (MAKE-STDIO-RPC-TRANSPORT with :ON-REQUEST and :ON-NOTIFICATION, so the
;;; reader thread starts at once): ACP is symmetric, each side sends and
;;; answers requests on the same pair of streams. ON-REQUEST and
;;; ON-NOTIFICATION call ACP-PROTOCOL:ACP-CONNECTION-HANDLER of the side's
;;; connection with ACP-PROTOCOL:*ACP-INCOMING-KIND* bound to :REQUEST /
;;; :NOTIFICATION. Error mapping is acp-protocol's, unchanged: the handler's
;;; RPC-ERROR (from ACP-ERROR-FOR) goes on the wire with its code, message
;;; and data; on the calling side REMOTE-CALL re-signals it as the
;;; ACP-CONDITION-FOR the code, with RETRY / USE-VALUE.
;;;   Unparseable lines: answered -32700 "Parse error" with "id": null, and
;;;   non-object / bad-envelope lines -32600, then reading goes on. In peer
;;;   mode that answer is rpc-backend-stdio's job (#14, fixed in 0.3.1, the
;;;   version this system depends on). No second line parser here.
;;;
;;; Dispatch. The agent side defaults to :CONCURRENT (*AGENT-DISPATCH*):
;;;   * a session/prompt handler calls the client (session/request_permission,
;;;     fs/*, terminal/*) and waits for the answer, so handlers cannot run on
;;;     the reader thread (:READER makes that call fail with -32603);
;;;   * session/cancel and $/cancel_request are notifications that must reach
;;;     the agent WHILE its session/prompt handler runs. :SERIAL queues them
;;;     behind the running prompt, so a turn could never be cancelled.
;;;     :CONCURRENT runs each request on a thread of its own and every
;;;     notification on one dispatcher thread, in arrival order.
;;;   * Outgoing session/update notifications keep their order: an agent
;;;     sends them from its prompt thread, each line written whole under the
;;;     transport's write lock, and the client handles them in arrival order.
;;;   Consequence: an agent's requests may run concurrently (a session/new or
;;;   session/set_mode while a prompt runs); the agent's own state must be
;;;   thread-safe. :SERIAL is accepted (one request at a time; cancellation
;;;   only between requests); :READER is refused with a TYPE-ERROR.
;;; The client side defaults to :READER (*CLIENT-DISPATCH*): the client GFs
;;;   (session/update, session/request_permission, fs/*, terminal/*) run on
;;;   the reader thread, so every session/update the agent sent before a
;;;   response has been handled by the client when the call that waited for
;;;   that response returns (as on the loopback: "updates precede the prompt
;;;   response"). A client GF may send notifications (ACP-CANCEL from inside
;;;   a permission dialog) but must not call the agent and wait; a client that
;;;   needs that passes :DISPATCH :CONCURRENT and loses the ordering
;;;   guarantee between updates and responses.
;;; Threads and permission: a client GF runs on a transport thread, not in
;;;   the caller of ACP-PROMPT, so a HANDLER-BIND around the prompt call does
;;;   not see ACP-PERMISSION-REQUIRED. A client answers permission with a
;;;   method on ACP-REQUEST-PERMISSION (or a HANDLER-BIND inside one, around
;;;   CALL-NEXT-METHOD); unhandled → cancelled, as acp-protocol says.
;;;
;;; ACP-STDIO-CONNECTION: an ACP-PROTOCOL:ACP-CONNECTION whose TRANSPORT is a
;;;   RPC-BACKEND-STDIO:STDIO-RPC-TRANSPORT (or a subclass of it); PROCESS is
;;;   the spawned agent's PROCESS-PROTOCOL handle, or NIL.
;;;
;;; SERVE-ACP-AGENT AGENT &key INPUT OUTPUT (DISPATCH *AGENT-DISPATCH*)
;;;     → the connection (role :agent, local AGENT), once serving ended.
;;;   Serves AGENT (an ACP-PROTOCOL:ACP-AGENT) on INPUT / OUTPUT, default the
;;;   process's stdin / stdout as UTF-8 character streams (on SBCL fd 0 / 1;
;;;   the defaulted streams are flushed, never closed). While AGENT's GFs
;;;   run, ACP-PROTOCOL:*ACP-REMOTE* is the client proxy, so the agent
;;;   streams with (ACP-SEND-UPDATE *ACP-REMOTE* …) and asks with
;;;   (ACP-ASK-PERMISSION *ACP-REMOTE* …). In every handler thread
;;;   *STANDARD-OUTPUT* is *ERROR-OUTPUT* (the value when serving started),
;;;   so a stray PRINT in agent code goes to stderr, never into the ACP
;;;   stream. Blocks the calling thread until either
;;;     * INPUT reaches EOF (the client closed our stdin, or went away) and the
;;;       handlers already started have finished (their answers are written
;;;       while OUTPUT is writable), or
;;;     * STOP-ACP-AGENT was called on the connection.
;;;   Then the transport is closed (given streams are closed, so the client
;;;   sees EOF) and the connection returned. Errors inside handlers never
;;;   escape: they are answers. There is no ACP shutdown method in stable v1
;;;   and `logout` ends authentication, not the connection; an agent that
;;;   wants to exit on logout calls STOP-ACP-AGENT from its ACP-LOGOUT method.
;;; STOP-ACP-AGENT CONNECTION → T. Callable from a handler (the answer of the
;;;   request that called it is still written) or any other thread; SERVE-
;;;   ACP-AGENT returns soon after, without handling later messages.
;;;   Idempotent.
;;;
;;; Cancellation (agent side).
;;;   session/cancel → ACP-CANCEL on the dispatcher thread while the prompt
;;;     runs (:CONCURRENT); the agent ends its turn and ACP-PROMPT returns or
;;;     signals ACP-REQUEST-CANCELLED → stopReason "cancelled" (acp-protocol).
;;;   $/cancel_request {requestId} → ACP-CANCEL-REQUEST on the agent (its GF,
;;;     default ignore), then, when a request with that id is still running
;;;     here, ACP-REQUEST-CANCELLED is signalled in that request's thread
;;;     (BT2:INTERRUPT-THREAD), so a handler blocked waiting for the client
;;;     unwinds: the request is answered -32800, a session/prompt with
;;;     stopReason "cancelled". The running id is RPC-BACKEND-STDIO:
;;;     *STDIO-RPC-REQUEST-ID*, compared with EQUAL to requestId. An unknown or
;;;     finished id is ignored. Client side: $/cancel_request reaches the
;;;     client's ACP-CANCEL-REQUEST GF only (the client's handlers run on the
;;;     reader, there is no request thread to interrupt).
;;;
;;; SPAWN-ACP-AGENT ARGV &key ENV DIRECTORY CLIENT (DISPATCH *CLIENT-DISPATCH*)
;;;     (ERROR-OUTPUT :INTERACTIVE) → (values CONNECTION REMOTE-AGENT).
;;;   ARGV a list of strings (program and arguments, no shell). Launches it
;;;   with PROCESS-PROTOCOL:LAUNCH (:INPUT / :OUTPUT pipes, UTF-8, ENV merged
;;;   into the inherited environment, DIRECTORY the child's working
;;;   directory, ERROR-OUTPUT the child's stderr: :INTERACTIVE = ours, or a
;;;   pathname; never a pipe nobody drains; :PROCESS-GROUP T when the backend
;;;   supports it, so a kill reaches the agent's own children). The child's
;;;   stdout / stdin become the transport's INPUT / OUTPUT (the launch is
;;;   ours, not the transport's :COMMAND, which takes no ENV or DIRECTORY).
;;;   CLIENT (default a fresh ACP-PROTOCOL:ACP-CLIENT) implements the
;;;   client-side GFs; CONNECTION has role :client; REMOTE-AGENT is its proxy,
;;;   on which the caller runs ACP-INITIALIZE, ACP-NEW-SESSION, ACP-PROMPT, …
;;;   Nothing is sent before the caller's first call. On Windows no handle of
;;;   the parent leaks into the child (process-backend-uiop 0.3.4).
;;;   The agent dies or closes its stdout: every call waiting for it, and every
;;;   later call, signals ACP-PROTOCOL:ACP-INTERNAL-ERROR (-32603) whose
;;;   message says the agent exited and names its exit code, and whose DATA is
;;;   a JSON object with "exitCode" (an integer, or :NULL when unknown, e.g.
;;;   killed by a signal) — within a few seconds, never a hang.
;;; CONNECT-ACP-STREAMS CLIENT INPUT OUTPUT &key (DISPATCH *CLIENT-DISPATCH*)
;;;     → (values CONNECTION REMOTE-AGENT). The same over streams that exist:
;;;   INPUT carries the agent's messages, OUTPUT goes to the agent. No
;;;   process; a closed INPUT gives the same ACP-INTERNAL-ERROR without
;;;   "exitCode".
;;; WAIT-ACP-CONNECTION CONNECTION &key TIMEOUT → the child's exit code (an
;;;   integer) once the agent's output reached EOF and the child exited, T for
;;;   a stream connection once INPUT reached EOF, or NIL when TIMEOUT seconds
;;;   passed first. Does not close or kill.
;;; CLOSE-ACP-CONNECTION CONNECTION &key (TIMEOUT 5) FORCE → the child's exit
;;;   code (an integer, or NIL when the OS reports none), or T without a
;;;   process. Closes our side (the agent sees EOF on its stdin and exits),
;;;   waits up to TIMEOUT seconds for the child to exit, then kills it
;;;   (PROCESS-PROTOCOL:KILL :FORCE T, :TREE T with a process group; FORCE: at
;;;   once). Calls still waiting signal the ACP-INTERNAL-ERROR above. Always
;;;   returns within TIMEOUT + 10 seconds: no wait in here is unbounded, even
;;;   when another process still holds the child's stdout (rpc-backend-stdio
;;;   #12) or closing a stream under a blocked reader hangs (#10, Windows);
;;;   such a stream is abandoned with a WARNING rather than waited for.
;;;   Since rpc-backend-stdio 0.3.1 the transport's own close is bounded too
;;;   (#12: a :GRACE option, default 3 s, then the warning
;;;   STDIO-RPC-PIPE-HELD); the TIMEOUT + 10 s bound here stays the contract.
;;;   Idempotent: a second call returns the same value.
;;;   On an agent connection (from SERVE-ACP-AGENT) it closes the transport.

(defvar *agent-dispatch* :concurrent
  "SERVE-ACP-AGENT's default :DISPATCH (:CONCURRENT or :SERIAL).")

(defvar *client-dispatch* :reader
  "SPAWN-ACP-AGENT's and CONNECT-ACP-STREAMS' default :DISPATCH.")

(defclass acp-stdio-connection (acp-protocol:acp-connection)
  ((process :initarg :process :initform nil :reader acp-stdio-connection-process
            :documentation "The spawned agent's PROCESS-PROTOCOL handle, or NIL.")
   ;; Internal state, under STATE-LOCK (broadcast on STATE-CV at every change).
   (process-group-p :initform nil :accessor %process-group-p
                    :documentation "PROCESS was launched with :PROCESS-GROUP T.")
   (state-lock :initform (bt2:make-lock :name "acp-stdio") :reader %lock)
   (state-cv :initform (bt2:make-condition-variable :name "acp-stdio") :reader %cv)
   (stop-requested :initform nil :accessor %stop-requested
                   :documentation "Agent side: STOP-ACP-AGENT was called.")
   (stoppers :initform '() :accessor %stoppers
             :documentation "Agent side: the request threads that called STOP-ACP-AGENT.")
   (running :initform (make-hash-table :test 'equal) :reader %running
            :documentation "Agent side: request id (EQUAL) → the %BOX of its running handler.")
   (exited :initform nil :accessor %exited
           :documentation "Client side: the exit watcher reaped PROCESS.")
   (exit-code :initform nil :accessor %exit-code
              :documentation "PROCESS's exit code once EXITED (NIL when the OS gave none).")
   (close-state :initform nil :accessor %close-state
                :documentation "NIL, :CLOSING or :CLOSED (CLOSE-ACP-CONNECTION).")
   (close-value :initform nil :accessor %close-value))
  (:documentation "An ACP connection over an rpc-backend-stdio transport."))

;;; --- deadlines and connection state ------------------------------------------------

(defun %deadline (seconds)
  (+ (get-internal-real-time) (round (* seconds internal-time-units-per-second))))

(defun %seconds-left (deadline)
  (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))

(defun %poll (seconds predicate)
  "Call PREDICATE every 10 ms for SECONDS at most. → its value, or NIL."
  (loop with deadline = (%deadline seconds)
        for value = (funcall predicate)
        when value return value
        while (plusp (%seconds-left deadline))
        do (sleep 0.01)))

(defmacro %with-state ((connection) &body body)
  "BODY under CONNECTION's state lock; waiters are woken afterwards."
  (let ((c (gensym "CONNECTION")))
    `(let ((,c ,connection))
       (bt2:with-lock-held ((%lock ,c))
         (multiple-value-prog1 (progn ,@body)
           (bt2:condition-broadcast (%cv ,c)))))))

(defun %await-state (connection seconds predicate)
  "Wait until PREDICATE (called under the state lock) is true, or SECONDS
passed (NIL: no limit). → its value, or NIL."
  (let ((deadline (and seconds (%deadline seconds)))
        (lock (%lock connection))
        (cv (%cv connection)))
    (bt2:with-lock-held (lock)
      (loop
        (let ((value (funcall predicate)))
          (when value (return value)))
        (let ((left (and deadline (%seconds-left deadline))))
          (when (and left (<= left 0)) (return nil))
          ;; Re-checked at least once a second.
          (bt2:condition-wait cv lock :timeout (if left (min left 1) 1)))))))

(defun %bounded (seconds what thunk)
  "Run THUNK on a helper thread and wait SECONDS for it. → T when it finished
in time; an error it signalled is signalled again here. One still running is
abandoned with a WARNING (a stream close that blocks: rpc-backend-stdio #10,
#12), → NIL."
  (let* ((outcome (list nil))           ; (done-p . condition)
         (thread (bt2:make-thread
                  (lambda ()
                    ;; Nothing may escape a thread function; the condition is
                    ;; handed to the waiting caller instead.
                    (handler-case (funcall thunk)
                      (error (c) (setf (cdr outcome) c)))
                    (setf (car outcome) t))
                  :name "acp-stdio close")))
    (declare (ignorable thread))
    (cond ((%poll seconds (lambda () (car outcome)))
           (when (cdr outcome) (error (cdr outcome)))
           t)
          (t (warn "acp-backend-stdio: ~A did not finish within ~A s; abandoned" what seconds)
             nil))))

;;; --- agent side: running requests and $/cancel_request ------------------------------

(defstruct (%box (:constructor %make-box (id thread)))
  "One agent request whose handler runs in THREAD. STATE (:RUNNING / :DONE),
WRITING and PENDING are written only by THREAD itself (its own code, or an
interrupt function running in it), so they need no lock."
  id thread (state :running) (writing nil) (pending nil))

(defvar *request-box* nil
  "The %BOX of the agent request whose handler runs in this thread. Bound only
inside the request wrapper, so it is NIL while rpc-backend-stdio writes the answer.")

(defun %interrupt-request (connection request-id)
  "$/cancel_request: signal ACP-REQUEST-CANCELLED in the thread of the running
request REQUEST-ID (EQUAL). Unknown or finished ids are ignored. A thread in
the middle of writing a line gets the signal right after that line (see
%GUARD-OUTPUT), so no line is ever cut."
  (let ((box (bt2:with-lock-held ((%lock connection))
               (gethash request-id (%running connection)))))
    (when (and box (eq :running (%box-state box)))
      (handler-case
          (bt2:interrupt-thread
           (%box-thread box)
           (lambda ()
             (when (and (eq *request-box* box) (eq :running (%box-state box)))
               (if (%box-writing box)
                   (setf (%box-pending box) t)
                   (error 'acp-protocol:acp-request-cancelled)))))
        ;; The thread ended between the lookup and the interrupt: nothing to cancel.
        (error () nil)))))

;;; The agent's output stream. rpc-backend-stdio writes each line as
;;; WRITE-STRING, a newline and FINISH-OUTPUT under its write lock. While a
;;; request thread writes, an interrupt only marks the cancel PENDING; it is
;;; signalled after the line's FINISH-OUTPUT, so the line is whole and the
;;; write lock is released by the unwind. CLOSE-TARGET-P NIL (the defaulted
;;; stdout) flushes the target and never closes it.

(defclass %guard-output (trivial-gray-streams:fundamental-character-output-stream)
  ((target :initarg :target :reader %guard-target)
   (close-target-p :initarg :close-target-p :reader %guard-close-target-p)))

(defun %begin-write ()
  (let ((box *request-box*))
    (when box (setf (%box-writing box) t))))

(defmethod trivial-gray-streams:stream-write-char ((stream %guard-output) char)
  (%begin-write)
  (write-char char (%guard-target stream)))

(defmethod trivial-gray-streams:stream-write-string ((stream %guard-output) string
                                                     &optional (start 0) end)
  (%begin-write)
  (write-string string (%guard-target stream) :start start :end end)
  string)

(defmethod trivial-gray-streams:stream-line-column ((stream %guard-output))
  nil)

(defmethod trivial-gray-streams:stream-force-output ((stream %guard-output))
  (force-output (%guard-target stream)))

(defmethod trivial-gray-streams:stream-finish-output ((stream %guard-output))
  (finish-output (%guard-target stream))
  (let ((box *request-box*))
    (when box
      (setf (%box-writing box) nil)
      (when (shiftf (%box-pending box) nil)
        (error 'acp-protocol:acp-request-cancelled)))))

(defmethod close ((stream %guard-output) &key abort)
  (let ((target (%guard-target stream)))
    (when (open-stream-p target)
      (if (%guard-close-target-p stream)
          (close target :abort abort)
          (finish-output target))))
  (call-next-method))

#+sbcl
(defun %std-fd (stream)
  "The OS descriptor under SBCL's standard stream STREAM (SB-SYS:*STDIN* /
*STDOUT*): fd 0 / 1 on Unix, but the process's standard HANDLE on Windows,
where SBCL fd-streams wrap HANDLEs and fd 0 / 1 are not stdin / stdout."
  (and (typep stream 'sb-sys:fd-stream) (sb-sys:fd-stream-fd stream)))

(defun %agent-streams (input output)
  "→ (values INPUT OUTPUT RAW-STDOUT) for the agent's transport. The defaulted
stdin / stdout are UTF-8 streams on the descriptors under SB-SYS:*STDIN* /
*STDOUT* (SBCL; %STD-FD) inside wrappers whose close does not close them (a
concatenated stream; %GUARD-OUTPUT with CLOSE-TARGET-P NIL). RAW-STDOUT is
the defaulted stdout stream, or NIL."
  (let ((in (or input
                (make-concatenated-stream
                 #+sbcl (let ((fd (%std-fd sb-sys:*stdin*)))
                          (if fd
                              (sb-sys:make-fd-stream fd :input t :external-format :utf-8
                                                        :buffering :full)
                              *standard-input*))
                 #-sbcl *standard-input*)))
        (raw-out (or output
                     #+sbcl (let ((fd (%std-fd sb-sys:*stdout*)))
                              (if fd
                                  (sb-sys:make-fd-stream fd :output t :external-format :utf-8
                                                            :buffering :full)
                                  *standard-output*))
                     #-sbcl *standard-output*)))
    (unless output
      ;; Nothing buffered on the old stdout stream can land between our lines.
      (finish-output *standard-output*))
    (values in
            (make-instance '%guard-output :target raw-out :close-target-p (and output t))
            (and (null output) raw-out))))

(defun %incoming (connection kind &key agent-p (stdout *error-output*))
  "The :ON-REQUEST / :ON-NOTIFICATION function of CONNECTION's transport: its
ACP-CONNECTION-HANDLER with *ACP-INCOMING-KIND* bound. On the agent side
*STANDARD-OUTPUT* is STDOUT (stray prints go to stderr), requests are
registered by id for $/cancel_request, and $/cancel_request interrupts the
running request after the agent's ACP-CANCEL-REQUEST."
  (let ((handler (acp-protocol:acp-connection-handler connection)))
    (ecase kind
      (:request
       (if (not agent-p)
           (lambda (method params)
             (let ((acp-protocol:*acp-incoming-kind* :request))
               (funcall handler method params)))
           (lambda (method params)
             (let* ((*standard-output* stdout)
                    (acp-protocol:*acp-incoming-kind* :request)
                    (box (%make-box rpc-backend-stdio:*stdio-rpc-request-id*
                                    (bt2:current-thread))))
               (%with-state (connection)
                 (setf (gethash (%box-id box) (%running connection)) box))
               (unwind-protect
                    (let ((*request-box* box))
                      (handler-case (funcall handler method params)
                        ;; A cancel that landed outside the handler's own
                        ;; HANDLER-CASE: still acp-protocol's -32800 answer.
                        (acp-protocol:acp-request-cancelled (c)
                          (multiple-value-bind (code message data) (acp-protocol:acp-error-for c)
                            (error 'rpc-protocol:rpc-error
                                   :code code :message message :data data)))))
                 ;; First: an interrupt arriving from now on does nothing.
                 (setf (%box-state box) :done)
                 (%with-state (connection)
                   (when (eq box (gethash (%box-id box) (%running connection)))
                     (remhash (%box-id box) (%running connection)))))))))
      (:notification
       (lambda (method params)
         (let ((acp-protocol:*acp-incoming-kind* :notification)
               (*standard-output* (if agent-p stdout *standard-output*)))
           ;; The local peer's GF first (ACP-CANCEL-REQUEST for $/cancel_request).
           (funcall handler method params)
           (when (and agent-p (equal method "$/cancel_request") (hash-table-p params))
             (multiple-value-bind (id present) (gethash "requestId" params)
               (when present
                 (%interrupt-request connection id))))))))))

(defun %wire (connection transport &key agent-p (stdout *error-output*))
  "Connect CONNECTION and TRANSPORT (made without handlers, so no reader runs
yet), install the handlers, then start the reader: no message is handled
before the connection is complete."
  (setf (acp-protocol:acp-connection-remote connection)
        (make-instance (if agent-p 'acp-protocol:remote-client 'acp-protocol:remote-agent)
                       :connection connection)
        (acp-protocol:acp-connection-transport connection) transport
        (rpc-backend-stdio:stdio-rpc-transport-on-request transport)
        (%incoming connection :request :agent-p agent-p :stdout stdout)
        (rpc-backend-stdio:stdio-rpc-transport-on-notification transport)
        (%incoming connection :notification :agent-p agent-p :stdout stdout))
  ;; "Start the reader if needed"; with TIMEOUT 0 it returns at once.
  (rpc-backend-stdio:stdio-rpc-transport-wait-closed transport :timeout 0)
  transport)

;;; --- agent side: serving ---------------------------------------------------------

(defun %await-stoppers (connection dispatch seconds)
  "Let the request that called STOP-ACP-AGENT write its answer (SECONDS at most)."
  (let ((threads (bt2:with-lock-held ((%lock connection))
                   (copy-list (%stoppers connection)))))
    (when threads
      (if (eq dispatch :concurrent)
          ;; A :CONCURRENT worker ends only after its answer was written.
          (%poll seconds (lambda () (notany #'bt2:thread-alive-p threads)))
          ;; :SERIAL: the dispatcher writes the answer right after the handler.
          (progn
            (%poll seconds (lambda ()
                             (bt2:with-lock-held ((%lock connection))
                               (zerop (hash-table-count (%running connection))))))
            (sleep 0.2))))))

(defun serve-acp-agent (agent &key input output (dispatch *agent-dispatch*))
  (check-type dispatch (member :concurrent :serial))
  (check-type agent acp-protocol:acp-agent)
  (let ((stdout *error-output*))
    (multiple-value-bind (in out raw-stdout) (%agent-streams input output)
      (let* ((connection (make-instance 'acp-stdio-connection :role :agent :local agent))
             (transport (rpc-backend-stdio:make-stdio-rpc-transport
                         :input in :output out :dispatch dispatch)))
        (%wire connection transport :agent-p t :stdout stdout)
        (unwind-protect
             (progn
               (loop until (or (%stop-requested connection)
                               (rpc-backend-stdio:stdio-rpc-transport-wait-closed
                                transport :timeout 0.1)))
               (when (%stop-requested connection)
                 (%await-stoppers connection dispatch 3)))
          (%bounded 10 "closing the agent's transport"
                    (lambda () (rpc-backend-stdio:close-stdio-rpc-transport transport :timeout 0)))
          (when raw-stdout
            (handler-case (finish-output raw-stdout)
              (stream-error () nil))))
        connection))))

(defun stop-acp-agent (connection)
  (check-type connection acp-stdio-connection)
  (%with-state (connection)
    (setf (%stop-requested connection) t)
    (let ((box *request-box*))
      ;; Called from one of this connection's requests: serve lets it answer.
      (when (and box (eq box (gethash (%box-id box) (%running connection))))
        (pushnew (bt2:current-thread) (%stoppers connection)))))
  t)

;;; --- client side: the agent's exit -------------------------------------------------

(defclass %process-transport (rpc-backend-stdio:stdio-rpc-transport)
  ((connection :initarg :connection :reader %transport-connection))
  (:documentation "The transport of a spawned agent: \"peer closed\" becomes the
agent's exit (ACP-INTERNAL-ERROR with \"exitCode\")."))

(defun %peer-closed-error-p (condition)
  "rpc-backend-stdio's \"peer closed\" RPC-ERROR (-32603, no data), not a timeout
and not an error answer of the agent."
  (and (not (typep condition 'rpc-backend-stdio:stdio-rpc-timeout))
       (eql (rpc-protocol:rpc-error-code condition) rpc-protocol:+internal-error+)
       (null (rpc-protocol:rpc-error-data condition))
       (let ((message (rpc-protocol:rpc-error-message condition)))
         (and (stringp message) (eql 0 (search "stdio RPC peer closed" message))))))

(defun %signal-exited (connection)
  "Signal the RPC-ERROR -32603 of an agent that exited; acp-protocol makes it
an ACP-INTERNAL-ERROR with the same message and data."
  (%await-state connection 5 (lambda () (%exited connection)))
  (let ((code (and (%exited connection) (%exit-code connection)))
        (data (make-hash-table :test 'equal)))
    (setf (gethash "exitCode" data) (if (integerp code) code :null))
    (error 'rpc-protocol:rpc-error
           :code rpc-protocol:+internal-error+ :data data
           :message (if (integerp code)
                        (format nil "The ACP agent exited with code ~D" code)
                        "The ACP agent exited or closed its stdout (exit code unknown)"))))

(defmethod rpc-protocol:backend-rpc-call :around
    ((transport %process-transport) method params &key timeout id)
  (declare (ignore method params timeout id))
  ;; HANDLER-CASE, not HANDLER-BIND: rpc-backend-stdio may signal "peer closed"
  ;; under its state lock, and %SIGNAL-EXITED waits; unwind first.
  (handler-case (call-next-method)
    ((and rpc-protocol:rpc-error (satisfies %peer-closed-error-p)) ()
      (%signal-exited (%transport-connection transport)))))

(defmethod rpc-protocol:backend-rpc-notify :around
    ((transport %process-transport) method params)
  (declare (ignore method params))
  (let ((connection (%transport-connection transport)))
    (handler-case (call-next-method)
      ;; A write to a dead agent's stdin.
      (stream-error (e)
        (if (%await-state connection 1 (lambda () (%exited connection)))
            (%signal-exited connection)
            (error e))))))

(defun %start-exit-watcher (connection)
  "The one thread that reaps the agent: records its exit code when it exits."
  (let ((process (acp-stdio-connection-process connection)))
    (bt2:make-thread
     (lambda ()
       (let ((code (handler-case (process-protocol:wait process)
                     ;; Nothing may escape the thread; the code is then unknown.
                     (error () nil))))
         (%with-state (connection)
           (setf (%exit-code connection) code
                 (%exited connection) t))))
     :name "acp-stdio exit watcher")))

;;; --- client side: connections ------------------------------------------------------

(defun %client-connection (client input output dispatch &key process process-group-p)
  (check-type dispatch (member :reader :serial :concurrent))
  (let ((connection (make-instance 'acp-stdio-connection
                                   :role :client :process process
                                   :local (or client (make-instance 'acp-protocol:acp-client))))
        (transport (rpc-backend-stdio:make-stdio-rpc-transport
                    :input input :output output :dispatch dispatch)))
    (when process
      ;; No reader thread exists yet, and no other thread knows TRANSPORT.
      (change-class transport '%process-transport :connection connection)
      (setf (%process-group-p connection) process-group-p)
      (%start-exit-watcher connection))
    (%wire connection transport)
    (values connection (acp-protocol:acp-connection-remote connection))))

(defun spawn-acp-agent (argv &key env directory client (dispatch *client-dispatch*)
                                  (error-output :interactive))
  (check-type argv (cons string list))
  (check-type dispatch (member :reader :serial :concurrent))
  (let* ((group-p (and (process-protocol:supports-p :process-group) t))
         (process (apply #'process-protocol:launch argv
                         :input :stream :output :stream :error-output error-output
                         :external-format :utf-8 :env env :directory directory
                         (and group-p '(:process-group t))))
         (done nil))
    (unwind-protect
         (multiple-value-prog1
             (%client-connection client (process-protocol:stdout process)
                                 (process-protocol:stdin process) dispatch
                                 :process process :process-group-p group-p)
           (setf done t))
      (unless done
        (process-protocol:kill process :force t :tree group-p)))))

(defun connect-acp-streams (client input output &key (dispatch *client-dispatch*))
  (%client-connection client input output dispatch))

(defun wait-acp-connection (connection &key timeout)
  (check-type connection acp-stdio-connection)
  (check-type timeout (or null (real 0)))
  (let ((deadline (and timeout (%deadline timeout)))
        (transport (acp-protocol:acp-connection-transport connection)))
    (and (rpc-backend-stdio:stdio-rpc-transport-wait-closed transport :timeout timeout)
         (if (acp-stdio-connection-process connection)
             (and (%await-state connection
                                (and deadline (max 0 (%seconds-left deadline)))
                                (lambda () (%exited connection)))
                  (%exit-code connection))
             t))))

;;; --- close -------------------------------------------------------------------------

(defun %close-stdin (process)
  "EOF on the agent's stdin. A dead agent's pipe fails the flush: it is gone."
  (let ((stdin (process-protocol:stdin process)))
    (when stdin
      (handler-case (close stdin)
        (stream-error () (handler-case (close stdin :abort t)
                           (stream-error () nil)))))))

(defun %close-now (connection timeout force)
  "→ the exit code (or NIL), or T without a process. At most TIMEOUT + 9 s."
  (let ((transport (acp-protocol:acp-connection-transport connection))
        (process (acp-stdio-connection-process connection)))
    (flet ((close-transport (seconds &rest keys)
             (when transport
               (%bounded seconds "closing the ACP transport"
                         (lambda ()
                           (apply #'rpc-backend-stdio:close-stdio-rpc-transport
                                  transport :timeout 0 keys))))))
      (cond
        ((eq :agent (acp-protocol:acp-connection-role connection))
         (stop-acp-agent connection)
         (close-transport 8)
         t)
        ((null process)
         (close-transport 8)
         t)
        (t
         ;; 1. EOF on the child's stdin (a Windows pipe close can block: #10).
         (%bounded 1 "closing the agent's stdin" (lambda () (%close-stdin process)))
         ;; 2. A graceful exit at EOF.
         (unless force
           (%await-state connection timeout (lambda () (%exited connection))))
         ;; 3. Else kill it, with its tree when it leads a process group.
         (unless (bt2:with-lock-held ((%lock connection)) (%exited connection))
           (handler-case (process-protocol:kill process :force t
                                                        :tree (%process-group-p connection))
             (process-protocol:process-error () nil))
           (%await-state connection 2 (lambda () (%exited connection))))
         ;; 4. The reader, now that the child is gone (rpc-backend-stdio bounds
         ;;    a stdout another process still holds, #12).
         (close-transport 6 :grace 2 :force t)
         (bt2:with-lock-held ((%lock connection))
           (and (%exited connection) (%exit-code connection))))))))

(defun close-acp-connection (connection &key (timeout 5) force)
  (check-type connection acp-stdio-connection)
  (check-type timeout (real 0))
  (let ((first-p (%with-state (connection)
                   (and (null (%close-state connection))
                        (setf (%close-state connection) :closing)))))
    (unless first-p
      ;; A close in progress elsewhere: wait for it (bounded), then its value.
      (%await-state connection (+ timeout 10)
                    (lambda () (eq :closed (%close-state connection))))
      (return-from close-acp-connection (%close-value connection)))
    (let ((value nil))
      (unwind-protect (setf value (%close-now connection timeout force))
        (%with-state (connection)
          (setf (%close-value connection) value
                (%close-state connection) :closed)))
      value)))
