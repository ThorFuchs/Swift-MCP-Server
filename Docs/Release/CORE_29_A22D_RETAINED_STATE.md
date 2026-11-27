# A2.2d — client retained state, exact identity and context isolation (#29)

Status 2026-11-27: SOURCE_AUDIT / TEST_ONLY_PREPARED; native execution NOT_RUN.
Immutable integrated A2.2b.1 base `415f62594e87a573ebea1f2bb701d5c24ad92cc1`, tree
`c6b300777f6ba9d4d26c3d88df861a7b56f65c91`.
The owner of this branch is the A2.2d audit, not the transport, server catalog,
HTTP authorization or MRTR implementation. #29 remains open.

## Authority and scope

- [CS3](../Plans/CS3-CLIENT-API-REVIEW.md), especially A9, A11 and C
  (concurrency, validation, limits, lifetimes); [client contract](../CLIENT.md).
- [A2.1 catalog contracts](CORE_29_TOOL_CATALOG_INVARIANTS.md),
  [A2.2a/b/c/d scope](CORE_29_A22_CLIENT_LIFECYCLE.md), ADR-0005, ADR-0006 and
  [ADR-0007](../ADR/0007-client-frozen-wire-cache.md). Use the implemented
  callback transport API when historical ADR wording predates CS3.
- Frozen MCP 2026-07-28 tools, resources, subscriptions, caching and pagination
  specifications, schema.json; retained Tasks and Skills extension overviews.
  Do not replace these with a newer upstream draft or reinterpret SHOULD as MUST.
- Inspect all state-owning Core client source files at the above immutable
  baseline. Physical transport routes, writer queues, child process state and
  server-owned catalogs/task stores are cross-track boundaries, not part of
  this branch's implementation scope. Host-retained public value types are
  accounted for as host-owned, not as an SDK-managed cache.

The caching specification limits reuse of private *responses* to the same
authorization context. Core does not implement a response cache: discover,
list, read and completion perform a new exchange, and return the raw result.
Catalog metadata used by callTool is a separate retained state, so lack of a
response cache is not proof of context-safe metadata. TTL hints do not by
themselves justify retiring a schema and silently weakening validation.

## D0 — state inventory (source facts, not native outcomes)

Source anchors below refer to the immutable base, not mutable main.

