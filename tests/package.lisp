(defpackage #:acp-backend-stdio/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:acp #:acp-protocol) (#:stdio #:acp-backend-stdio)
                    (#:rbs #:rpc-backend-stdio) (#:fx #:acp-stdio-fixture)))

(in-package #:acp-backend-stdio/tests)
