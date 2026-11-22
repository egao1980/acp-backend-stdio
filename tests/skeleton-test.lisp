(in-package #:acp-backend-stdio/tests)

(deftest skeleton-status
  (ok (eq :skeleton acp-backend-stdio:+acp-stdio-backend-status+)))