| ID | Retained state | Owner and lifetime | Enforced bound / retirement | Assessment |
| --- | --- | --- | --- | --- |
| F1 | frozen document, definition plans, retainedBytes | process-local ClientFrozenWirePlanCache.shared actor; immutable artifacts | 48 definitions + 33,554,432 reported peak logical bytes aggregate; non-admitted plan still evaluated; warm entries not evicted | historical qualified policy, no RSS claim |
| F2 | parse/compile/hit counters | same actor | saturating UInt64 counters; no per-request history | source bounded |
| C1 | configuration (info, capabilities/extensions, handlers, limits), transport reference | Client lifetime, caller supplies values and captures | immutable stored configuration/reference; host controls captures and underlying transport; no automatic credential or context lifecycle | per-client, not a principal binding |
| C2 | nextID | Client actor lifetime | monotonically incrementing Int, no collection; theoretical overflow not reached in audit | per-client namespace, shared physical transport coordination belongs to A2.2b |
| C3 | toolMetadata: [String:ToolMetadata] including headers, outputSchema JSON, rejection | Client actor, updated on admitted validated listing pages | complete fresh chain retires unseen names, failed/stale pages do not commit; no cumulative count/byte cap | source growth risk; String identity candidate D1 |
| C4 | toolListing: nextCursor + observedNames Set<String> | Client, active local listing chain | replaced on new admitted head, terminal or independent page clears; no cumulative name/byte limit for incomplete chain | source growth and identity risk |
| C5 | catalogRevision, latestListingHead | Client actor | two UUID tickets (one optional), latest-initiated head and same-revision continuation policy | constant retained state; A2.1 existing evidence |
| C6 | rejectedTools array | Client actor, regenerated from metadata | one latest rejection per admitted dictionary key; sorted; no independent cap | grows with metadata, not an append-only history |
| C7 | captured ToolMetadata, derived parameterHeaders, arguments | per call across perform/MRTR and reentrant callbacks | releases when invocation exits; in-flight call pins old metadata even if catalog is refreshed | correct snapshot policy; aggregate in-flight ownership A2.2b |
| V1 | WireValidator.schemas: [JSON:CompiledJSONSchema] | each Client's WireValidator actor | **256 entries**; compile new miss, clear all if count >=256, then insert; no aggregate logical-byte accounting of key plus plan, no catalog retirement hook | count bound exists, bytes/lifetime open; no shared application schema |
| V2 | fresh evaluation/report and failed compile | current invocation | existing SchemaCompilerAdapter/SchemaValidatorAdapter operation limits; failed compile not published; invalid values not cached | no response/value cache; operation limit != retention bound |
| R1 | perform continuation, round/versionRetried, request body/id/token, final response mutex, local callback captures | one call / one exchange round on caller task | maximumInputRounds (default 8), one version retry, one terminal response; JSON parsing limits; not a persistent session | MRTR/handler errors and cancellation A2.2c |
| R2 | answer requests/responses, elicitation schema | one answer call; V1 may outlive it | input and operation limits; no persistent answer map in Client | A2.2c; application-schema plan retention V1 here |
| S1 | SubscriptionAdmission id, requested/agreed CoreFilter (three flags + Set<ScalarText> URIs) | one typed listen exchange | first unique ACK/subset, one exact ID, request-bounded filters; no extension-specific policy; released with exchange | existing A2.2a; actual callback release A2.2b |
| S2 | raw extension filters, events, capabilities | configuration, exchange, then host values as applicable | encoded/parsed limits; Core validates known admission order/ID, extension owns member grammar | preserve raw JSON, no generic authorization inference |
| T1 | TasksClient client reference + pollingBounds | wrapper value | host-provided interval bounds (default 50 ms to 30 s); no persistent task response cache | per wrapper |
| T2 | wait current snapshot + answered Set<String> | one wait invocation | releases when wait ends; dedup input keys, no explicit cumulative key cap or total polling deadline | count/identity follow-up with A2.3/A2.2c, not a new task lifetime limit |
| T3 | FollowState agreed Set<String>, finals [String:TaskSnapshot], done stream | one follow call, child listen task | bufferingNewest(1) completion signal; agreement/final maps have no independent count/byte cap; current record accepts any terminal snapshot | A2.3 already tests foreign callbacks/finals and premature completion; coordinate membership before any additional bounds |
| K1 | SkillsClient client reference | wrapper value | no SDK file/list cache | caller retains SkillEntry, LoadedSkill, manifests and verified file bytes |
| K2 | skill URI/manifest/digests, frontmatter, read contents | host-owned entry/loaded values and one load/file invocation | checks manifest membership, byte size/digest/frontmatter; equality uses Swift String in fetch; no originating-server binding in value | origin/identity review; host policy and valid URI fixtures needed |
| P1 | Page, Tool, ToolResult, Resource, Prompt, Content, TaskSnapshot, SkillEntry, etc. | caller owns returned raw/typed values | no Core retention beyond explicitly inventoried metadata; parsing limits only bound individual values | not SDK-owned aggregate storage |
| X1 | stdio routes, outgoing continuation, terminal flags, reader/line buffers, run configuration | StdioClientTransport/run | max pending and per-line limit, outstanding A2.2b.2–5 aggregate queue/lifetime audit | boundary, do not modify |
| X2 | authentication headers/tokens/issuer/resource/scope state | host and HTTP sibling repository | outside Core; LoopbackTransport binds immutable principal/origin; generic ClientTransport exposes no authority/epoch | context handshake decision before A3 |

Detailed source references: Client.swift lines 18–147 (C1–C7), 223–362
(R1/R2), 364–411 (S2), 425–461 (V1/V2);
ClientFrozenWirePlanCache.swift (F1/F2); ClientConfiguration.swift;
SubscriptionAdmission.swift (S1); ClientTypes.swift / ClientViews.swift
(P1/S2); TasksClient.swift lines 69–225 (T1–T3);
SkillsClient.swift lines 12–175 (K1/K2); ScalarText.swift;
ToolHeaders.swift; ClientTransport.swift; LoopbackTransport.swift.
The per-process frozen cache's byte accounting is upstream logical
accounting, not physical memory. No aggregate client-wide memory bound
is established merely by the configured JSONLimits or 256-entry limit.

