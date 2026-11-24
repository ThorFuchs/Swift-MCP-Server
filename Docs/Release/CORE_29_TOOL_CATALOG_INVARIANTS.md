# Core #29 — A2.1 tool-catalog metadata invariants (test-first)

**Status:** Draft regression specification; no production changes and no native test outcomes yet. Baseline `4e561e8469d5a85988d84b1f78f424a7e25aac69`.

## Scope and authority
Read `Docs/CLIENT.md`, `ClientConfiguration.validatesStructuredContent`, `ClientTransport`, the existing `ToolHeaderCases` and `SchemaValidationCases`, and the frozen protocol `Reference/Protocol/docs/specification/2026-07-28/server/tools.mdx`, `server/utilities/pagination.mdx`, `server/utilities/caching.mdx` and `basic/patterns/subscriptions.mdx`.

This is the client's per-tool routing/validation metadata, not a general response cache. The frozen protocol requires HTTP clients to exclude invalid x-mcp-header definitions, and structured content must match its declared output schema. Cursor tokens are opaque (including empty strings). Pages are independently cacheable; the server gives no cross-page consistency guarantee. The following tests use a stable *scripted* server for each individual listing chain and propose a clear local metadata lifetime for a successful fresh list. They do not demand cross-page server snapshot isolation.

## Regression matrix

| Public test | Observable contract | Static expectation (not execution) |
|---|---|---|
| completeRefreshDropsRemovedToolHeaders | Old routing headers do not appear after a successful complete refresh removes the tool; server still decides the call result | Likely red |
| completeRefreshDropsRemovedToolOutputSchema | A directly invoked unlisted tool is not validated against a retired schema; a still-listed schema must not be bypassed | Likely red |
| repeatedRefreshDoesNotAccumulateRejectedTools | Rejection entries describe the current listing, not an ever-growing history; repaired tool is usable | Likely red |
| redefinedToolUsesNewHeaderAndSchemaAndStillRejectsInvalidOutput | Replacement header/schema effective, invalid output fails closed, explicit removal clears annotation | Control |
| stablePaginationRetainsVisitedPagesAndRetiresOldCatalog | Stable scripted pagination retains both pages, respects empty cursor and does not retain retired tool metadata | Likely red |
| malformedRefreshDoesNotCommitUnvalidatedMetadata | Failed validation does not commit unvalidated headers or destroy last validated metadata (no change notification in this case) | Control |
| toolsChangedCallbackCanRefreshWithoutRetainingRetiredHeaders | Real public listen callback can explicitly relist and retire obsolete metadata, without automatic I/O assumptions | Likely red |

## Not yet asserted — follow-up design decisions

- Concurrent cursorless listings completing out of order: decide the local winner rule and validate using explicit rendezvous, not sleeps. The protocol does not supply a globally ordered catalog revision.
- A previous-generation cursor page completing after a newer refresh: define how local pagination generations are retired; do not parse cursors or promise server snapshot consistency.
- A list-changed event with no immediate explicit refresh: decide stale-metadata behavior and failure policy. The protocol's invalidation of a cached response is not a mandate to silently drop validation of previously advertised schemas. Do not automatically fetch or retry behind the caller's back without an explicit contract.
- Bound retained catalog state and rejection diagnostics; define behavior on duplicate names, invalid cursor, interrupted refresh, authorization changes and calls overlapping catalog changes. No shared cache across authorization contexts.

## Run and evidence

    swift test --filter ToolCatalogInvariantCases

    Scripts/test.sh

First command needs no subprocess fixture for this new suite. Run against the exact test-only SHA and retain logs with case names and assertions. Ordinary CI remains unmodified and intentionally may be red: no `withKnownIssue`, disabled tests, retry, enlarged deadline or validation bypass. Do not merge a failing regression-only PR. Once red cases are confirmed, add a narrowly scoped implementation commit to the same PR and prove the before/after results; audit overlap/notification policy before declaring #29 complete.

The new suite's own tests are serialized to limit additional compile pressure; no existing suite/test policy changes. Existing A1.2 diagnostic matrix is tied to its immutable 26-test baseline SHA; do not apply its fixed test-count assertion to a future expanded suite without a reviewed new baseline.



