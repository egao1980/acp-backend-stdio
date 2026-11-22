(defpackage #:acp-backend-stdio
  (:use #:cl)
  (:documentation "stdio transport for acp-protocol (ACP-1): newline-delimited JSON-RPC 2.0
over an agent process's stdin / stdout, and a client that spawns an agent subprocess
or connects to a pair of streams. Built on rpc-backend-stdio's peer mode.")
  (:export
   ;; connections
   #:acp-stdio-connection #:acp-stdio-connection-process
   ;; agent side
   #:serve-acp-agent #:stop-acp-agent
   ;; client side
   #:spawn-acp-agent #:connect-acp-streams #:wait-acp-connection #:close-acp-connection
   ;; defaults
   #:*agent-dispatch* #:*client-dispatch*))

(in-package #:acp-backend-stdio)

(define-condition acp1-pending (error)
  ((what :initarg :what :reader acp1-pending-what))
  (:report (lambda (c s)
             (format s "ACP-1 contract stub not implemented: ~S" (acp1-pending-what c)))))

(defun %acp1-pending (what)
  "Contract stub. Every call site is replaced by the ACP-1 implementation."
  (error 'acp1-pending :what what))