## D1 — identity and state boundaries: source findings

1. Tool.name is a string in frozen schema.json without an ASCII pattern.
   tools.mdx recommends ASCII characters and uniqueness (SHOULD).
   Client.listTools currently accepts canonical-equivalent but byte-distinct
   names, and uses Swift String dictionaries/sets for observations and
   retained metadata. Swift canonical equivalence can merge the two names,
   while the outgoing name preserves its original text. Source hypothesis:
   wrong Mcp-Param-* mapping and wrong output schema for an admitted name.
   Local SDK policy under test: if names are admitted, preserve exact
   identity rather than silently alias them. No claim the server is
   encouraged to emit Unicode names; no new normative protocol MUST.
   A stricter reject-invalid-name policy would require explicit review;
   do not silently change the admitted public name surface. Duplicate exact
   names with conflicting metadata are a separate policy decision.
2. Cursor equality and admitted resource URI equality already use ScalarText.
   Test valid distinct URI strings without treating normalization as identity.
   Frozen ResourceUpdatedNotificationParams notes a URI may refer to a
   sub-resource: current explicit exact-URI policy is narrower; review that
   separately against provider semantics. Do not add arbitrary path-prefix
   authorization or equate percent-encoded separators.
3. Known subscription filters have a local admission contract; unknown
   extension filters and payloads are open values. Tests must not invent
   generic extension membership rules. Reserved Core filter keys supplied
   through extensions need an explicit collision policy before freeze.
   A2.3 owns Tasks-specific membership/terminal outcomes. Skills origin
   binding and scalar comparison require an agreed host/wrapper contract;
   raw Unicode URIs may be outside RFC3986 and are not used as the first
   proof of a Skills defect. No generic normalize/URL rewrite.
4. Catalog state and V1 are per Client. Separate clients over separately
   owned transports are the first positive isolation control. That is not
   same-client credential rotation. Core cannot detect authority changes:
   ClientTransport has exchange and mirrorsToolParameters only.
   HTTP sibling main inspected at
   `2cbedd510b15f510c24373ea45ca4fc9cf754cbe` (HTTPClientTransport.swift
   blob `e227f81d89c4a640e45e8ff0eb062d17af8dede5`):
   header closure and authorization provider are called per request; 401/403
   handling may retry after authorization changes. An unchanged Core Client
   can therefore hold metadata from an older context. This is an unresolved
   interface/security design finding, not a reproduced OAuth leak. Discuss
   effective authority boundary with HTTP owner: distinct Client/transport
   per stable context, or an explicit coherent invalidation/epoch contract
   before API freeze; include in-flight calls, late listing responses,
   retry behavior, and credential refresh versus genuine authority change.
   Do not key by raw access tokens, infer authority from serverInfo/name or
   flush silently while allowing stale calls. No API addition in D0/D1.

## D2 — bounded retention decision pending

- C3/C4/C6: independent cursor pages and unfinished listing chains can
  increase retained names despite a bounded message. Test with small finite
  pages and an empty complete refresh. This is characterization, not proof of
  an agreed cap violation. Define count and logical-byte budgets covering
  names, headers, schema JSON, rejections, active listing set and in-flight
  snapshots; agree policy/numbers before a RED asserting a threshold.
- V1: verify validation remains enforced across the existing count-boundary,
  failed offline compile and reuse. Choose explicit aggregate logical-byte
  accounting (schema keys + compiled plan reports) and safe non-retaining
  fallback as a follow-up design, not an arbitrary RSS threshold. Do not
  skip validation after a failed compile, count/byte exhaustion or eviction.
- Catalog capacity is not a schema-plan optimization. Silent eviction of
  still-advertised output schemas can disable callTool validation. Prefer
  review of atomic admission failure preserving prior committed metadata
  and typed failure, or another explicitly justified contract. No arbitrary
  new public limit or eviction strategy selected here.
- Existing 15 A2.1 catalog and 17 A2.2a listen regressions remain required.
  Exact retirement and in-flight snapshot semantics must remain intact.

