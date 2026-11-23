# ADR-0005: MCP client for protocol 2026-07-28 (`MCPClient`)

- Status: **Proposed** (2026-11-11)
- Scope: phases C1 and C2 of [SDK-ROADMAP](../Plans/SDK-ROADMAP.md); authorization (C3) and
  extension clients (C4) build on this decision.

## Context

No Swift client for 2026-07-28 exists; the official swift-sdk implements 2025-11-25 only.
The revision is stateless: there is no `initialize`, every request carries its protocol
version and client capabilities in `params._meta`, servers ask for input with
`InputRequiredResult` (MRTR) instead of server-to-client requests, and notifications that
are not tied to a request flow over `subscriptions/listen`.

`MCPProtocol` already holds everything both directions share: the frozen 2026-07-28 schema
with a definition for every request, result and notification, `WireDefinitionPlan`
validation, `WireCodec` and the envelope rules. The official referee tests clients by
starting `<command> <server-url>` with the scenario in `MCP_CONFORMANCE_SCENARIO`; for
2026-07-28 it has 8 scenarios without authorization (`tools_call`, `request-metadata`,
`sep-2322-client-request-state`, three HTTP header scenarios, two JSON Schema scenarios)
and about 25 authorization scenarios.

## Decision

### Products

| Product | Repository | Content |
|---|---|---|
| `MCPClient` | core | `Client` actor, `ClientTransport` protocol, MRTR driver, listen streams, response validation |
| `MCPClientStdio` | core | Child-process transport on swift-subprocess: owned pipes, newline framing, termination |
| `MCPServerTesting` (extended) | core | In-process loopback transport, so client and server test each other without I/O |
| `MCPHTTPClient` | HTTP | Streamable HTTP on AsyncHTTPClient: JSON and SSE responses, standard and custom headers |

`MCPClient` does not depend on `MCPServer`. One HTTP stack, AsyncHTTPClient, on every
platform; no automatic fallback to URLSession.

### Transport contract

A transport carries one request to its terminal response:
`exchange(_ request: OutgoingRequest) -> ResponseStream`, where the stream yields
request-scoped notifications (progress, log messages, or a listen stream's events) and
ends with exactly one response or a transport error. `OutgoingRequest` carries the
encoded message plus the method and routing name, so HTTP can set `Mcp-Method` and
`Mcp-Name`. Cancelling the consuming task cancels the exchange: stdio sends
`notifications/cancelled` for the request ID, HTTP closes the stream. Transports never
interpret results.

### Client

- **Requests.** Every request carries `io.modelcontextprotocol/protocolVersion`
  (`2026-07-28`), `io.modelcontextprotocol/clientCapabilities` and, when configured,
  `io.modelcontextprotocol/clientInfo`. Request IDs are unique per client.
- **Discovery.** `discover()` returns the server's description; the client refuses
  servers that do not list 2026-07-28. Other methods do not require a prior discover.
- **Typed views, raw values.** Results are returned as small typed views (tools,
  resources, prompts, contents) that keep the raw JSON, so schemas and unknown fields
  pass through unchanged (required by the JSON Schema preservation scenario). Tool input
  schemas are never dereferenced over the network.
- **Validation.** Every response and notification is validated against its frozen
  definition before it reaches the application; invalid ones fail with
  `ClientError.invalidResponse`. Messages are bounded by `JSONLimits`.
- **MRTR.** Configured handlers answer input requests: elicitation (form and URL),
  sampling and roots. Declared client capabilities follow from the handlers that are set.
  The driver resends the original request with `inputResponses` and the opaque
  `requestState`, up to a configurable round limit (default 8). A request without a
  matching handler fails with `ClientError.unsupportedInput` instead of guessing.
- **Notifications.** Progress and log notifications go to per-call handlers.
  `listen(_:)` returns an `AsyncThrowingStream` of typed events that starts after the
  acknowledgement and reports which filters the server agreed to.
- **Errors.** JSON-RPC errors surface as `ClientError.server(code:message:data:)`;
  `-32021` keeps its `requiredCapabilities`.
- **Concurrency.** `Client` is an actor; requests run concurrently on the caller's task.
  No detached tasks, shared mutable request state, or process-wide signal or logging setup.
  [ADR-0007](0007-client-frozen-wire-cache.md) defines the narrow exception for immutable
  frozen protocol artifacts.

### Verification

A client conformance fixture in Swift-MCP-Server-HTTP runs the referee's client mode.
Exit criterion for C1 and C2: the 8 non-authorization 2026-07-28 client scenarios pass,
plus loopback tests against `MCPServer` for every method, MRTR round and listen stream.

## Alternatives

- **URLSession for HTTP.** Simpler on Apple platforms, but streaming and cancellation
  differ on Linux, and two stacks double the conformance surface.
- **Foundation `Process` for stdio.** Available everywhere, but its termination and
  pipe ownership need manual handling that swift-subprocess already provides.
- **Generated Codable types for every result.** Complete typing, but the schema's unions
  and open objects lose unknown fields; typed views over validated raw JSON keep them.
- **Keeping 2025-11-25 compatibility.** Out of scope; this client speaks 2026-07-28 only.

## Consequences

- New dependencies: swift-subprocess (core, `MCPClientStdio` only) and AsyncHTTPClient
  (HTTP repository, already present through swift-http-server).
- `MCPServerTesting` gains a client dependency for the loopback transport.
- The client fixture becomes a second CI gate next to the server referee run.
