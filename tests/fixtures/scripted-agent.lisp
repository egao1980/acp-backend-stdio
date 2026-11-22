;;; The scripted ACP agent of the tests. Loaded two ways:
;;;   * as a component of acp-backend-stdio/tests, served in-process by
;;;     SERVE-ACP-AGENT over pipes (pair-test, framing-test);
;;;   * by fixtures/agent-main.lisp in a child SBCL (--script), served on the
;;;     child's real stdin / stdout (subprocess-test).
;;; Depends on acp-protocol and acp-backend-stdio only (no Rove).
;;;
;;; The prompt's first text block picks the script:
;;;   "work"  message, thought, tool_call; permission (allow_once /
;;;           allow_always / reject_once); fs read + write of /w/a.txt and a
;;;           terminal (each only when the client advertises it); tool_call_update
;;;           with a diff; plan; commands; a PRINT to *standard-output* and a
;;;           line on *error-output*; a final message
;;;           "permission <kind> read <old or none>"; end_turn.
;;;   "ask"   permission only (four options); message "permission <kind>";
;;;           stopReason "cancelled" when the answer was cancelled.
;;;   "wait"  message "waiting", then waits (60 s at most) until session/cancel
;;;           for this session arrives → ACP-REQUEST-CANCELLED.
;;;   "burst" 200 agent_message_chunk updates "0" … "199".
;;;   "text:<s>" one agent_message_chunk whose text is <s>.
;;;   "pwd"   message: the native namestring of the working directory.
;;;   "env"   message: the value of ACP_FIXTURE_VALUE.
;;;   "boom"  signals a plain ERROR "boom".
;;;   else    end_turn.
;;; Extension requests: _cl-stack.test/echo → {"echo": params};
;;; _cl-stack.test/sleep → waits (30 s at most), noting :sleeping, → "slept".
;;; logout (advertised) → STOP-ACP-AGENT on the connection.

