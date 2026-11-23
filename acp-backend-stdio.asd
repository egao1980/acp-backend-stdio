(defsystem "acp-backend-stdio"
  :version "0.1.1"
  :description "stdio transport for acp-protocol: newline-delimited JSON-RPC over an agent process's stdin / stdout (serve-acp-agent) and a client that spawns or connects to an agent (spawn-acp-agent, connect-acp-streams), through rpc-backend-stdio peer mode; requests a client pipelines after initialize are handled after it"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "acp-protocol" "0.1.0")
               (:version "rpc-backend-stdio" "0.4.1")
               "rpc-protocol" "rpc-protocol-json"
               (:version "process-protocol" "0.4.0")
               (:version "process-backend-uiop" "0.3.4")
               "bordeaux-threads" "trivial-gray-streams")
  :properties (:cl-repo (:ci (:with ("dissect"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "backend"))
  :in-order-to ((test-op (test-op "acp-backend-stdio/tests"))))

(defsystem "acp-backend-stdio/tests"
  :depends-on ("acp-backend-stdio" "rove" "bordeaux-threads" (:version "json-protocol" "0.2.3")
               (:version "json-backend-jzon" "0.2.3"))
  :pathname "tests"
  :serial t
  :components (;; the scripted agent: in-process, and the child's (fixtures/agent-main.lisp)
               (:file "fixtures/scripted-agent")
               (:file "package")
               (:file "support")
               (:file "api-test")
               (:file "pair-test")
               (:file "framing-test")
               ;; 0.1.1 (cl-stack-code#45)
               (:file "pipeline-test")
               (:file "subprocess-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