## D1.1 test-only batch (seven functions)

| Test | Source prediction | Acceptance and witness |
| --- | --- | --- |
| distinctAcceptedToolNamesDoNotShareRoutingOrOutputSchemas | RED predicted | two accepted distinct names, respective actual request headers and numeric/string output validation; strict wire names, no extra exchange |
| separateClientsKeepPrivateCatalogMetadataIsolated | PASS | different clients same name, incompatible schemas/headers, new client unlisted; correct positives and exact validation failures, no inherited headers |
| independentPagesCharacterizeRetentionUntilCompleteRefresh | characterization PASS | 32 independent cursor pages, public rejectedTools 1..32, complete empty refresh retires all; no proposed cap |
| unknownExtensionPayloadStaysExchangeLocalAndRaw | PASS | original filter and nested notification payload preserved; correlated exchange then independent known filter |
| resourceSubscriptionDoesNotNormalizeDistinctURIStrings | PASS | accepted exact URI event; encoded-separator-distinct event rejected before callback |
| schemaChurnAcrossCountCeilingNeverBypassesValidation | PASS | 257 distinct small schemas, 514 value evaluations plus first schema reuse (516 total), valid accepted and invalid rejected, frozen cache untouched |
| failedDynamicPreparationDoesNotPoisonWarmValidSchema | PASS | unresolved external ref fails offline twice, warm valid/invalid checks unchanged |

Five public functions use deterministic finite transport scripts, actual
outgoing request ID, strict ScalarText request matching, raw wire fixture
results and captured headers. Two internal validation tests use the existing
MCPClientWireCacheTests @testable seam, not private dictionary introspection.
No sleeps, new production APIs, test-only hooks, new dependencies or changed
existing assertions. Churn tests check correctness at the source count
boundary, not retained byte usage or observed eviction count.
Native acceptance: each suite compiles, exact named test results and
assertions; a schema/fixture error, timeout or unrelated failure is not
the predicted identity RED. Keep original RED source immutable; no production
fix until actual evidence and agreed scope. If all pass, record PASS rather
than manufacture RED.

Local authoring: Swift 6.2.1 Linux x86_64 parser accepts both files;
Swift language mode 6 typecheck with API stubs succeeds (not SDK compilation).
Independent Swift dictionary probe demonstrates String canonical-equivalence
aliasing vs the actual ScalarText comparison/hash algorithm. That probe is
not a native SDK regression. Remote Git blobs match exact locally parsed
sources: public `563b031ca29605edbec6dda856eed9a2e5b172ca`; validator
`ee65e96b368b5d9e911297b6d4f85e42070fb10e`.

Native focused Debug on Studio after host admission:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientRetainedStateCases
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientDynamicSchemaRetentionCases

Separate logs/exits; continue to second suite after expected RED in first.
Record exact SHA/tree, source blobs, six dependency-file hashes, native
toolchain, raw test output and clean status. Full base 368 functions;
375 expected if this batch is admitted independently unchanged. After
review: targeted GREEN, full locked Debug/Release macOS/Linux, external
HTTP regression on exact integrated graph and post-merge; AMD64 separately.

## Coordination and next gates

At audit start A2.2c branch head
`fa042df7bc4334d83030cd82355f37c106d00643` only added
ClientMRTRContractTests.swift. A2.3 head
`256cae7c813b0f146167ef1d928ca35a47157a4c` added 27 consumer tests
and its contract. No production edit in either branch at that snapshot.
A2.3 explicitly owns Tasks follow foreign-task/get/terminal issues and
Skills get mismatched identity/cache-hint/cursor checks; do not duplicate
their regression bodies. A2.2d owns cross-context, exact identity,
retention budgets and cache/metadata lifecycle; coordinate wrapper changes
with A2.3 and any handler-schema/cancellation changes with A2.2c.
If a fix is justified, keep Client.swift changes restricted to catalog
metadata and WireValidator; shared request engine belongs to A2.2c.
Control Tower must review common file diffs, contracts and current base
before any sequential merge; requalify combined tree. No main mutation,
PR, CI dispatch, new ADR changing public API, dependency edit or RC1 GO.
