# ``MCPClientStdio``

Launch and communicate with a local MCP server through a caller-owned subprocess lifetime.

## Overview

The transport implements newline-delimited JSON-RPC over stdin and stdout using Swift Subprocess. It is intended for supported process-launching hosts (macOS and Linux); iOS package availability does not imply subprocess support.

Create a ``StdioClientTransport`` and run it in a structured child task. Use the same instance for client exchanges. The host decides the executable, arguments, environment and lifecycle. Starting a run does not provide an implicit readiness handshake.

The transport routes messages by request identifier, progress token and subscription identifier, with finite message and pending-request bounds. Keep stdout reserved for protocol messages; stderr is the server's separate diagnostic stream.

Normal stdout EOF settles pending exchanges but does not release the child-run permit. The stdin writer and stderr reader are joined before the owning task returns. Successful completion requires a successfully reaped child. Nonzero or signal termination is exposed through ``StdioClientTransportError``; cancellation of the host run remains cancellation.

## Topics

### Transport

- ``StdioClientTransport``
- ``StdioClientTransportError``
- <doc:ChildProcessOwnership>
