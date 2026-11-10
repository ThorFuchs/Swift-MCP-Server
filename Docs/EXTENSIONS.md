# Supplemental extension framework

MCP2026-07-28 remains the only protocol. The frozen155 definitions and21 core
method entries are unchanged. `ExtensionRegistration` adds host-owned offline
plans; concrete Tasks/Apps/Skills are outside this package.

A declaration contains an exact mandatory namespace (for example `com.example/demo`),
settings schema, optional object capability metadata, and request/result/input/notification
forms. All form names begin with that namespace plus `/`. Registration rejects core
collisions, duplicate namespaces/directions, invalid names, unresolved/network references,
and operational preparation failures. There are at most64 namespaces,16 forms per category
per namespace and256 total forms. Each schema has a262144-byte preparation ceiling;
capability metadata/settings each have a16384-byte encoded ceiling. Prepared schemas and
metadata share the32MiB catalog retained-weight ceiling and one cumulative preparation
budget. These are logical limits, not an RSS guarantee.

Current `_meta["io.modelcontextprotocol/clientCapabilities"].extensions` must explicitly
advertise the namespace and valid settings on every request/retry. A registration alone
never activates a route. Unknown extensions remain data. Absent negotiation retains
method-not-found; wrong direction and invalid settings retain the frozen error layer.
Self-reported client identity never becomes a verified principal.

`RequestContext.method` is `RequestMethod`: `.core` identifies a frozen `WireMethod`,
`.extensionNamespace` identifies a supplemental route, and `.rawValue` preserves its
exact name. Existing contextual aliases such as `.callTool` remain available. Diagnostics
use the finite `unknown` method dimension for supplemental traffic.

`ExtensionRequest` requires a parameters schema, allowed declared result types and
optional scopes. Its ordinary handler receives checked application parameters. Result
objects must match an active declared schema and exact namespaced `resultType`; malformed
outputs are internal protocol errors. `ExtensionResult.coreMethods` explicitly permits
that branch on tools/call, resources/read or prompts/get only. Built-in catalog listings
and typed completion reject unsupported augmentation declarations, without broadening the frozen core validator.
HTTP mirrors are still mandatory. Nested `x-mcp-header` declarations use the existing
D07 traversal and mapping, after schema validation. HTTP access policies separately
authorize supplemental requests; the compatibility default denies them.

Explicit `MultiRoundProvider` registration enables supplemental MRTR; ordinary custom
methods cannot accept requestState/inputResponses. Declared `ExtensionInput` schemas
validate input requests/responses. Protected state binds method, original parameters,
current namespace/settings, provider version and immutable input/response/result plans.
Binding-v1 exact-number/scalar semantics remain unchanged; normalized writing is not JCS.
Retries are independently admitted; replay/effect policy and terminal ownership retain
the core rules. Changed settings/plan/principal reject before provider effects.

`context.notify(extensionMethod:parameters:)` emits only a negotiated declared notification
on the request's owned channel, with schema/meta validation, cumulative work and existing
count/byte ceilings. It cannot create standalone server JSON-RPC requests, revive a closed
channel or bypass cancellation. Recognizable incoming notifications remain response-silent.

See `Tools/AcceptanceConsumer` for actual public consumption and the optional
`--extensions` example mode. Example names define a synthetic host extension, not a protocol
extension standard. Native ExtensionCases, middleware, authorization, real stdio and TLS
cases exercise these boundaries; parameter counts do not replace criterion evidence.
