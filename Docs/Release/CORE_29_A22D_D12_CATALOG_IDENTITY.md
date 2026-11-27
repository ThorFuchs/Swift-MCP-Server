# A2.2d D1.2 — exact catalog identity boundaries

Status: D1.1 EXPECTED_RED_CONFIRMED; D1.2 native RED2 NOT_RUN.
Shared integrated base `415f62594e87a573ebea1f2bb701d5c24ad92cc1`.
Original immutable D1.1 candidate `4bec9f8f30075e3f6699a5eb1513b510eb2c9342`,
tree `c943143e5f7702a2e304e166da298f5721851bfd`. Preserve its tests
and [inventory](CORE_29_A22D_RETAINED_STATE.md) byte-for-byte.
[Accepted native evidence](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7229719596):
6 PASS, 1 expected RED, two issues, both native builds complete,
integrity PASS. Archive SHA-256
`f9272559b91419506da7067f575d020d8c7c0a78e16462ad82346a0027fd5975`.
The original failure demonstrates that an admitted tool name uses
another definition's schema and that expected routing headers differ.
The original log did not print actual header values.

## D1.2a — two new test-only boundary probes

Test commit `b7f7865f07a49269d8ff59d17f7e4b6abf629707`.
[ClientCatalogIdentityBoundaryTests.swift](https://github.com/ThorFuchs/Swift-MCP-Server/blob/b7f7865f07a49269d8ff59d17f7e4b6abf629707/Tests/MCPClientTests/ClientCatalogIdentityBoundaryTests.swift),
blob `5bafda58b192bf1be0b444503807e58c4b8675aa`.
Only new source file, no existing test/helper modifications. Finite
scripted public ClientTransport; each exchange checks method, the exact
UTF-8 identity of both outgoing routing name and decoded wire name,
and the exact cursor. No sleeps or timing-dependent assertions.
Fixtures use two names: composed café (UTF-8 63 61 66 c3 a9)
and decomposed cafe + U+0301 (63 61 66 65 cc 81). The frozen
Tool.name schema admits both; the protocol ASCII recommendation remains
SHOULD. This is a local policy of preserving identity for admitted names.

| Function | Predicted baseline | Required GREEN |
| --- | --- | --- |
| partialListingRetainsDistinctPeerAndCompletionRetiresOnlyUnseenIdentity | RED | incomplete fresh chain retains unseen distinct peer; terminal page retires exactly that peer; direct invocation then carries no stale header/schema; retained peer still validates correctly |
| rejectionDiagnosticsRemainDistinctAcrossReorderRepairAndRetirement | RED | two separate rejection identities/reasons even when listing order reverses; repair A on independent page keeps rejection B; complete refresh retires unseen B |

First probe: seven exchanges, four calls, two intentionally valid
decomposed-name outcomes (before/after retirement), one valid surviving
numeric outcome and one required exact invalidResponse for surviving
name's invalid string output. Expected header arrays:
`[["Mcp-Param-Second: west"], [], ["Mcp-Param-Fresh: west"], ["Mcp-Param-Fresh: west"]]`.
Baseline source predicts both decomposed-name calls will wrongly use
Fresh and fail schema validation, while surviving numeric validation
continues to work. Observe actual outcomes, do not assert predicted
failure as success. A22D_D12_CALL prints actual name bytes and headers.

Second probe: four exchanges. Two invalid definitions deliberately
produce distinct diagnostics (not an HTTP token / non-primitive
property). Both fresh lists are empty after filtering; retain both
diagnostics in deterministic name order independent of list order.
For names equal under Swift String comparison, require UTF-8
lexicographic tie-break (decomposed first); preserve established String
ordering for non-equivalent names. This tie-break is a local design
decision to make previously documented sorted diagnostics deterministic,
not a new MCP normative rule. Independent cursor repair then leaves
only decomposed rejection; completed fresh list removes it.
A22D_D12_REJECTIONS and A22D_D12_REPAIR print actual name bytes/reasons.
No test permits an unrelated wire mismatch, compile failure or timeout
to count as RED. Both scripts must be consumed.

Authoring: exact blob parsed with Swift 6.2.1 Linux x86_64; language
mode 6 typecheck with stub API signatures including Swift Testing
macros and actor checks passed. Actual fixture builders rendered 11/11
JSON-RPC responses accepted by Foundation JSON parsing, first list
verified both exact UTF-8 names. These are local authoring controls,
not actual SwiftPM dependency compilation or native SDK results.

Run focused Debug on idle Studio:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientCatalogIdentityBoundaryCases

The launcher also reruns original D1.1 public and validator suites
separately, preserving both original and new evidence (nine functions
total; predicted six PASS, three RED). All three legs must run even
when the expected first/second failure occurs, unless infrastructure
or integrity prevents continued execution. Require real named logs,
actual exits, zero tee exits, exact source hashes, clean working tree
and six unchanged dependency-file receipts. Archive all six actual
dependency bytes too, for independent hash verification. Native
RED2 not yet observed. No release decision or production edit.

## D1.2b — planned minimal fix, AFTER valid RED2

Use existing MCPProtocol.ScalarText as key everywhere in retained
catalog identity: ToolListing.observedNames, toolMetadata, local
observations, optional observedNames, insertion and callTool lookup.
No normalization, no new API or dependency. Keep public String names
and raw payloads unchanged. Sort rejection names by existing String
ordering with UTF-8 tie-break for canonically equal names. Preserve
exact cursor comparison, latest-head ownership, revision admission,
atomic commit, captured in-flight metadata, failed page behavior and
unvisited name lifetime. No change to dynamic schema budget or
authorization-context contract. No fix to exact duplicate-name policy
without separate agreed contract.

A2.2c current head at review
`ca6c86b0ddddc16a3f49c7d1424818e61adc105e` has production
Client.swift blob `eaf5b91a37c582a13f845cda856c0246a9a1d617`.
Actual source comparison against base
`7953099ee15fcf9999af33894a1359498fd59e75` establishes byte-identical
prefix before // MARK: Request engine and byte-identical WireValidator
body. Catalog change and MRTR change are currently disjoint regions
of the same file; do not overwrite or cherry-pick either blindly.
Recheck sister branch head and regions before production commit;
sequential integration with exact combined qualification is required.
A2.3 still only test/docs additions. No main edit, merge, PR, CI dispatch
or release tag. D2/D3 budgets and D5 authority still require decisions.

After valid RED2 and localized GREEN change, run nine functions,
15 existing ToolCatalogInvariantCases, both listen suites and frozen
cache regressions, then full locked native Debug/Release (377 functions
on isolated branch if unchanged), ARM64 CI and external HTTP regression.
Do not declare D1.2 or A2.2d closed on authoring checks alone.
