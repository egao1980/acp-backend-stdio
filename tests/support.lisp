(in-package #:acp-backend-stdio/tests)

;;; Shared helpers. Every wait has a deadline, so a deadlock or a hang fails
;;; a test instead of hanging the suite.
;;;   * TEST-CLIENT: a recording client whose permission policy is a slot
;;;     (its GFs run on a transport thread, not in the test's thread).
;;;   * WITH-PAIR: the scripted agent served in-process by SERVE-ACP-AGENT on
;;;     one thread, the client connected with CONNECT-ACP-STREAMS, over two
;;;     rpc-backend-stdio pipes (real character streams, not the loopback).
;;;   * WITH-RAW-AGENT: SERVE-ACP-AGENT with the test writing and reading raw
;;;     lines (framing).
;;;   * Child agents: argv, environment and WITH-CHILD (subprocess-test).

(defun js (&rest kvs) (apply #'fx:js kvs))

(defun json (text) (json-protocol:decode text))

(defun d (x) (princ-to-string x))

(defun elapsed-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun wait-until (seconds predicate)
  "Poll PREDICATE every 10 ms for SECONDS at most. → its value or NIL."
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        for v = (funcall predicate)
        when v return v
        while (< (get-internal-real-time) deadline)
        do (sleep 0.01)))

(defstruct (outcome (:constructor %make-outcome ()))
  "What a background call did: VALUES or the CONDITION it signalled. DONE is
set last."
  (values nil) (condition nil) (done nil) (thread nil))

(defun in-background (thunk &key (name "acp test call"))
  "Run THUNK on a new thread. → an OUTCOME."
  (let ((o (%make-outcome)))
    (setf (outcome-thread o)
          (bt2:make-thread
           (lambda ()
             (unwind-protect
                  (handler-case (setf (outcome-values o) (multiple-value-list (funcall thunk)))
                    (serious-condition (c) (setf (outcome-condition o) c)))
               (setf (outcome-done o) t)))
           :name name))
    o))

(defun await (outcome seconds)
  "Wait for OUTCOME. → T when it finished within SECONDS."
  (and (wait-until seconds (lambda () (outcome-done outcome))) t))

(defun call-within (seconds thunk)
  "→ (values value condition finished-p): THUNK on a thread, waited SECONDS."
  (let ((o (in-background thunk)))
    (if (await o seconds)
        (values (first (outcome-values o)) (outcome-condition o) t)
        (values nil nil nil))))

;;; --- test client -------------------------------------------------------------------

(defclass test-client (acp:acp-client)
  ((lock :initform (bt2:make-lock :name "test client") :reader client-lock)
   (updates :initform '() :documentation "SESSION-NOTIFICATIONs, newest first.")
   (files :initform (make-hash-table :test 'equal) :reader client-files)
   (calls :initform '() :documentation "Method names, newest first.")
   (permission :initarg :permission :initform 'acp:allow-once :accessor client-permission
               :documentation "Restart invoked for ACP-PERMISSION-REQUIRED (with
PERMISSION-ARGS), or NIL to leave it unhandled.")
   (permission-args :initarg :permission-args :initform '() :accessor client-permission-args)
   (on-permission :initarg :on-permission :initform nil :accessor client-on-permission
                  :documentation "(lambda (client request)) run first, e.g. a session/cancel.")
   (remote :initform nil :accessor client-remote
           :documentation "The REMOTE-AGENT, set once connected.")
   (threads :initform '() :documentation "Threads the GFs ran on, newest first.")))

(defun %record (client slot value)
  (bt2:with-lock-held ((client-lock client))
    (push value (slot-value client slot))))

(defun client-updates (client)
  "The SESSION-NOTIFICATIONs received, oldest first."
  (bt2:with-lock-held ((client-lock client))
    (reverse (slot-value client 'updates))))

(defun client-update-objects (client)
  (mapcar #'acp:update (client-updates client)))

(defun update-tags (client)
  (mapcar #'acp:session-update (client-update-objects client)))

(defun update-texts (client)
  "The text of every agent_message_chunk, oldest first."
  (loop for u in (client-update-objects client)
        when (typep u 'acp:update-agent-message-chunk)
          collect (acp:text (acp:content u))))

(defun client-calls (client)
  (bt2:with-lock-held ((client-lock client))
    (reverse (slot-value client 'calls))))

(defmethod acp:acp-session-update ((client test-client) notification)
  (%record client 'threads (bt2:current-thread))
  (%record client 'updates notification))

(defmethod acp:acp-request-permission :around ((client test-client) request)
  (%record client 'calls "session/request_permission")
  (when (client-on-permission client)
    (funcall (client-on-permission client) client request))
  (let ((restart (client-permission client)))
    (if restart
        (handler-bind ((acp:acp-permission-required
                         (lambda (c)
                           (apply #'invoke-restart (find-restart restart c)
                                  (client-permission-args client)))))
          (call-next-method))
        (call-next-method))))

(defmethod acp:acp-read-text-file ((client test-client) request)
  (%record client 'calls "fs/read_text_file")
  (let ((text (gethash (acp:path request) (client-files client))))
    (unless text
      (error 'acp:acp-resource-not-found :data (js "path" (acp:path request))))
    (acp:make-acp 'acp:read-text-file-response :content text)))

(defmethod acp:acp-write-text-file ((client test-client) request)
  (%record client 'calls "fs/write_text_file")
  (setf (gethash (acp:path request) (client-files client)) (acp:content request))
  (acp:make-acp 'acp:write-text-file-response))

(defmethod acp:acp-create-terminal ((client test-client) request)
  (%record client 'calls "terminal/create")
  (acp:make-acp 'acp:create-terminal-response
                :terminal-id (format nil "term-~A" (acp:command request))))

(defmethod acp:acp-wait-for-terminal-exit ((client test-client) request)
  (declare (ignore request))
  (%record client 'calls "terminal/wait_for_exit")
  (acp:make-acp 'acp:wait-for-terminal-exit-response :exit-code 0))

(defmethod acp:acp-release-terminal ((client test-client) request)
  (declare (ignore request))
  (%record client 'calls "terminal/release")
  (acp:make-acp 'acp:release-terminal-response))

;;; --- requests ----------------------------------------------------------------------

(defparameter *full-client-caps*
  "{\"fs\":{\"readTextFile\":true,\"writeTextFile\":true},\"terminal\":true}")

(defun initialize (ra &key (caps *full-client-caps*))
  (acp:acp-initialize
   ra (acp:make-acp 'acp:initialize-request
                    :protocol-version 1
                    :client-capabilities (and caps (acp:parse-acp-object
                                                    'acp:client-capabilities (json caps)))
                    :client-info (acp:make-acp 'acp:implementation
                                               :name "test-client" :version "0.0.1"))))

(defun new-session (ra)
  (acp:session-id (acp:acp-new-session ra (acp:make-acp 'acp:new-session-request
                                                        :cwd "/work" :mcp-servers #()))))

(defun prompt-request (session-id text)
  (acp:make-acp 'acp:prompt-request
                :session-id session-id
                :prompt (vector (acp:make-acp 'acp:text-content :text text))))

(defun prompt (ra session-id text)
  (acp:acp-prompt ra (prompt-request session-id text)))

(defun cancel (ra session-id)
  (acp:acp-cancel ra (acp:make-acp 'acp:cancel-notification :session-id session-id)))

(defun transport-of (remote)
  (acp:acp-connection-transport (acp:remote-connection remote)))

;;; --- in-process pair ---------------------------------------------------------------

(defstruct pair
  ra connection agent client serve)

(defun open-pair (&key (client (make-instance 'test-client))
                       (agent (make-instance 'fx:scripted-agent))
                       (agent-dispatch nil agent-dispatch-p)
                       (client-dispatch nil client-dispatch-p))
  "SERVE-ACP-AGENT on a thread, CONNECT-ACP-STREAMS here, over two pipes."
  (multiple-value-bind (agent-in client-out) (rbs:make-stdio-pipe)
    (multiple-value-bind (client-in agent-out) (rbs:make-stdio-pipe)
      (let* ((serve (in-background
                     (lambda ()
                       (apply #'stdio:serve-acp-agent agent :input agent-in :output agent-out
                              (and agent-dispatch-p (list :dispatch agent-dispatch))))
                     :name "serve-acp-agent")))
        (multiple-value-bind (connection ra)
            (apply #'stdio:connect-acp-streams client client-in client-out
                   (and client-dispatch-p (list :dispatch client-dispatch)))
          (when (typep client 'test-client)
            (setf (client-remote client) ra))
          (make-pair :ra ra :connection connection :agent agent :client client
                     :serve serve))))))

(defun close-pair (pair)
  "Close the client side; the agent's SERVE-ACP-AGENT returns at EOF.
→ T when it did within 10 s."
  (ignore-errors (stdio:close-acp-connection (pair-connection pair) :timeout 5))
  (await (pair-serve pair) 10))

(defmacro with-pair ((pair &rest keys) &body body)
  `(let ((,pair (open-pair ,@keys)))
     (unwind-protect (progn ,@body)
       (close-pair ,pair))))

(defun session-of (pair &key (caps *full-client-caps*))
  "Initialize PAIR and open a session. → the session id."
  (initialize (pair-ra pair) :caps caps)
  (new-session (pair-ra pair)))

;;; --- raw agent (framing) -----------------------------------------------------------

(defstruct raw
  in out serve agent)

(defun open-raw-agent (&key (agent (make-instance 'fx:scripted-agent)))
  "SERVE-ACP-AGENT on a thread; the test writes to RAW-OUT and reads RAW-IN."
  (multiple-value-bind (agent-in test-out) (rbs:make-stdio-pipe :capacity 65536)
    (multiple-value-bind (test-in agent-out) (rbs:make-stdio-pipe :capacity 65536)
      (make-raw :in test-in :out test-out :agent agent
                :serve (in-background
                        (lambda () (stdio:serve-acp-agent agent :input agent-in
                                                                :output agent-out))
                        :name "serve-acp-agent raw")))))

(defun raw-send (raw text &key (newline t))
  (write-string text (raw-out raw))
  (when newline (write-char #\Newline (raw-out raw)))
  (finish-output (raw-out raw)))

(defun raw-line (raw &optional (seconds 10))
  "The next line the agent wrote, or NIL when none came within SECONDS (or EOF)."
  (when (outcome-condition (raw-serve raw))   ; serving failed: nothing will come
    (return-from raw-line nil))
  (multiple-value-bind (line condition finished) (call-within seconds
                                                              (lambda ()
                                                                (read-line (raw-in raw) nil nil)))
    (declare (ignore condition))
    (and finished line)))

(defun raw-message (raw &optional (seconds 10))
  "The next line, decoded, or NIL."
  (let ((line (raw-line raw seconds)))
    (and line (json line))))

(defun raw-close-input (raw)
  (close (raw-out raw)))

(defun close-raw (raw)
  "EOF to the agent. → T when SERVE-ACP-AGENT returned within 10 s."
  (ignore-errors (close (raw-out raw)))
  (prog1 (await (raw-serve raw) 10)
    (ignore-errors (close (raw-in raw)))))

(defmacro with-raw-agent ((raw &rest keys) &body body)
  `(let ((,raw (open-raw-agent ,@keys)))
     (unwind-protect (progn ,@body)
       (close-raw ,raw))))

(defparameter *raw-initialize*
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}")

(defun raw-initialize (raw)
  (raw-send raw *raw-initialize*)
  (raw-message raw))

(defun error-code (message)
  (let ((e (and (hash-table-p message) (gethash "error" message))))
    (and (hash-table-p e) (gethash "code" e))))

(defun response-id (message)
  (and (hash-table-p message) (gethash "id" message)))

;;; --- child agents ------------------------------------------------------------------

(defparameter *agent-main*
  (asdf:system-relative-pathname "acp-backend-stdio" "tests/fixtures/agent-main.lisp"))

(defun child-argv ()
  "An SBCL child running the scripted agent: this image's runtime and core."
  #+sbcl (list (uiop:native-namestring sb-ext:*runtime-pathname*)
               "--core" (uiop:native-namestring sb-ext:*core-pathname*)
               "--script" (uiop:native-namestring *agent-main*))
  #-sbcl (error "the child agent fixture needs SBCL"))

(defun child-source-registry ()
  "CL_SOURCE_REGISTRY for the child: the directory of every system this image
loaded, so the child finds the same acp-backend-stdio and dependencies."
  (let ((dirs (remove-duplicates
               (loop for name in (asdf:already-loaded-systems)
                     for dir = (ignore-errors
                                (asdf:system-source-directory (asdf:find-system name nil)))
                     when dir collect (uiop:native-namestring dir))
               :test #'equal)))
    (format nil "(:source-registry ~{(:directory ~s) ~}:ignore-inherited-configuration)" dirs)))

(defun child-env (&rest more)
  (list* (cons "CL_SOURCE_REGISTRY" (child-source-registry)) more))

(defparameter *child-start-seconds* 120
  "Deadline for a child's first answer: it loads acp-backend-stdio first.")

(defmacro with-child ((connection ra &key (client '(make-instance 'test-client)) env
                                          directory error-output)
                      &body body)
  "Spawn the scripted agent; BODY; close the connection (bounded)."
  (let ((c (gensym "CLIENT")))
    `(let ((,c ,client))
       (multiple-value-bind (,connection ,ra)
           (stdio:spawn-acp-agent (child-argv)
                                  :client ,c
                                  :env (child-env ,@(mapcar (lambda (e) `(quote ,e)) env))
                                  ,@(and directory `(:directory ,directory))
                                  ,@(and error-output `(:error-output ,error-output)))
         (when (typep ,c 'test-client) (setf (client-remote ,c) ,ra))
         (unwind-protect (progn ,@body)
           (call-within 30 (lambda ()
                             (stdio:close-acp-connection ,connection :timeout 5))))))))

(defun initialize-child (ra &key (caps *full-client-caps*))
  "INITIALIZE with the child's start-up deadline. → the response, or NIL."
  (values (call-within *child-start-seconds* (lambda () (initialize ra :caps caps)))))
