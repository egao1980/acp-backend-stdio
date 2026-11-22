# acp-backend-stdio

stdio transport for [`acp-protocol`](https://github.com/egao1980/acp-protocol):
newline-delimited JSON-RPC 2.0 over the agent process's stdin / stdout, through
`rpc-backend-stdio`. This is the transport editors (Zed, Emacs agent-shell, …)
use to launch an ACP agent.

Brief: [cl-stack/docs/capabilities/acp.md](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/acp.md).

Status: **0.1.0 contracted** (ACP-1): `serve-acp-agent`, `stop-acp-agent`,
`spawn-acp-agent`, `connect-acp-streams`, `wait-acp-connection`,
`close-acp-connection`. The rules are in the header of `src/backend.lisp`;
the tests run the scripted agent in-process over pipes and as a child SBCL.
