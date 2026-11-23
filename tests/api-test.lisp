(in-package #:acp-backend-stdio/tests)

;;; The API surface: exports, version, defaults, argument validation.

(deftest exports-and-version
  (ok (equal "0.1.1" (asdf:component-version (asdf:find-system "acp-backend-stdio"))))
  (dolist (name '("SERVE-ACP-AGENT" "STOP-ACP-AGENT" "SPAWN-ACP-AGENT" "CONNECT-ACP-STREAMS"
                  "WAIT-ACP-CONNECTION" "CLOSE-ACP-CONNECTION" "ACP-STDIO-CONNECTION-PROCESS"))
    (multiple-value-bind (sym status) (find-symbol name "ACP-BACKEND-STDIO")
      (ok (and (eq status :external) (fboundp sym)) name)))
  (ok (subtypep 'stdio:acp-stdio-connection 'acp:acp-connection)))

(deftest dispatch-defaults
  (ok (eq :concurrent stdio:*agent-dispatch*)
      "agent: requests on their own threads, so session/cancel reaches a running prompt")
  (ok (eq :reader stdio:*client-dispatch*)
      "client: updates are handled before the response they precede"))

(deftest serve-refuses-reader-dispatch
  (multiple-value-bind (in out) (rbs:make-stdio-pipe)
    (declare (ignore out))
    (multiple-value-bind (in2 out2) (rbs:make-stdio-pipe)
      (declare (ignore in2))
      (ok (signals (stdio:serve-acp-agent (make-instance 'fx:scripted-agent)
                                          :input in :output out2 :dispatch :reader)
                   'type-error)
          ":reader would make every call back to the client fail"))))
