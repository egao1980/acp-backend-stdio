;;; The child agent of subprocess-test: `sbcl --core <core> --script agent-main.lisp`.
;;; CL_SOURCE_REGISTRY (set by the parent) finds acp-backend-stdio and its
;;; dependencies. Everything printed while loading goes to stderr: stdout
;;; carries ACP only.

(require "asdf")
(let ((*standard-output* *error-output*))
  (asdf:load-system "acp-backend-stdio")
  (load (merge-pathnames "scripted-agent.lisp" *load-truename*)))
(funcall (intern "MAIN" "ACP-STDIO-FIXTURE"))
