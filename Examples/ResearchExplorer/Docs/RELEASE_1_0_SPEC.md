# Research Explorer — Release 1.0 Product and Technical Specification

Status: **Proposed for review**, 2026-11-21. Owner: the Research Explorer example/application, not the SDK protocol.
Source-of-truth issue: https://github.com/ThorFuchs/Swift-MCP-Server/issues/40
Protocol: **MCP 2026-07-28 only**. Target: **Swift 6.4, macOS 27, Swift 6 language mode**.
Core dependency: Swift-MCP-Server; HTTP dependency: Swift-MCP-Server-HTTP; application and CLI remain separate SwiftPM executable products.
This document defines a release target, **not an assertion that the implementation or CI is complete**.

## 1. Product thesis

**Research Explorer** is a polished native macOS research application *and* an inspectable end-to-end reference consumer of the public Swift MCP SDK.

The primary experience is reading: search, choose an article, explore sections and associated references, and inspect source/revision/license provenance. The developer experience is understanding: deliberately start the local MCP host, perform a real client/server journey with the same domain, inspect bounded exchange metadata, and reproduce the journey via stdio CLI.

Success is not maximum SDK feature coverage. Four real, well-specified read-only tools with strong provenance, cancellation, and boundary handling are better than superficially adding every MCP primitive.

Distinct user audiences:
- **Researcher:** reads selected English Wikipedia or a coherent offline fictional corpus.
- **Swift developer:** witnesses a real MCP client/server call chain and can inspect examples/CLI/tests.
- **SDK maintainer:** verifies transport, typed structured results, provenance, validation, cancellation and lifecycle guarantees.

## 2. Factual baseline (2026-11-21)

Current example at the audit SHA (Core bb3a3b7f): Research UI uses a local ResearchController → ExplorerService; the macOS Server screen explicitly starts a local Streamable HTTP host with four registered tools; Activity reflects eligible external MCP tool handler calls. The stdio CLI runs a genuine MCP server, but its historical --walkthrough invokes ExplorerService directly.

The four tool methods: `search_articles`, `get_article_outline`, `read_article_section`, `get_section_references`.
Source profiles: **Offline demo (fictional Riverglass)** or **Wikipedia English (enwiki)**.
The article reader currently displays a hierarchical outline via a menu, plain-text sections and metadata-only references. Provenance is revision-pinned.
Offline fixtures include two search candidates but only one fully resolvable article (Observatory) in revisions r1/r2; the other candidate intentionally supports missing-article behavior.
The example has a minimum macOS 27 manifest, SwiftUI app, stdio CLI, test targets and source-owned third-party notices.

## 3. User journeys and acceptance

### J1 — Offline first-run, no network
- Launch with **no outgoing request** and **no started listener**.
- Show two clear source choices and an inviting first-run action, **Explore the offline collection**.
- The sample collection contains at least four fully resolvable fictional articles with short but substantive sections and coherent synthetic references. No result should pretend to represent actual Wikipedia.
- Offer an easy sequence: Search → candidate → revision-bound outline → section → associated references/provenance.
- Make expired/unknown snapshot, no search matches, interrupted search, and unresolved references explicit distinct states. No silent fallback.

### J2 — Live Wikipedia research (explicit)
- A user consciously selects Wikipedia English and searches. No fetching before initiation.
- Returned candidate maps to a **specific immutable fetched revision**; each section/reference uses that same snapshot identity.
- Render the approved bounded **plain-text** projection. Explicitly label omitted tables, media, math and active HTML. Never parse remote code in WebView or load third-party assets.
- Display source URL/permalink, retrieval time, original revision ID, normalizer version, license, history/attribution link; citations are metadata and are **not independently verified**.
- Preserve the 15-second bounded upstream operation, two attempts maximum, constrained redirect origin, two admitted upstream operations and 300-second cache expiry, or change them only via separate documented review.

### J3 — Real in-app MCP journey (priority)
- The user intentionally starts the local Server. A **Ready** state and concrete local endpoint are visible.
- The user explicitly invokes **Explore MCP**. A *public SDK* MCPClient + MCPHTTPClient adapter connects over real loopback HTTP and uses the four existing registered tools. No private hooks, fake JSON-RPC or hand-written protocol simulator.
- Discover → tools/list → search_articles → get_article_outline → read_article_section → get_section_references.
- Decode/validate `structuredContent` according to the registered response schemas and domain identity; preserve tool error vs transport error vs invalid output distinctions.
- Render the exact returned article in Research. In Activity, the actual eligible MCP handlers increment; direct local research remains separately identified. No artificial events.
- Cancel a demo in progress and demonstrate joined cleanup and no lingering client operations. Idle app must not open a connection.
- The same research view can remain direct-service-backed when the server is not active. Inject a ResearchClient adapter instead of maintaining two UI implementations.

