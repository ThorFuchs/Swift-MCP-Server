# SDK roadmap: server parity and a 2026-07-28 client

Status: proposed (2026-11-10). Scope: protocol revision 2026-07-28 only; no
initialization-based (2025-11-25 and earlier) compatibility on either side.
Related: [TASKS-ROADMAP.md](TASKS-ROADMAP.md), ADR-0003 (Tasks), ADR-0004 (task store).

## Baseline (survey of 2026-11-10)

Sources: `modelcontextprotocol/modelcontextprotocol` (specification 2026-07-28 and
`docs/extensions`), `modelcontextprotocol/conformance` (main and npm
`0.2.0-alpha.12`), TypeScript SDK v2.4.0, rust-sdk `rmcp` 3.9.0, Python SDK 2.3.0,
Go SDK 1.8.0, official swift-sdk 0.12.1.

**Server, already covered:** `server/discover`, per-request `_meta` capabilities,
tools/resources/prompts, completion, logging, progress, caching hints, pagination,
MRTR with protected `requestState`, `subscriptions/listen`, extension registry,
Tasks (10/10 official scenarios), Streamable HTTP with standard headers, protected
resource metadata and bearer authorization (Swift-MCP-Server-HTTP).

**Client:** none. The official swift-sdk implements 2025-11-25 only, so no Swift
client for 2026-07-28 exists. Reusable here: `MCPProtocol` (all methods in both
directions including the input-request legs, frozen schema validation, JSON-RPC
envelopes), Swift-JSON/JSONSchema, `ToolHeaderMapping` from the HTTP package.

## Part S: server parity

| ID | Item | Extension stage | Reference SDKs | Estimate |
|---|---|---|---|---|
| S1 | Tasks phase B: `notifications/tasks` over `subscriptions/listen` | Beta, to core | TypeScript, Rust | ~1 week (see TASKS-ROADMAP) |
| S2 | **Skills over MCP** (`io.modelcontextprotocol/skills`, SEP-2640) as product `MCPSkills`: catalog enumeration, manifest, directory reads over resources, digest/size metadata | Beta | TypeScript (`ext/skills`), Rust (`skill_catalog`, `skills-fs`), Python | 1–2 weeks |
| S3 | MCP Apps (`io.modelcontextprotocol/ui`) helpers: `ui://` resources with `text/html;profile=mcp-app`, tool `_meta` UI reference, client MIME negotiation | Stable | Python examples; rendering is host-side | a few days |
| S4 | Server Cards: static document at `<endpoint>/server-card` in Swift-MCP-Server-HTTP | Experimental in its repository | — | 2–3 days; wait for Beta |
| S5 | Auth extensions on the resource server: confirm whether DPoP-bound tokens need proof validation in `MCPHTTPAuthorization` | Stable (client credentials, enterprise-managed) | Go, Rust | investigate first |

Exit criteria: S2 passes the referee's `sep-2640-skills-*` server scenarios against
the HTTP fixture; S1 passes `tasks-status-notifications` once the referee scores it.
Experimental extensions (interceptors, variants, file uploads, filesystems,
triggers/events, tool annotations) are tracked, not implemented.

## Part C: client (2026-07-28 only)

| ID | Item | Referee scenarios | Estimate |
|---|---|---|---|
| C1 | **`MCPClient` core**: discover, per-request `_meta`, typed calls, pagination, result validation, cancellation and progress, MRTR driver with pluggable elicitation/sampling/roots handlers and `requestState` echo, `listen` as `AsyncSequence`, list caching | `tools_call`, `request-metadata`, `mrtr-client`, `elicitation-defaults`, JSON Schema `ref-deref` and `2020-12-preservation` | 2–3 weeks |
| C2 | **Transports**: in-memory loopback (client ↔ `MCPServer` tests), stdio client on swift-subprocess with owned process and cancellation, Streamable HTTP client with SSE, `Last-Event-ID` resumption, standard and custom headers. One HTTP stack (AsyncHTTPClient), no automatic fallback | `sse-retry`, HTTP standard/custom/invalid tool headers | 2–3 weeks |
| C3 | **`MCPClientAuthorization`** (OAuth 2.1): protected resource and AS metadata discovery, CIMD, DCR, pre-registration, PKCE, scope selection and step-up, token endpoint auth methods, refresh/offline access, `iss` validation, AS migration, DPoP; extensions client credentials, enterprise-managed (ID-JAG), WIF JWT bearer. swift-crypto; tokens live in a host-supplied store protocol (the library never owns host credentials) | ~27 `auth/*` scenarios | 4–6 weeks |
| C4 | Extension clients: Tasks (poll at `pollIntervalMs`, `tasks/update`, cancel, status stream); Skills (no prefetch, digest/size/frontmatter verification) | 4 skills client scenarios | 1–2 weeks |
| C5 | Client conformance fixture and CI (macOS 27, Linux container) | all of the above | ~1 week |

Total: about 9–14 weeks. **MVP** (C1 + C2 + a bearer token provider): 4–6 weeks,
usable against stdio servers and HTTP servers with pre-issued tokens.

Exit criteria: all active, non-pending client scenarios of the pinned referee pass
except those that require pre-2026-07-28 behavior (`initialize`, backcompat), which
are recorded as out of scope.

## Order

1. S1 and S2 (server parity with the reference SDKs).
2. C1 + C2 MVP, tested client ↔ server over the in-memory transport.
3. C3 authorization.
4. C4 extension clients, C5 alongside each phase.
5. S3 and S4 when their specifications are stable; S5 after the investigation.

## Open decisions

- Package layout: client products in this repository (`MCPClient`, shared
  `MCPProtocol`) and the HTTP client in Swift-MCP-Server-HTTP, or a separate client
  package. Recommendation: same repositories, mirroring the server split.
- HTTP client stack: AsyncHTTPClient (Linux and Apple platforms) vs. URLSession.
  Recommendation: AsyncHTTPClient, one stack only.
- Repository naming once a client exists ("Swift-MCP-Server" → broader name).
