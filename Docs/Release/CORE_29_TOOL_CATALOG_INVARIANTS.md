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

