# Client (`MCPClient`)

`MCPClient` is a client for MCP revision 2026-07-28 only (see ADR-0005). It keeps no
session: every request carries the protocol version and client capabilities in
`params._meta`, and every response and notification is validated against the frozen
2026-07-28 schema before it reaches the caller.

## Setup

```swift
let client = Client(transport: HTTPClientTransport(endpoint: url),       // MCPHTTPClient
    configuration: .init(info: clientInfo,
        elicitation: .init { request in try await askUser(request) },    // -> .accept(content:), .decline, .cancel
        sampling: { request in try .text(try await model(request), model: "local") },
        roots: { [Root(uri: "file:///Users/me/project", name: "project")] }))
let server = try await client.discover()                                 // server.serverInfo?.name
let tools = try await client.listTools()
let result = try await client.callTool("search", arguments: arguments) { progress in show(progress) }
for block in result.content { if case .text(let text) = block { print(text) } }
let contents = try await client.readResource("file:///readme")           // [.text(...)] or [.blob(...)]
let prompt = try await client.getPrompt("review", arguments: ["code": source])
let options = try await client.complete(.prompt(name: "review"), argument: "language", value: "sw")
try await client.listen(SubscriptionFilter(toolsListChanged: true)) { event in handle(event) }
```

Transports:

- `HTTPClientTransport` (Swift-MCP-Server-HTTP): Streamable HTTP on AsyncHTTPClient.
- `StdioClientTransport` (`MCPClientStdio`, macOS and Linux): launches the server with
  swift-subprocess. The host runs `run()` in its own child task and calls `shutdown()`
  (closes the server's input) or cancels `run()` (SIGTERM, then SIGKILL after
  `terminationGrace`). Responses are routed by `id`, progress by `progressToken`, listen
  events by `subscriptionId`; log messages cannot be correlated on stdio and are dropped.
  Cancelling a call sends `notifications/cancelled`. At stdout EOF, pending exchanges
  fail with `StdioClientTransportError.serverExited`, while the run owner joins stderr
  and stdin before returning. A nonzero exit or signal throws
  `StdioClientTransportError.unsuccessfulTermination` with the subprocess termination
  status; cancellation of the run is `CancellationError`. A primary I/O/framing
  error is preserved rather than replaced by a later cleanup status. See
  [ADR-0008](ADR/0008-client-stdio-child-lifetime.md).
- `LoopbackTransport` (`MCPServerTesting`): in-process against a `Server`.

## Behavior

- **MRTR.** An `InputRequiredResult` is answered by the configured handlers. They are typed:
  - elicitation: `ElicitationRequest` → `ElicitationResponse`;
  - sampling: `SamplingRequest` → `SamplingResponse`;
  - roots: `[Root]`;
  - other methods: `additionalInputHandlers`, JSON → JSON.

  Their results are validated against the schema, and accepted elicitation content against
  `requestedSchema`. Then the request is resent with `inputResponses` and the opaque
  `requestState`, up to `maximumInputRounds`. Declared capabilities follow from the handlers
  that are set; an elicitation in a mode that was not declared is refused. Input that no
  handler answers is `ClientError.unsupportedInput`, never guessed.
- **Typed results.**
  - `ToolResult.content` and prompt messages are `[Content]`: text, image, audio, resource
    link, embedded resource, or `.unknown(JSON)` for types the SDK does not model and for
    payloads that do not decode.
  - `readResource` returns `[ResourceContents]` with decoded blobs.
  - `getPrompt` returns `PromptResult`, `complete` returns `Completion`, and
    `listResourceTemplates` returns `Page<ResourceTemplate>`.
  - Log levels are `LoggingLevel`.
