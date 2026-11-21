# Research Explorer — Public Swift Library Integration Decision

Status: **Accepted architecture direction for initial release specification**, 2026-11-21. Revisit after concrete user workflows.
Portfolio verification source: actual GitHub README, released versions and SwiftPM Package.swift for ThorFuchs/Swift-JSON, Swift-GFM, Swift-HTML, Swift-SQLite, Swift-Liquid. These are availability/API assessments, **not compatibility builds performed in the example app**.

## Decision heuristic

A dependency belongs in Research Explorer only when it:
1. Solves an actual end-user or developer task, demonstrably better than the existing code;
2. Preserves provenance, privacy, limits and cancellation;
3. Has a stable, versioned package and is tested through the real example;
4. Does not duplicate a parser or add a maintenance burden merely to advertise a portfolio item.

Prefer **actual use to a logos gallery**. Nothing about an external Swift library should leak into the MCP protocol/Core SDK foundation unless that SDK independently needs the feature.

## Matrix

| Library / released version checked 2026-11-21 | Existing or proposed role | Decision for 1.0 | Why and safety concern |
| --- | --- | --- | --- |
| [Swift-JSON 1.9.0](https://github.com/ThorFuchs/Swift-JSON/releases/tag/1.9.0) | Already used for frozen MCP wire parsing, strict JSON and JSON Schema; example's typed tool shapes, inputs and structured results | **USE — already installed** | Real protocol-domain value. Demonstrate validated structured output and exact revision/page identity; no new dependency required. Optional JSONSchemaExamples is not needed for the four deterministic example calls. |
| [Swift-GFM 1.1.0](https://github.com/ThorFuchs/Swift-GFM/releases/tag/1.1.0) | Parse/render user-authored Markdown notes summarizing an exact article revision with citations | **DEFER** to RE-06 | Current upstream research content is *plain text*, not Markdown. GFM HTML rendering is not an HTML sanitizer. Use only if a user-visible Research Notes workflow proves worthwhile. |
| [Swift-HTML 0.1.1](https://github.com/ThorFuchs/Swift-HTML/releases/tag/0.1.1) | Replace the Research Explorer's direct `scinfu/SwiftSoup` package, retaining a traceable source-only vendored backend and MIT notices | **REQUIRED MIGRATION** ([RE-08 #42](https://github.com/ThorFuchs/Swift-MCP-Server/issues/42)) | Package contains upstream SwiftSoup source without upstream tests/webpage fixtures; provenance/notice verifiers support a narrower redistribution review. **Not a drop-in**: ordered text + element traversal currently lacks public wrapper coverage; extend Swift-HTML minimally and prove full normalizer parity first. Still contains MIT SwiftSoup-derived code; licenses and final artifacts must be reviewed. |
| [Swift-SQLite 1.1.0](https://github.com/ThorFuchs/Swift-SQLite/releases/tag/1.1.0) | Optional user-controlled durable article/revision notebook, full-text local search and crash recovery | **DEFER** to RE-07 | The demo's current 300-second ephemeral snapshots are intentional; persistence introduces data rights, retention, stale-revision, privacy and migration contracts. SQLite is already genuinely used by the Core SDK's MCPTasksSQLite product, so no additional showcase pressure. |
| [Swift-Liquid 2.0.0](https://github.com/ThorFuchs/Swift-Liquid/releases/tag/2.0.0) | Configurable export templates, if an actual export product is later requested | **DO NOT ADD** now | No present need for user-configurable template language. Static bounded export is simpler and easier to secure. |

## Swift-JSON: the meaningful present showcase

- Show actual tool name, resultType and strict schema-check outcome from the public MCPClient path.
- Reuse the current example's separately pinned tool definition JSON schema bundles. Never claim a JSON document was validated without executing the validator.
- Distinguish JSON-RPC / transport errors from a tool's isError result, malformed structured content, and domain absent-snapshot.
- Maintain strict Int64-to-decimal-string page/revision IDs and Unicode-sensitive keys; no lossy Double intermediary.
- Existing activity redaction keeps tool result bodies out of general traces. The example should not become a general arbitrary JSON inspection UI.

## Swift-GFM: conditional Research Notes spike (RE-06)

Proposed user action: **Create note from selected revision**; produce Markdown with original title, source permalink, exact revision ID, retrieval date, license and a bounded subset of references. A preview can optionally use a pinned stable Swift-GFM backend once this workflow is approved. No HTML from Wikipedia crosses into the preview; unsafe raw HTML/links require explicit escaping and policy. Export works without hidden external network calls. If simple Markdown export without preview suffices, **do not add GFM**.

## Swift-HTML: approved provenance-driven replacement (RE-08)

**Decision revised on 2026-11-21 at maintainer request.** Replace Research Explorer's direct SwiftSoup dependency with the released Swift-HTML package **before the separately distributed app release**, under [RE-08 #42](https://github.com/ThorFuchs/Swift-MCP-Server/issues/42), as a *separate PR after the rename*. This is a real package-provenance and redistribution benefit rather than a showcase-only feature.

[Swift-HTML third-party provenance](https://github.com/ThorFuchs/Swift-HTML/blob/main/Documentation/THIRD_PARTY.md) records source-only vendoring of SwiftSoup 2.14.4, excluding its original tests and third-party webpage fixtures, with upstream hashes and MIT notices for SwiftSoup/jsoup/LRUCache. The specific upstream fixture licensing concern reported by the maintainer should be identified explicitly in the final inventory; this documentation is not a legal opinion. Swift-HTML's backend remains MIT-licensed SwiftSoup-derived source, and shipping the app still requires the applicable notices.

**API qualification gate:** The existing MediaWikiNormalizer traverses ordered `Node` and `TextNode` children, checks depth/count and preserves text sequence, section nesting and citations. SwiftHTML 0.1.1 exposes element selection and `text()` (normalized), or `directText()` (only if all direct children are text); neither matches the existing traversal contract. RE-08 must obtain a minimal public read-only node/child API in Swift-HTML if needed, then test before/after Wikipedia normalization identity, whitespace, references, URL checks and all limits. Do not access the private SwiftHTMLBackend, replace arbitrary descendant text with `text()`, or relax the 4 MiB input and postparse 100k/128 node/depth limits. The normalizer stays actor-local; no SwiftHTML DOM is Sendable.

The dependency change does **not** belong in this rename/spec PR, and the app must not be published until exact-source/consumer tests and licenses pass.

## Swift-SQLite: explicit post-1.0 persistence gate (RE-07)

A durable research library could create user value: saved exact revisions, offline lookup and honest stale indication. But it requires opt-in persistence, quotas, export/delete, schema migration, attribution, rate-limit policy, consent and no implicit refreshing from a different revision. A cache must never replace current ephemeral published snapshot semantics invisibly.

## Release version policy

Keep Core and HTTP release pinning aligned with the actual tested SDK version graph, not GitHub main. **This rename/spec PR does not change dependencies.** Swift-JSON 1.9.0 stays in place. Introduce Swift-HTML via the separately reviewed RE-08 migration after its required public traversal contract is available and qualified; only then remove the direct SwiftSoup package and audit final MIT notices. Defer Swift-GFM and Swift-SQLite to optional post-1.0 workflows and do not add Swift-Liquid. Every dependency change requires exact integration tests, amended notices and a clean build.

## Review checkpoints
- After RE-00: naming complete; **no dependency graph change**.
- After RE-02: real Core+HTTP SDK client demonstration with schema checks; developer clarity.
- Before RE-05: RE-08 removes the direct SwiftSoup package after strict Swift-HTML normalization parity, source inventory and MIT notices have passed.
- After RE-05: final external dependency/version/license and clean consumer qualification.
- Optional features after release: acceptance of RE-06 and RE-07 only based on demonstrated user benefit.
