# acp-backend-stdio

stdio transport for [`acp-protocol`](https://github.com/egao1980/acp-protocol):
newline-delimited JSON-RPC 2.0 over the agent process's stdin / stdout, through
`rpc-backend-stdio`. This is the transport editors (Zed, Emacs agent-shell, …)
use to launch an ACP agent.

Brief: [cl-stack/docs/capabilities/acp.md](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/acp.md).

Status: skeleton. ACP-1 (0.1.0) follows acp-protocol 0.1.0.
