(in-package #:acp-backend-stdio/tests)

;;; 0.1.1 (egao1980/cl-stack-code#45): a client that writes requests after
;;; initialize without waiting for its answer (a replay harness, an eager
;;; client). Under :CONCURRENT dispatch they ran at once, before initialize
;;; had been handled, and were answered -32600 "Request before initialize".
;;; Initialize is slow here, so that race would always be lost.

(defclass slow-initialize-agent (fx:scripted-agent) ()
  (:documentation "The scripted agent, whose initialize takes 300 ms."))

(defmethod acp:acp-initialize :around ((agent slow-initialize-agent) request)
  (declare (ignore request))
  (sleep 0.3)
  (call-next-method))

(defun %raw-request (id method params-json)
  (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"method\":~s,\"params\":~a}" id method params-json))

(defparameter *raw-new-session-params* "{\"cwd\":\"/work\",\"mcpServers\":[]}")

(defun raw-messages (raw n &optional (seconds 10))
  "N decoded lines the agent wrote (fewer when one did not come in time)."
  (loop repeat n
        for m = (raw-message raw seconds)
        while m collect m))

(deftest pipeline-requests-after-initialize-are-handled-after-it
  (let ((agent (make-instance 'slow-initialize-agent)))
    (with-raw-agent (raw :agent agent)
      ;; back to back: nothing waits for the initialize answer
      (raw-send raw *raw-initialize*)
      (raw-send raw (%raw-request 2 "session/new" *raw-new-session-params*))
      (raw-send raw "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess-1\"}}")
      (raw-send raw (%raw-request 3 "session/new" *raw-new-session-params*))
      (let ((answers (raw-messages raw 3)))
        (ok (= 3 (length answers)) "three answers")
        (ok (eql 1 (response-id (first answers)))
            (format nil "the initialize answer first: ~s" (mapcar #'response-id answers)))
        (ok (equal '(2 3) (sort (mapcar #'response-id (rest answers)) #'<)))
        (ok (notany #'error-code answers)
            (format nil "no error answer: ~s" (mapcar #'error-code answers)))
        (ok (every (lambda (m)
                     (let ((r (gethash "result" m)))
                       (and (hash-table-p r) (stringp (gethash "sessionId" r)))))
                   (rest answers))
            "both sessions opened"))
      (ok (wait-until 5 (lambda () (fx:agent-cancelled agent)))
          "the pipelined notification reached the agent (not dropped as before initialize)")
      (ok (equal '("sess-1") (fx:agent-cancelled agent))))))

(deftest pipeline-a-request-before-initialize-is-still-refused
  ;; Only what comes after initialize on the wire waits for it.
  (with-raw-agent (raw :agent (make-instance 'slow-initialize-agent))
    (raw-send raw (%raw-request 7 "session/new" *raw-new-session-params*))
    (raw-send raw *raw-initialize*)
    (let ((answers (raw-messages raw 2)))
      (let ((early (find 7 answers :key #'response-id))
            (init (find 1 answers :key #'response-id)))
        (ok (eql -32600 (error-code early)) "a request before initialize on the wire: -32600")
        (ok (and init (null (error-code init))) "initialize answered")))))

(deftest pipeline-serial-dispatch-in-order-too
  (multiple-value-bind (agent-in test-out) (rbs:make-stdio-pipe :capacity 65536)
    (multiple-value-bind (test-in agent-out) (rbs:make-stdio-pipe :capacity 65536)
      (let* ((agent (make-instance 'slow-initialize-agent))
             (raw (make-raw :in test-in :out test-out :agent agent
                            :serve (in-background
                                    (lambda ()
                                      (stdio:serve-acp-agent agent :input agent-in
                                                                   :output agent-out
                                                                   :dispatch :serial))
                                    :name "serve-acp-agent serial"))))
        (unwind-protect
             (progn
               (raw-send raw *raw-initialize*)
               (raw-send raw (%raw-request 2 "session/new" *raw-new-session-params*))
               (let ((answers (raw-messages raw 2)))
                 (ok (equal '(1 2) (mapcar #'response-id answers)))
                 (ok (notany #'error-code answers))))
          (close-raw raw))))))