(defpackage #:acp-stdio-fixture
  (:use #:cl)
  (:local-nicknames (#:acp #:acp-protocol) (#:stdio #:acp-backend-stdio))
  (:export #:scripted-agent #:agent-events #:agent-event #:agent-cancelled
           #:agent-connection #:main #:js))

(in-package #:acp-stdio-fixture)

(defun js (&rest kvs)
  "A JSON object (EQUAL hash-table) from alternating keys and values."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defclass scripted-agent (acp:acp-agent)
  ((lock :initform (bt2:make-lock :name "scripted agent") :reader agent-lock)
   (events :initform '() :documentation "Newest first, under LOCK.")
   (sessions :initform '())
   (cancelled :initform '() :documentation "Session ids, under LOCK.")
   (connection :initform nil :accessor agent-connection
               :documentation "*ACP-CONNECTION* seen at initialize.")))

(defun note (agent &rest event)
  (bt2:with-lock-held ((agent-lock agent))
    (push event (slot-value agent 'events))))

(defun agent-events (agent)
  (bt2:with-lock-held ((agent-lock agent))
    (copy-list (slot-value agent 'events))))

(defun agent-event (agent key)
  (find key (agent-events agent) :key #'first))

(defun agent-cancelled (agent)
  (bt2:with-lock-held ((agent-lock agent))
    (copy-list (slot-value agent 'cancelled))))

(defun %wait-for (seconds predicate)
  "Poll PREDICATE every 10 ms for SECONDS at most. → its value or NIL."
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        for v = (funcall predicate)
        when v return v
        while (< (get-internal-real-time) deadline)
        do (sleep 0.01)))

(defun %text (s) (acp:make-acp 'acp:text-content :text s))

(defun %say (sid s)
  (acp:acp-send-update acp:*acp-remote* sid
                       (acp:make-acp 'acp:update-agent-message-chunk :content (%text s))))

(defun %end (&optional (reason "end_turn"))
  (acp:make-acp 'acp:prompt-response :stop-reason reason))

(defun %options (&rest kinds)
  (mapcar (lambda (k) (acp:make-acp 'acp:permission-option :option-id k :name k :kind k))
          kinds))

(defun %client-has (feature)
  (acp:client-supports-p (acp:acp-connection-client-capabilities acp:*acp-connection*)
                         feature))

(defmethod acp:acp-initialize ((agent scripted-agent) request)
  (setf (agent-connection agent) acp:*acp-connection*)
  (note agent :initialize request)
  (acp:make-acp 'acp:initialize-response
                :agent-capabilities
                (acp:parse-acp-object 'acp:agent-capabilities
                                      (json-protocol:decode "{\"auth\":{\"logout\":{}}}"))
                :agent-info (acp:make-acp 'acp:implementation
                                          :name "scripted-agent" :version "0.1.0")))

(defmethod acp:acp-logout ((agent scripted-agent) request)
  (declare (ignore request))
  (note agent :logout)
  (stdio:stop-acp-agent acp:*acp-connection*)
  (acp:make-acp 'acp:logout-response))

(defmethod acp:acp-new-session ((agent scripted-agent) request)
  (let ((id (bt2:with-lock-held ((agent-lock agent))
              (let ((id (format nil "sess-~D" (1+ (length (slot-value agent 'sessions))))))
                (push id (slot-value agent 'sessions))
                id))))
    (note agent :new-session (acp:cwd request))
    (acp:make-acp 'acp:new-session-response :session-id id)))

(defmethod acp:acp-cancel ((agent scripted-agent) notification)
  (bt2:with-lock-held ((agent-lock agent))
    (push (acp:session-id notification) (slot-value agent 'cancelled)))
  (note agent :cancel (acp:session-id notification)))

(defmethod acp:acp-cancel-request ((agent scripted-agent) notification)
  (note agent :cancel-request (acp:request-id notification)))

(defmethod acp:acp-ext-method ((agent scripted-agent) method params)
  (cond ((equal method "_cl-stack.test/echo") (js "echo" params))
        ((equal method "_cl-stack.test/sleep")
         (note agent :sleeping)
         (%wait-for 30 (constantly nil))
         "slept")
        (t (call-next-method))))

(defun %work (agent sid)
  (let ((rc acp:*acp-remote*) (old nil))
    (%say sid "Looking")
    (acp:acp-send-update rc sid (acp:make-acp 'acp:update-agent-thought-chunk
                                              :content (%text "need to read")))
    (acp:acp-send-update rc sid (acp:make-acp 'acp:update-tool-call
                                              :tool-call-id "t1" :title "Edit a.txt"
                                              :kind "edit" :status "pending"))
    (multiple-value-bind (kind option)
        (acp:acp-ask-permission rc sid
                                (acp:make-acp 'acp:tool-call-update :tool-call-id "t1"
                                                                    :title "Edit a.txt")
                                (%options "allow_once" "allow_always" "reject_once"))
      (note agent :permission kind option)
      ;; stray output: must not reach the ACP stream
      (print :stray-output-on-stdout)
      (format *error-output* "~&scripted-agent: permission ~(~a~)~%" kind)
      (finish-output *error-output*)
      (when (%client-has :read-text-file)
        (setf old (acp:content (acp:acp-read-text-file
                                rc (acp:make-acp 'acp:read-text-file-request
                                                 :session-id sid :path "/w/a.txt"))))
        (note agent :read old))
      (when (%client-has :write-text-file)
        (acp:acp-write-text-file rc (acp:make-acp 'acp:write-text-file-request
                                                  :session-id sid :path "/w/a.txt"
                                                  :content "new")))
      (when (%client-has :terminal)
        (let* ((tid (acp:terminal-id (acp:acp-create-terminal
                                      rc (acp:make-acp 'acp:create-terminal-request
                                                       :session-id sid :command "make"))))
               (exit (acp:acp-wait-for-terminal-exit
                      rc (acp:make-acp 'acp:wait-for-terminal-exit-request
                                       :session-id sid :terminal-id tid))))
          (note agent :terminal tid (acp:exit-code exit))
          (acp:acp-release-terminal rc (acp:make-acp 'acp:release-terminal-request
                                                     :session-id sid :terminal-id tid))))
      (acp:acp-send-update rc sid
                           (acp:make-acp 'acp:update-tool-call-update
                                         :tool-call-id "t1" :status "completed"
                                         :content (vector (acp:make-acp 'acp:diff
                                                                        :path "/w/a.txt"
                                                                        :old-text (or old "")
                                                                        :new-text "new"))))
      (acp:acp-send-update rc sid
                           (acp:make-acp 'acp:update-plan
                                         :entries (vector (acp:make-acp 'acp:plan-entry
                                                                        :content "edit a.txt"
                                                                        :priority "high"
                                                                        :status "completed"))))
      (acp:acp-send-update rc sid
                           (acp:make-acp 'acp:update-available-commands-update
                                         :available-commands
                                         (vector (acp:make-acp 'acp:available-command
                                                               :name "test"
                                                               :description "run tests"))))
      (%say sid (format nil "permission ~(~a~) read ~a" kind (or old "none")))
      (%end))))

(defmethod acp:acp-prompt ((agent scripted-agent) request)
  (let* ((sid (acp:session-id request))
         (first (and (plusp (length (acp:prompt request))) (aref (acp:prompt request) 0)))
         (text (if (typep first 'acp:text-content) (acp:text first) "")))
    (unless (bt2:with-lock-held ((agent-lock agent))
              (member sid (slot-value agent 'sessions) :test #'equal))
      (error 'acp:acp-resource-not-found :message "Resource not found"
                                         :data (js "sessionId" sid)))
    (note agent :prompt sid text)
    (cond
      ((string= text "work") (%work agent sid))
      ((string= text "ask")
       (let ((kind (acp:acp-ask-permission
                    acp:*acp-remote* sid
                    (acp:make-acp 'acp:tool-call-update :tool-call-id "t9" :title "rm -rf build")
                    (%options "allow_once" "allow_always" "reject_once" "reject_always"))))
         (note agent :permission kind)
         (%say sid (format nil "permission ~(~a~)" kind))
         (%end (if (eq kind :cancelled) "cancelled" "end_turn"))))
      ((string= text "wait")
       (%say sid "waiting")
       (if (%wait-for 60 (lambda () (member sid (agent-cancelled agent) :test #'equal)))
           (error 'acp:acp-request-cancelled)
           (%end "end_turn")))
      ((string= text "burst")
       (dotimes (i 200) (%say sid (princ-to-string i)))
       (%end))
      ((and (> (length text) 5) (string= "text:" text :end2 5))
       (%say sid (subseq text 5))
       (%end))
      ((string= text "pwd")
       (%say sid (uiop:native-namestring (uiop:getcwd)))
       (%end))
      ((string= text "env")
       (%say sid (or (uiop:getenv "ACP_FIXTURE_VALUE") "unset"))
       (%end))
      ((string= text "boom") (error "boom"))
      (t (%end)))))

(defun main ()
  "The child's entry: serve on stdin / stdout; ACP_FIXTURE_MODE=hang ignores
EOF afterwards (a hung agent the client must kill). Exit 0."
  (stdio:serve-acp-agent (make-instance 'scripted-agent))
  (when (equal (uiop:getenv "ACP_FIXTURE_MODE") "hang")
    (loop (sleep 3600)))
  (uiop:quit 0))