### J4 — Real stdio client journey
- An explicit, documented CLI option drives MCPClientStdio against the real `research-explorer --stdio` child, not direct ExplorerService.
- The stdio server writes only MCP JSON-RPC frames to stdout. Diagnostics remain safe and on stderr.
- Client launches, discovers and lists, invokes all four tools and terminates/join-cleans its subprocess. Test graceful shutdown, early cancellation, bad schema response, and repeated startup.
- Keep the existing human-readable direct walkthrough only if explicitly labeled **direct (not MCP)**.

### J5 — Developer inspection
- Show a finite demo timeline per guided session: protocol method, tool name, stage, status, resultType, duration, safe byte counts, whether response validation succeeded, and (where appropriate) snapshot/revision identifiers.
- General Activity events remain **bounded projections**: no arbitrary provider text, full tool arguments/result body, request headers, authorization, tokens, personal query strings or credentials in logs or export.
- The detailed inspector is **opt-in, session-scoped and ephemeral**, clearly separated from Activity retention. It must not claim network-wide monitoring or replace protocol conformance.
- Copyable actual endpoint and tested client connection recipe. Explicitly identify that this app's HTTP listener is **anonymous local-development only**, not an authenticated production resource server. Do not imply legacy initialize/session semantics.

### J6 — Ready-to-run macOS demo
- Stable Research Explorer name, icon, version, Help / README and source-selector affordance.
- A reproducible .app package and exact-SHA qualification, including first-run offline journey and optional live smoke.
- Support macOS light/dark appearance, small/large windows, keyboard navigation, text selection, VoiceOver and effective text-size controls.
- Release separately as a demo binary/source artifact alongside SDK; do not assume the app's version and SDK SemVer are identical.

## 4. Visual interaction model (native SwiftUI)

Three existing workspaces continue: **Research**, **Server**, **Activity**. Avoid adding navigation destinations solely for features; place guided exploration in the Server screen, actual results in Research and events in Activity.

Research proposed adaptive layout:
1. **Outline/navigation pane** — title, section tree, breadcrumb/search return; hierarchy, selected section and loading.
2. **Reading pane** — plain text with editorial typography, explicit truncation, source/revision badge, selectable content.
3. **Evidence pane** — associated reference titles, resolved/unresolved identifiers, retrieval, license and exact revision permalink; label not independently verified.

In a narrower window the evidence pane collapses to a toolbar inspector. Persistent sidebar navigation remains under the native NavigationSplitView; no redundant nested split windows. Source switch may be placed in Research, but must preserve the existing **server stopped and actually joined** prerequisite, explain why switching is disabled, and never silently replace in-flight research.

Server proposed groups: **Local host status**, **Guided MCP journey**, **How to connect**, **Recent real activity**.
Activity proposed groups: filters + event Table, inspected redacted details, actual counts and timing chart, explicit "catalogue handler observation" scope.

First-run default should offer offline demo without making any network request. Do not turn source selection into a global hidden startup side effect.

## 5. Domain/data invariants

- Reuse existing ExplorerDomain, ExplorerService, SourceProfile, SnapshotID and PartLocation; no model rewrite merely for UI.
- The immutable identity tuple (provider, project, pageID, revisionID, normalizerVersion) gates every section/ref read.
- r1/r2 comparison must be **explicit and user-initiated**; pinned earlier revision remains pinned.
- Distinguish absent metadata from a valid empty reference list; no invented citations.
- No synthetic article may be presented as live; no offline substitution on a live error.
- Fictional corpus contents are original teaching data and clearly licensed/marked.
- All new render/export operations have finite byte/time/retention limits, bounded concurrency, cancellation checks and testable failures.

## 6. Architecture and isolation

`ResearchController` depends on a `ResearchClient` abstraction. Two adapters:
- **DirectResearchClient** → the existing domain/service for local no-server use.
- **MCPResearchClient** → public `MCPClient` + `MCPHTTPClient`, real wire requests, strict decoding and identity checks.

