# Standalone stdio example

Requires macOS 27, Swift 6.4 (tools 6.4, language mode 6). Build and run:

```bash
swift run --package-path Examples/StdioServer ExampleStdioServer [--extensions]
```

The executable exposes echo, progress, wait, demo://greeting, greet and completion.
It selects a verified local demo principal and explicit finite configuration. Stdout
contains newline-delimited modern JSON-RPC frames only. Readiness/provider/shutdown
markers go to host-owned stderr. There is no initialize/ping/session or public client.

Send MCP2026-07-28 request metadata on each request. The real subprocess acceptance
cases include fragmented UTF8, coalesced requests, notification silence, malformed
input, cancellation, backpressure, EOF and SIGTERM. The executable explicitly owns
SIGTERM/SIGINT and joins its service/transport/provider. Embedding products do not
install process signals. Owned descriptors transfer only on successful construction.
The optional synthetic extension is described in Shared/ExampleCatalog.swift.
