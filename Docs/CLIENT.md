# Client (`MCPClient`)

`MCPClient` is a client for MCP revision 2026-07-28 only (see ADR-0005). It keeps no
session: every request carries the protocol version and client capabilities in
`params._meta`, and every response and notification is validated against the frozen
2026-07-28 schema before it reaches the caller.

## Setup

```swift
let client = Client(transport: HTTPClientTransport(endpoint: url),       // MCPHTTPClient
    configuration: .init(info: clientInfo,
        elicitation: .init { params in try await askUser(params) },      // answers elicitation/create
        roots: { _ in try rootsJSON() }))
let server = try await client.discover()
let tools = try await client.listTools()
let result = try await client.callTool("search", arguments: arguments) { progress in show(progress) }
try await client.listen(filters) { event in handle(event) }             // subscriptions/listen
```

Transports:

- `HTTPClientTransport` (Swift-MCP-Server-HTTP): Streamable HTTP on AsyncHTTPClient.
- `StdioClientTransport` (`MCPClientStdio`, macOS and Linux): launches the server with
  swift-subprocess. The host runs `run()` in its own child task and calls `shutdown()`
  (closes the server's input) or cancels `run()` (SIGTERM, then SIGKILL after
  `terminationGrace`). Responses are routed by `id`, progress by `progressToken`, listen
  events by `subscriptionId`; log messages cannot be correlated on stdio and are dropped.
  Cancelling a call sends `notifications/cancelled`.
- `LoopbackTransport` (`MCPServerTesting`): in-process against a `Server`.

## Behavior

- **MRTR.** An `InputRequiredResult` is answered by the configured handlers
  (elicitation, sampling, roots); their results are validated, then the request is resent
  with `inputResponses` and the opaque `requestState`, up to `maximumInputRounds`.
  Declared capabilities follow from the handlers that are set. Input no handler answers is
  `ClientError.unsupportedInput`, never guessed.
- **Tool headers.** On Streamable HTTP, `x-mcp-header` parameters are mirrored into
  `Mcp-Param-*` headers with the specification's encoding; tools with invalid annotations
  are dropped from `tools/list` and listed in `rejectedTools`.
- **Raw values.** Typed views keep the raw JSON, so schemas pass through unchanged and are
  never dereferenced over the network.
- **Compatibility.** A result without `resultType` is `complete`. `-32022` is retried
  once when the server lists 2026-07-28, otherwise it is `ClientError.unsupportedProtocol`.
- **Errors.** JSON-RPC errors are `ClientError.server(code:message:data:)`;
  `requiredExtensions` reads the extensions a `-32021` names.
- **Concurrency.** `Client` is an actor; calls run concurrently on the caller's tasks and
  cancelling a call cancels its exchange. No detached tasks, no global state.

## Conformance

The client fixture in Swift-MCP-Server-HTTP passes all 8 non-authorization client
scenarios of `@modelcontextprotocol/conformance` 0.2.0-alpha.12 for 2026-07-28 (64 checks).

## Not yet implemented

- OAuth (`MCPClientAuthorization`), Tasks and Skills client helpers.