Only one active Research driver/worker with existing supersession/join semantics. The guided demo owns its real client lifetime and is cancelled and joined before server shutdown or source handoff. Reuse the already bounded ActivityStore for handler observations; never smuggle protocol payloads into it. Development-only connection inspector has its own finite ephemeral model.

No changes to Core SDK public API, HTTP SDK internal classes, transport security policy, or legacy revision support are authorized by this product spec. If a true public SDK defect is encountered, file a separate Core/HTTP issue with a minimal reproducer.

Package integration rules: external versioned dependencies where released, no dependency solely for a logo or marketing showcase, test all supported platform and clean-consumer footprints. See PORTFOLIO_INTEGRATION.md.

## 7. Release stages and work boundaries

| Wave | GitHub issue | Deliverable | Dependencies |
| --- | --- | --- | --- |
| RE-00 | [#32](https://github.com/ThorFuchs/Swift-MCP-Server/issues/32) | Complete product/SwiftPM/app/CLI/path rename | Separate branch; no interference with Core #28 |
| RE-01 | [#33](https://github.com/ThorFuchs/Swift-MCP-Server/issues/33) | Offline corpus, onboarding, source journey | RE-00 |
| RE-02 | [#34](https://github.com/ThorFuchs/Swift-MCP-Server/issues/34) | Real in-app HTTP MCP client and stdio MCP client | RE-00, Core #28 |
| RE-03 | [#35](https://github.com/ThorFuchs/Swift-MCP-Server/issues/35) | Adaptive native research reader, citations/provenance | RE-00/01; coordinate 02 |
| RE-04 | [#36](https://github.com/ThorFuchs/Swift-MCP-Server/issues/36) | Opt-in exchange inspector and connection recipes | RE-02 |
| RE-05 | [#37](https://github.com/ThorFuchs/Swift-MCP-Server/issues/37) | Packaging, docs, accessibility, licenses, exact-SHA tests | RE-00…04, Core/HTTP release gates |

Optional after 1.0:
- [RE-06 #38](https://github.com/ThorFuchs/Swift-MCP-Server/issues/38) Swift-GFM-backed Research Notes only upon user-value validation.
- [RE-07 #39](https://github.com/ThorFuchs/Swift-MCP-Server/issues/39) Swift-SQLite-backed durable notebook only upon retention/privacy agreement.
- Swift-HTML and Swift-Liquid: **not adopted**; rationale in portfolio matrix.

## 8. Release/CI acceptance contract

For each wave: one issue → own branch/worktree → focused changes → regression tests (including race/errors) → PR → review → full CI on *exact SHA* → squash merge after approval. Do not commit directly to protected main.

Must prove:
- Core macOS + Linux tests and Example tests do not hang or silently skip; coordinate ongoing [Core #28](https://github.com/ThorFuchs/Swift-MCP-Server/issues/28).
- Genuine HTTP 2026-07-28 client ↔ server on macOS, genuine stdio child process, both using only public SDK APIs.
- No auth/provenance/privacy/budget regression; no log of body or credentials; network and listener opt-in.
- SwiftPM manifest, product/target directory, generated app metadata, CLI command and README are identical in naming.
- Real native build + reproducible app package; license and attribution; no official Wikimedia endorsement.
- Exact tagged dependency graph for SDK releases, no unresolved \`main\` in an advertised immutable release.
- Explicit blocker handling for HTTP SwiftNIO macOS EOF and optimized build if still pending, rather than treating a green but masked test as a complete production guarantee.

## 9. Non-goals

No complete Wikipedia browser, arbitrary remote HTML renderer, external crawler, Wikipedia editorial client, image downloader, AI agent, automatic network/session start, OAuth server UI, remote public endpoint, universal MCP method inventory, database/FTS cache, Markdown renderer or Liquid template system **unless a later issue establishes direct user benefit**.

## 10. Codex handoff protocol

The future Research Explorer implementation session must:
1. Read this spec, PORTFOLIO_INTEGRATION.md, Core AGENTS.md and the actual release/control issues.
2. Verify current SHAs/PRs, check Core #28 and HTTP blockers.
3. Execute **one RE issue per branch/PR**, beginning with RE-01 or RE-02 only once RE-00 is merged/validated.
4. Return actual commands, test counts, failure evidence, commit and CI links, known issues, and the next proposed issue. Do not claim that code or tests were verified merely because this spec exists.

