(in-package #:acp-backend-stdio)

;;; ACP over stdio (contract ACP-1, 0.1.0).
;;;
;;; GIVEN: the package, ACP-STDIO-CONNECTION and its PROCESS reader, the
;;; dispatch defaults. STUBBED (%ACP1-PENDING): SERVE-ACP-AGENT,
;;; STOP-ACP-AGENT, SPAWN-ACP-AGENT, CONNECT-ACP-STREAMS,
;;; WAIT-ACP-CONNECTION, CLOSE-ACP-CONNECTION.
;;;
;;; Framing (ACP spec, Transports / stdio). One JSON-RPC 2.0 message per
;;; line, UTF-8, LF. A message never contains a raw newline: JSON-RPC text
;;; comes from rpc-protocol-json's encoder (through acp-protocol and
;;; rpc-backend-stdio), which escapes newlines, CR and every control
;;; character inside strings. A CR before the LF of an incoming line is
;;; accepted (JSON whitespace). Nothing but ACP messages is written to the
;;; agent's stdout or the client's pipe to it. stderr is for logs: the client
;;; passes the child's stderr through (:ERROR-OUTPUT) and never reads or
;;; parses it. Blank lines are ignored. Lines of any length are read whole
;;; (no size limit; > 1 MiB is tested).
;;;
;;; Transport. Both sides are rpc-backend-stdio peer-mode transports
;;; (MAKE-STDIO-RPC-TRANSPORT with :ON-REQUEST and :ON-NOTIFICATION, so the
;;; reader thread starts at once): ACP is symmetric, each side sends and
;;; answers requests on the same pair of streams. ON-REQUEST and
;;; ON-NOTIFICATION call ACP-PROTOCOL:ACP-CONNECTION-HANDLER of the side's
;;; connection with ACP-PROTOCOL:*ACP-INCOMING-KIND* bound to :REQUEST /
;;; :NOTIFICATION. Error mapping is acp-protocol's, unchanged: the handler's
;;; RPC-ERROR (from ACP-ERROR-FOR) goes on the wire with its code, message
;;; and data; on the calling side REMOTE-CALL re-signals it as the
;;; ACP-CONDITION-FOR the code, with RETRY / USE-VALUE.
;;;   Unparseable lines: answered -32700 "Parse error" with "id": null, and
;;;   non-object / bad-envelope lines -32600, then reading goes on. In peer
;;;   mode that answer is rpc-backend-stdio's job (#14, fixed in 0.3.1, the
;;;   version this system depends on). No second line parser here.
;;;
;;; Dispatch. The agent side defaults to :CONCURRENT (*AGENT-DISPATCH*):
;;;   * a session/prompt handler calls the client (session/request_permission,
;;;     fs/*, terminal/*) and waits for the answer, so handlers cannot run on
;;;     the reader thread (:READER makes that call fail with -32603);
;;;   * session/cancel and $/cancel_request are notifications that must reach
;;;     the agent WHILE its session/prompt handler runs. :SERIAL queues them
;;;     behind the running prompt, so a turn could never be cancelled.
;;;     :CONCURRENT runs each request on a thread of its own and every
;;;     notification on one dispatcher thread, in arrival order.
;;;   * Outgoing session/update notifications keep their order: an agent
;;;     sends them from its prompt thread, each line written whole under the
;;;     transport's write lock, and the client handles them in arrival order.
;;;   Consequence: an agent's requests may run concurrently (a session/new or
;;;   session/set_mode while a prompt runs); the agent's own state must be
;;;   thread-safe. :SERIAL is accepted (one request at a time; cancellation
;;;   only between requests); :READER is refused with a TYPE-ERROR.
;;; The client side defaults to :READER (*CLIENT-DISPATCH*): the client GFs
;;;   (session/update, session/request_permission, fs/*, terminal/*) run on
;;;   the reader thread, so every session/update the agent sent before a
;;;   response has been handled by the client when the call that waited for
;;;   that response returns (as on the loopback: "updates precede the prompt
;;;   response"). A client GF may send notifications (ACP-CANCEL from inside
;;;   a permission dialog) but must not call the agent and wait; a client that
;;;   needs that passes :DISPATCH :CONCURRENT and loses the ordering
;;;   guarantee between updates and responses.
;;; Threads and permission: a client GF runs on a transport thread, not in
;;;   the caller of ACP-PROMPT, so a HANDLER-BIND around the prompt call does
;;;   not see ACP-PERMISSION-REQUIRED. A client answers permission with a
;;;   method on ACP-REQUEST-PERMISSION (or a HANDLER-BIND inside one, around
;;;   CALL-NEXT-METHOD); unhandled → cancelled, as acp-protocol says.
;;;
;;; ACP-STDIO-CONNECTION: an ACP-PROTOCOL:ACP-CONNECTION whose TRANSPORT is a
;;;   RPC-BACKEND-STDIO:STDIO-RPC-TRANSPORT (or a subclass of it); PROCESS is
;;;   the spawned agent's PROCESS-PROTOCOL handle, or NIL.
;;;
;;; SERVE-ACP-AGENT AGENT &key INPUT OUTPUT (DISPATCH *AGENT-DISPATCH*)
;;;     → the connection (role :agent, local AGENT), once serving ended.
;;;   Serves AGENT (an ACP-PROTOCOL:ACP-AGENT) on INPUT / OUTPUT, default the
;;;   process's stdin / stdout as UTF-8 character streams (on SBCL fd 0 / 1;
;;;   the defaulted streams are flushed, never closed). While AGENT's GFs
;;;   run, ACP-PROTOCOL:*ACP-REMOTE* is the client proxy, so the agent
;;;   streams with (ACP-SEND-UPDATE *ACP-REMOTE* …) and asks with
;;;   (ACP-ASK-PERMISSION *ACP-REMOTE* …). In every handler thread
;;;   *STANDARD-OUTPUT* is *ERROR-OUTPUT* (the value when serving started),
;;;   so a stray PRINT in agent code goes to stderr, never into the ACP
;;;   stream. Blocks the calling thread until either
;;;     * INPUT reaches EOF (the client closed our stdin, or went away) and the
;;;       handlers already started have finished (their answers are written
;;;       while OUTPUT is writable), or
;;;     * STOP-ACP-AGENT was called on the connection.
;;;   Then the transport is closed (given streams are closed, so the client
;;;   sees EOF) and the connection returned. Errors inside handlers never
;;;   escape: they are answers. There is no ACP shutdown method in stable v1
;;;   and `logout` ends authentication, not the connection; an agent that
;;;   wants to exit on logout calls STOP-ACP-AGENT from its ACP-LOGOUT method.
;;; STOP-ACP-AGENT CONNECTION → T. Callable from a handler (the answer of the
;;;   request that called it is still written) or any other thread; SERVE-
;;;   ACP-AGENT returns soon after, without handling later messages.
;;;   Idempotent.
;;;
;;; Cancellation (agent side).
;;;   session/cancel → ACP-CANCEL on the dispatcher thread while the prompt
;;;     runs (:CONCURRENT); the agent ends its turn and ACP-PROMPT returns or
;;;     signals ACP-REQUEST-CANCELLED → stopReason "cancelled" (acp-protocol).
;;;   $/cancel_request {requestId} → ACP-CANCEL-REQUEST on the agent (its GF,
;;;     default ignore), then, when a request with that id is still running
;;;     here, ACP-REQUEST-CANCELLED is signalled in that request's thread
;;;     (BT2:INTERRUPT-THREAD), so a handler blocked waiting for the client
;;;     unwinds: the request is answered -32800, a session/prompt with
;;;     stopReason "cancelled". The running id is RPC-BACKEND-STDIO:
;;;     *STDIO-RPC-REQUEST-ID*, compared with EQUAL to requestId. An unknown or
;;;     finished id is ignored. Client side: $/cancel_request reaches the
;;;     client's ACP-CANCEL-REQUEST GF only (the client's handlers run on the
;;;     reader, there is no request thread to interrupt).
;;;
;;; SPAWN-ACP-AGENT ARGV &key ENV DIRECTORY CLIENT (DISPATCH *CLIENT-DISPATCH*)
;;;     (ERROR-OUTPUT :INTERACTIVE) → (values CONNECTION REMOTE-AGENT).
;;;   ARGV a list of strings (program and arguments, no shell). Launches it
;;;   with PROCESS-PROTOCOL:LAUNCH (:INPUT / :OUTPUT pipes, UTF-8, ENV merged
;;;   into the inherited environment, DIRECTORY the child's working
;;;   directory, ERROR-OUTPUT the child's stderr: :INTERACTIVE = ours, or a
;;;   pathname; never a pipe nobody drains; :PROCESS-GROUP T when the backend
;;;   supports it, so a kill reaches the agent's own children). The child's
;;;   stdout / stdin become the transport's INPUT / OUTPUT (the launch is
;;;   ours, not the transport's :COMMAND, which takes no ENV or DIRECTORY).
;;;   CLIENT (default a fresh ACP-PROTOCOL:ACP-CLIENT) implements the
;;;   client-side GFs; CONNECTION has role :client; REMOTE-AGENT is its proxy,
;;;   on which the caller runs ACP-INITIALIZE, ACP-NEW-SESSION, ACP-PROMPT, …
;;;   Nothing is sent before the caller's first call. On Windows no handle of
;;;   the parent leaks into the child (process-backend-uiop 0.3.4).
;;;   The agent dies or closes its stdout: every call waiting for it, and every
;;;   later call, signals ACP-PROTOCOL:ACP-INTERNAL-ERROR (-32603) whose
;;;   message says the agent exited and names its exit code, and whose DATA is
;;;   a JSON object with "exitCode" (an integer, or :NULL when unknown, e.g.
;;;   killed by a signal) — within a few seconds, never a hang.
;;; CONNECT-ACP-STREAMS CLIENT INPUT OUTPUT &key (DISPATCH *CLIENT-DISPATCH*)
;;;     → (values CONNECTION REMOTE-AGENT). The same over streams that exist:
;;;   INPUT carries the agent's messages, OUTPUT goes to the agent. No
;;;   process; a closed INPUT gives the same ACP-INTERNAL-ERROR without
;;;   "exitCode".
;;; WAIT-ACP-CONNECTION CONNECTION &key TIMEOUT → the child's exit code (an
;;;   integer) once the agent's output reached EOF and the child exited, T for
;;;   a stream connection once INPUT reached EOF, or NIL when TIMEOUT seconds
;;;   passed first. Does not close or kill.
;;; CLOSE-ACP-CONNECTION CONNECTION &key (TIMEOUT 5) FORCE → the child's exit
;;;   code (an integer, or NIL when the OS reports none), or T without a
;;;   process. Closes our side (the agent sees EOF on its stdin and exits),
;;;   waits up to TIMEOUT seconds for the child to exit, then kills it
;;;   (PROCESS-PROTOCOL:KILL :FORCE T, :TREE T with a process group; FORCE: at
;;;   once). Calls still waiting signal the ACP-INTERNAL-ERROR above. Always
;;;   returns within TIMEOUT + 10 seconds: no wait in here is unbounded, even
;;;   when another process still holds the child's stdout (rpc-backend-stdio
;;;   #12) or closing a stream under a blocked reader hangs (#10, Windows);
;;;   such a stream is abandoned with a WARNING rather than waited for.
;;;   Since rpc-backend-stdio 0.3.1 the transport's own close is bounded too
;;;   (#12: a :GRACE option, default 3 s, then the warning
;;;   STDIO-RPC-PIPE-HELD); the TIMEOUT + 10 s bound here stays the contract.
;;;   Idempotent: a second call returns the same value.
;;;   On an agent connection (from SERVE-ACP-AGENT) it closes the transport.

(defvar *agent-dispatch* :concurrent
  "SERVE-ACP-AGENT's default :DISPATCH (:CONCURRENT or :SERIAL).")

(defvar *client-dispatch* :reader
  "SPAWN-ACP-AGENT's and CONNECT-ACP-STREAMS' default :DISPATCH.")

(defclass acp-stdio-connection (acp-protocol:acp-connection)
  ((process :initarg :process :initform nil :reader acp-stdio-connection-process
            :documentation "The spawned agent's PROCESS-PROTOCOL handle, or NIL."))
  (:documentation "An ACP connection over an rpc-backend-stdio transport."))

(defun serve-acp-agent (agent &key input output (dispatch *agent-dispatch*))
  (declare (ignore agent input output dispatch))
  (%acp1-pending 'serve-acp-agent))

(defun stop-acp-agent (connection)
  (declare (ignore connection))
  (%acp1-pending 'stop-acp-agent))

(defun spawn-acp-agent (argv &key env directory client (dispatch *client-dispatch*)
                                  (error-output :interactive))
  (declare (ignore argv env directory client dispatch error-output))
  (%acp1-pending 'spawn-acp-agent))

(defun connect-acp-streams (client input output &key (dispatch *client-dispatch*))
  (declare (ignore client input output dispatch))
  (%acp1-pending 'connect-acp-streams))

(defun wait-acp-connection (connection &key timeout)
  (declare (ignore connection timeout))
  (%acp1-pending 'wait-acp-connection))

(defun close-acp-connection (connection &key (timeout 5) force)
  (declare (ignore connection timeout force))
  (%acp1-pending 'close-acp-connection))
