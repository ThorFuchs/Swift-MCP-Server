# SDK roadmap: complete server SDK and a stable client

Status: updated 2026-11-12 (first version 2026-11-10). Scope: protocol revision 2026-07-28
only; no initialization-based (2025-11-25 and earlier) compatibility on either side.
Related: [TASKS-ROADMAP.md](TASKS-ROADMAP.md), ADR-0003 (Tasks), ADR-0004 (task store),
ADR-0005 (client), ADR-0006 (client authorization).

Referee: `@modelcontextprotocol/conformance` 0.2.0-alpha.12 (latest alpha on 2026-11-11).

## 1. Where we stand

### Server

| Area | State | Evidence |
|---|---|---|
| Core 2026-07-28 (discover, tools, resources, prompts, completion, MRTR, listen, logging, progress, caching, pagination) | done | referee 37/37 required |
| Streamable HTTP, standard and custom headers, protected resource metadata, bearer authorization | done (Swift-MCP-Server-HTTP) | referee, HTTP tests |
| Tasks phase A: 10 official scenarios | done (#6, #8) | 10/10, gated in HTTP CI (HTTP #2) |
| Tasks phase B: `notifications/tasks` over listen | done (#10) | 4 tests, full regression |
| Tasks phase C: `TaskStore`, `TaskStoreConformanceKit`, `MCPTasksSQLite`, restart policy | in review (#17) | kit passes for in-memory and SQLite (including reopen); restart policy tests |
| S2 Skills (`MCPSkills`, SEP-2640) | done (#11, HTTP #2) | 9 tests, referee 45/45 checks |
| CI gate for implemented extensions (13 scenarios) | done (HTTP #2) | gate fails when results are missing |

### Client

| Area | State | Evidence |
|---|---|---|
| C1 `MCPClient`: discover, tools, resources, prompts, complete, listen, generic requests, MRTR driver, schema validation, typed errors | in review (#16) | 18 tests in 6 suites |
| C2 transports: `LoopbackTransport`, `MCPClientStdio` (swift-subprocess), `MCPHTTPClient` (AsyncHTTPClient, JSON and SSE) | stdio in review (#16); HTTP on `feat/http-client`, PR after #16 | stdio tests against a real server process; HTTP end-to-end tests against `MCPHTTP` |
| `x-mcp-header` mirroring and invalid-tool rejection | done | spec encoding examples, referee |
| Client conformance | **8/8 non-authorization scenarios, 64/64 checks** | `Scripts/client-conformance.sh` (CI gate on the branch) |

## 2. Complete server SDK (target: 1.0)

### Features

| ID | Item | Estimate | Exit criterion |
|---|---|---|---|
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
| R3 | Timing-dependent tests: one Explorer test (`deadlineOfPartialResponseJoinsTask`), `realStdioExampleFragments…` under load, and `eofCancellationAndBrokenOutputSettle` on Linux (a closed output can surface as `CoreFailure.eventOverflow` from the event channel before the transport reports `StdioFailure.brokenPipe`; the transport should report the pipe failure first) | flaky CI hides real failures |
| R4 | CI access to the private core and HTTP repositories (the self-hosted runner only has cached checkouts; macOS cleared them once already) | every core change needs a manual cache refresh until a read-only key exists or the repositories are public; Swift-SQLite is public since 2026-11-12 |
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
| C3 | `MCPClientAuthorization`: OAuth 2.1 client with a host-supplied user agent, token store and keys (slices A1–A6 below) | 25 core + 6 extension `auth/*` | 4–6 weeks |
| C4 | Tasks client (create, poll at `pollIntervalMs`, `tasks/update`, cancel, status stream) and Skills client (no prefetch, digest/size/frontmatter verification) | 4 Skills scenarios | 1–2 weeks |

### C3 in detail: client authorization

Today the server side has protected resource metadata (RFC 9728), `WWW-Authenticate`
with scopes and bearer validation through a host verifier; only DPoP (S5) is open. The
client side has nothing yet. Referee scenarios for 2026-07-28 (0.2.0-alpha.12):

| Slice | Content | Referee scenarios |
|---|---|---|
| A1 Discovery | Protected resource metadata from `WWW-Authenticate` and well-known paths; authorization server metadata (RFC 8414, OpenID Connect); issuer and resource checks | `metadata-default`, `metadata-var1`–`var3`, `metadata-issuer-mismatch`, `resource-mismatch` (6) |
| A2 Registration | Client ID metadata documents (CIMD), pre-registration, dynamic client registration as fallback | `basic-cimd`, `pre-registration` (2) |
| A3 Code flow | Authorization code with PKCE and `resource`; token endpoint authentication `client_secret_basic`, `client_secret_post`, `none`; `iss` checks (RFC 9207) | `token-endpoint-auth-*` (3), `iss-*` (6) |
| A4 Scopes and refresh | Scopes from `WWW-Authenticate` or `scopes_supported`, omitted when undefined, step-up, retry limit; `offline_access` and refresh tokens | `scope-*` (5), `offline-access-*` (2) |
| A5 Lifecycle | Authorization server migration; token store protocol; `MCPHTTPClient` retries 401/403 once through the authorization handler | `authorization-server-migration` (1) |
| A6 Extensions | Client credentials (JWT and basic), enterprise-managed authorization, workload identity federation (JWT bearer), DPoP with nonces | 6 extension scenarios |

Decisions, proposed in ADR-0006 (client authorization and DPoP):
1. Location: `MCPClientAuthorization` in Swift-MCP-Server-HTTP next to `MCPHTTPClient`
   (authorization exists only over HTTP).
2. Host-supplied parts: the user agent for the authorization redirect, the token store and
   signing keys (`private_key_jwt`, DPoP). The library never owns host credentials.
3. Cryptography through CryptoKit / swift-crypto only (PKCE, JWT signatures, DPoP proofs).
4. DPoP together with S5, so the server can validate the proofs the client creates.

Order inside C3: ADR, A1–A3 (the common interactive case), then A4–A6.

## 4. Order

1. Merge #16 (client) and #17 (Tasks phase C); then the HTTP client PR.
2. CS2–CS5 and tag the client's first stable surface (0.x).
3. R3 and R4 (reliable CI), T-B2.
4. C4 (Tasks and Skills client), then C3 (authorization, largest block).
5. S3, S5, S2b; S4 when Server Cards reach Beta.
6. R1, R2, R5, R6 and the 1.0 release of the server SDK.

## 5. Decisions taken since the first version

- Package layout: client products live in the same repositories as the server
  (`MCPClient`, `MCPClientStdio` in core; `MCPHTTPClient` in Swift-MCP-Server-HTTP).
- HTTP client stack: AsyncHTTPClient only, no fallback.
- Official extensions can be server-declared (Skills) or client-declared (Tasks).
- Open: repository naming once the client ships ("Swift-MCP-Server" → broader name).