## A2.1 replay on integrated A1

Original seven tests copied without body changes from PR #57 commit `a2c3d31db2e0bf062aba135ca4b3f37f69efb862` to the qualified Core `02958abee82c363b879aa013c38229edb9a1c116` (import merge `e98d03ce7a612fce9e1eeb6db4a27ec826dc6e44`). Historical native macOS [CI 45265755646](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45265755646/job/138012085888) actually recorded five failing tests, six issues, and two passing controls. The old PR description is pre-execution; the historical log is the authority. Reproduction on the new base is still required.

Add six test-first public API contracts:
- Partial successful listing and failed terminal refresh retain known, unvisited metadata until a successful terminal page; new observed definitions take effect on successful pages.
- A later page repairs a rejected definition (latest accepted observation of a name).
- A late in-flight continuation must not restore obsolete metadata after a newer successful refresh, while returning its own validated page.
- For overlapping cursorless requests, the latest initiated refresh owns the right to commit; an older late completion does not overwrite it.
- A call captures header routing and output schema together before its first suspension; a later refresh must not silently drop that call's validation.
- A standalone opaque-cursor request is still supported and may update observed names without inferring any removals.

The overlap tests use explicit one-use transport rendezvous, not delays to order requests; the 10-second timer is a failure bound for a missing rendezvous. All seven original test bodies remain unchanged; no existing assertions weakened. Thirteen test functions, one serialized new suite, no fixture or production changes. Expected new controls and failures require actual native execution; not a fresh RED claim.

The choice is local metadata consistency, not a server revision protocol. A failed/cancelled page leaves metadata unchanged; a superseded valid page still returns its own validated view. Notification-only behavior remains explicit host refresh, no automatic network requests and no validation bypass. Full retained-byte/count limits and auth-context changes remain a separate audit; the tests do not assert a global server snapshot.


## Implementation candidate (after test-only replay `377c4225942dcc8982f0de46ec94f629fdabf827`)

Replace the independent growing maps and rejection history by a coherent
private per-name metadata record. Each page is wire-validated and locally
classified before one actor-isolated, non-suspending commit. Track the
observed names in a nil-origin listing chain, not an inferred server version.
A successful terminal page retires unvisited entries; incomplete chains keep
previously known validation for unvisited names. Matching continuation cursors
are opaque, including empty strings. An independent cursor response may update
observations, but abandons chain completeness (no deletion). Failed pages do
not update the state. Capture a local revision at request entry; late
continuations cannot overwrite a newer committed observation. For concurrent
heads, latest initiated owns the commit even if it subsequently fails;
previous validated metadata remains intact on failure. This is deliberately
a local ordering policy, not a promise of consistent server pages. Calls pin
the observed routing and validation together before any asynchronous exchange
and reuse that output schema for the final result; no validation is relaxed
by a concurrent refresh. Direct calls without a known schema still go to the
server, as before. Invalid HTTP header tools remain excluded from returned
items, raw JSON unchanged; their observed output schema remains available for
direct-call validation, matching the prior policy.

No public signatures, dependencies, fixture sources, original tests,
timeouts, or wire validation changes. Per-client cardinality/byte ceilings,
authorization-context identity, notification-only invalidation policy and
duplicate-name protocol semantics are deferred follow-ups, not passed gates.
New branch holds the candidate without opening or updating PR #57 while the
independent Studio notification proof runs. Native Swift 6.4.2 qualification
on the immutable RED and candidate heads, full macOS/Linux CI and HTTP
fixture interoperability remain required.


Additional test-first controls: canonically equivalent but byte-distinct
opaque cursors must not complete a chain; a later failed head leaves
previously validated metadata intact and supersedes an older in-flight
head. Scripted transport compares cursor identities via existing ScalarText.
Fifteen total public test functions; seven original test bodies unchanged.

The cursor match uses existing MCPProtocol.ScalarText to preserve exact UTF-8 identity, rather than Swift String's canonical equivalence. Tool-name key semantics otherwise remain unchanged.
