# Architecture and ownership

| Layer | Owns | Depends on |
|---|---|---|
| MCPProtocol | Exact wire representations and codec projections | Swift-JSON JSON |
| MCPJSONSchemaAdapter (private) | Compiled schema generation and budget bridge | Protocol, JSONSchema |
| MCPServer | Catalog snapshot, dispatch, request lifetime, MRTR and events | Protocol, adapter, Logging |
| MCPStdio | Owned/borrowed FDs, framing and bounded writes | Server, SystemPackage |
| MCPHTTP | Raw HTTP mapping, SSE, header/authority admission | Server, NIOHTTPServer, HTTPAPIs |
| MCPHTTPAuthorization | Verified principal/resource scopes and metadata | HTTP/Server |
| MCPServiceLifecycle | Readiness and host-coordinated stop/drain | Server, ServiceLifecycle |
| MCPObservability | Injected instrumentation and low-cardinality context | Server, Metrics, ServiceContextModule |
| MCPServerTesting | In-process test harness and deterministic clocks | Server |

Transports translate external events to a transport-neutral request lifetime. Admission checks raw size,
envelope, protocol context, principal policy and handler capacity before calling a provider. Each request
captures one immutable catalog/schema generation. Shared catalog mutation, continuation claims and event
routing use explicit actor ownership; data-only wire values are Sendable if the actual JSON dependency is.

Provider execution occurs in structured child tasks. A single terminal-result coordinator owns response
completion and prevents error/cancel/success races from writing twice. The transport owns its writer and
connection; runtime owns the admitted request; host owns providers, keys and token verifier. Disconnect
propagates cancellation to both runtime and I/O. No library owns application-global signal handlers.

The verified-principal carrier and host authorization seam belong in MCPServer so in-process/stdio hosts
can supply identity without importing HTTP authorization. MCPHTTPAuthorization verifies tokens and maps
them into that core carrier; it does not introduce a reverse dependency from Server to HTTP. Keep direct
module/product imports explicitly declared when freezing the actual API.

Transport-facing seams are proposed as finite byte-source/byte-sink, request event emitter and lifecycle
closure interfaces. Freeze actual public protocol signatures in P00/P03 after consumer probes. Avoid
exposing NIO channel machinery, private schema plans or an unnecessary class for every placeholder file.
Core APIs must not require an HTTP transport or Metrics backend to register an in-process tool.

Synthetic conformance registrations exist in a separate executable package. That executable is a normal
consumer of production libraries. Reference snapshots and Python qualification tools never enter the
compiled library graph. Server-only does not mean ignoring outbound messages: MRTR inputs, responses
and correlated notifications are fully represented without creating a client SDK.