- **Tool headers.** On Streamable HTTP, `x-mcp-header` parameters are mirrored into
  `Mcp-Param-*` headers with the specification's encoding; tools with invalid annotations
  are dropped from `tools/list` and listed in `rejectedTools`.
  Routing and output-validation metadata follow successful listing pages. A fresh
  listing starts with a nil cursor; observed names replace their previous metadata.
  Unvisited names retain their last known metadata while pagination is incomplete.
  A successful terminal page of that chain retires unobserved names, including
  old rejection diagnostics. Rejections describe one latest observation per name,
  sorted by name; a valid redefinition removes its rejection. An empty string is
  a valid continuation cursor. An independent cursor page updates observed names
  but does not prove removal of others or complete an unrelated listing chain.
  A malformed, failed or cancelled page does not commit metadata.
  Concurrent cursorless requests use latest-initiated ownership of the metadata
  commit (including when the latest request fails); continuations commit only if
  the local revision observed at their start has not changed. A superseded
  successful request still returns its own validated page. No global server
  snapshot is implied. A call captures its routing and output schema before
  exchange, including across input rounds and callbacks. A list-changed event
  is delivered to the caller, who may explicitly relist; the client neither
  starts background refreshes nor discards validation solely on receipt of an event.
- **Raw values.** Typed views keep the raw JSON, so schemas pass through unchanged and are
  never dereferenced over the network.
- **Compatibility.** A result without `resultType` is `complete`. `-32022` is retried
  once when the server lists 2026-07-28, otherwise it is `ClientError.unsupportedProtocol`.
- **Errors.** JSON-RPC errors are `ClientError.server(code:message:data:)`. `ClientError` is
  `Equatable`, and `ClientError.Code` names the codes (for example `.methodNotFound`,
  `.missingRequiredCapabilities`). `requiredExtensions` reads the extensions a `-32021` names.
- **Concurrency.** `Client` is an actor; calls run concurrently on the caller's tasks and
  cancelling a call cancels its exchange. No detached tasks or shared mutable request state.
  Only hash-verified frozen wire preparation is shared through a bounded, process-local actor
  (see [ADR-0007](ADR/0007-client-frozen-wire-cache.md)); each response is still evaluated,
  and server-supplied schema plans remain client-local.

## Extensions

### Tasks (`MCPTasksClient`)

```swift
let (key, value) = TasksClient.declaration
let client = Client(transport: transport, configuration: .init(elicitation: elicitation, extensions: [key: value]))
let tasks = TasksClient(client: client)
let result = try await tasks.callToolToCompletion("build_report", arguments: arguments)
```

- `callTool` returns `.completed(ToolResult)` or `.task(TaskSnapshot)`.
- `wait(for:)` polls `tasks/get` at the server's `pollIntervalMs` (clamped to
  `pollingBounds`), answers each input request key once with the client's handlers through
  `tasks/update`, and returns the terminal state. Cancelling the wait does not cancel the
  task; `cancel(_:)` sends `tasks/cancel`.
- `follow(_:)` uses `subscriptions/listen` with `taskIds` instead of polling and returns
  the final state of every task the server agreed to report.
- Requests fail with `TasksClientError.extensionNotDeclared` unless the configuration
  declares the extension.

### Skills (`MCPSkillsClient`)

```swift
let skills = SkillsClient(client: client)
let entry = try await skills.list().items.first { $0.name == "pdf-processing" }!
let loaded = try await skills.load(entry)                  // fetches and verifies SKILL.md
let forms = try await skills.file("skill://pdf-processing/references/FORMS.md", of: loaded)
```

- Nothing is fetched ahead of need: `list` and `get` return entries only.
- Every fetched file must be listed in the entry and match its `size` and `sha256:`
  digest; `SKILL.md`'s frontmatter is parsed with the server's strict parser and compared
  field by field with the entry. Any mismatch throws `SkillVerificationError` and the
  content is not returned.

## Conformance

The client fixture in Swift-MCP-Server-HTTP passes all 8 non-authorization client
scenarios of `@modelcontextprotocol/conformance` 0.2.0-alpha.12 for 2026-07-28 (64 checks)
and the 4 Skills client scenarios (`sep-2640-client-*`).

## Not yet implemented

- OAuth (`MCPClientAuthorization`).
