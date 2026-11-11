# SDK roadmap: complete server SDK and a stable client

Status: updated 2026-11-11 (first version 2026-11-10). Scope: protocol revision 2026-07-28
only; no initialization-based (2025-11-25 and earlier) compatibility on either side.
Related: [TASKS-ROADMAP.md](TASKS-ROADMAP.md), ADR-0003 (Tasks), ADR-0004 (task store),
ADR-0005 (client).

Referee: `@modelcontextprotocol/conformance` 0.2.0-alpha.12 (latest alpha on 2026-11-11).

## 1. Where we stand

### Server

| Area | State | Evidence |
|---|---|---|
| Core 2026-07-28 (discover, tools, resources, prompts, completion, MRTR, listen, logging, progress, caching, pagination) | done | referee 37/37 required |
| Streamable HTTP, standard and custom headers, protected resource metadata, bearer authorization | done (Swift-MCP-Server-HTTP) | referee, HTTP tests |
| Tasks phase A: 10 official scenarios | done (#6, #8) | 10/10, gated in HTTP CI (HTTP #2) |
| Tasks phase B: `notifications/tasks` over listen | done (#10) | 4 tests, full regression |
| S2 Skills (`MCPSkills`, SEP-2640) | in review (#11, HTTP #2) | 9 tests, referee 45/45 checks |
| CI gate for implemented extensions (13 scenarios) | in review (HTTP #2) | gate fails when results are missing |

### Client

| Area | State | Evidence |
|---|---|---|
| C1 `MCPClient`: discover, tools, resources, prompts, complete, listen, generic requests, MRTR driver, schema validation, typed errors | done, not yet in a PR (`feat/client-core`) | 13 tests |
| C2 transports: `LoopbackTransport`, `MCPClientStdio` (swift-subprocess), `MCPHTTPClient` (AsyncHTTPClient, JSON and SSE) | done, not yet in a PR (`feat/client-core`, HTTP `feat/http-client`) | stdio tests against a real server process; HTTP end-to-end tests against `MCPHTTP` |
| `x-mcp-header` mirroring and invalid-tool rejection | done | spec encoding examples, referee |
| Client conformance | **8/8 non-authorization scenarios, 64/64 checks** | `Scripts/client-conformance.sh` (CI gate on the branch) |

## 2. Complete server SDK (target: 1.0)

### Features

| ID | Item | Estimate | Exit criterion |
|---|---|---|---|
| T-C | Tasks phase C: `TaskStore` protocol, store conformance kit, `MCPTasksSQLite`, restart semantics (ADR-0004) | 5–7 days | kit passes for in-memory and SQLite on macOS and Linux; restart test |
| T-B2 | Tasks phase B remainder: compiler-enforced single completion (`~Copyable` token), typed `TaskFailure`, DocC article, Explorer example | 1–2 days | API review |
| S3 | MCP Apps helpers (`ui://` resources, `text/html;profile=mcp-app`, tool `_meta` UI reference, client MIME negotiation) | 2–3 days | example plus tests |
| S5 | Resource-server DPoP: decide whether `MCPHTTPAuthorization` validates DPoP-bound tokens (ext-auth) | 1 day investigation | ADR |
| S2b | Skills: dynamic skills (`"resources": "dynamic"`) and catalogs that change at runtime | 1–2 days | tests |
| S4 | Server Cards (`<endpoint>/server-card`) once the extension reaches Beta | 2–3 days | wait |
| T-D | Shared stores (libSQL/Turso, PostgreSQL), experimental | 5–8 days | after T-C |

### Release blockers (testing and infrastructure)

| ID | Item | Why it blocks |
|---|---|---|
| R1 | SwiftNIO early-EOF fix for macOS 27 ([apple/swift-nio#3783](https://github.com/apple/swift-nio/pull/3783), open) | Swift-MCP-Server-HTTP cannot release on a SwiftNIO without it |
| R2 | Release build of the HTTP fixture fails to link (`NIOHTTPServer.Connection.HTTPProtocol` metadata, swift-http-server) | conformance runs only in debug (slow, 90 s scenario timeout) |
| R3 | Two timing-dependent Linux tests (`deadlineJoinsUncooperativeCallbackAndBoundsRetainedWork`, `parentCancellationAndRepeatedNeverStartedCleanup` descriptor count) and one Explorer test (`deadlineOfPartialResponseJoinsTask`) | flaky CI hides real failures |
| R4 | CI access to the private core repository (the self-hosted runner only has a cached checkout) | every core change needs a manual cache refresh until a read-only key exists or the repository is public |
| R5 | Linux CI for Swift-MCP-Server-HTTP (only macOS 27 today) | Linux is a supported platform |
| R6 | Public API review, DocC for every product, semantic-versioning policy, `1.0.0` tag | stable promise |

## 3. First stable client (target: `MCPClient` 0.x → 1.0 for the covered surface)

The stable part is what C1 and C2 cover: discover, tools, resources, prompts, completion,
listen, MRTR (elicitation, sampling, roots), progress, over stdio, Streamable HTTP and
loopback. Authorization stays outside the stable surface until C3.

### To finish before calling it stable

| ID | Item | Estimate |
|---|---|---|
| CS1 | PRs for `feat/client-core` and HTTP `feat/http-client` (merge `main`, full regression, client conformance in CI) | ½ day |
| CS2 | Test gaps: listen over stdio, resources and prompts over HTTP and stdio, limits (oversized messages, too many pending requests), server restart on stdio, invalid server output on every method | 1–2 days |
| CS3 | API review: typed views versus raw JSON, handler signatures, error cases, `Sendable` and cancellation contracts; DocC and an example client | 1–2 days |
| CS4 | Linux: stdio transport and client tests in the Linux container | ½ day |
| CS5 | Caching hints (`ttlMs`, `cacheScope`) for list results; log messages on stdio are dropped today (not correlatable) | 1 day |

### After the stable part

| ID | Item | Referee scenarios | Estimate |
|---|---|---|---|
| C3 | `MCPClientAuthorization` (OAuth 2.1: discovery, CIMD, DCR, PKCE, scopes and step-up, token endpoint methods, refresh, `iss`, AS migration, DPoP; client credentials, enterprise-managed, WIF) with a host-supplied token store | about 25 `auth/*` | 4–6 weeks |
| C4 | Tasks client (create, poll at `pollIntervalMs`, `tasks/update`, cancel, status stream) and Skills client (no prefetch, digest/size/frontmatter verification) | 4 Skills scenarios | 1–2 weeks |

## 4. Order

1. Merge #11 and HTTP #2 (Skills, extension gate).
2. CS1: client PRs; then CS2–CS4 and tag the client's first stable surface.
3. R3 and R4 (reliable CI), T-B2, T-C (durable tasks).
4. C4, then C3 (largest block).
5. S3, S5, S2b; S4 when Server Cards reach Beta.
6. R1, R2, R5, R6 and the 1.0 release of the server SDK.

## 5. Decisions taken since the first version

- Package layout: client products live in the same repositories as the server
  (`MCPClient`, `MCPClientStdio` in core; `MCPHTTPClient` in Swift-MCP-Server-HTTP).
- HTTP client stack: AsyncHTTPClient only, no fallback.
- Official extensions can be server-declared (Skills) or client-declared (Tasks).
- Open: repository naming once the client ships ("Swift-MCP-Server" → broader name).
