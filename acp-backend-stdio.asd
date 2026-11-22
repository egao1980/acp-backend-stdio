(defsystem "acp-backend-stdio"
  :version "0.0.0"
  :description "stdio transport backend for acp-protocol (newline-delimited JSON-RPC)"
  :author "egao1980"
  :license "MIT"
  :serial t
  :pathname "src"
  :components ((:file "package"))
  :in-order-to ((test-op (test-op "acp-backend-stdio/tests"))))

(defsystem "acp-backend-stdio/tests"
  :depends-on ("acp-backend-stdio" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "skeleton-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
