# A2.3 — Public-consumer contracts (Core #29)

Status 2026-11-27: source audit and first test-only candidate prepared;
native qualification NOT_RUN. No production fix or API freeze decision.
Baseline `415f62594e87a573ebea1f2bb701d5c24ad92cc1`, tree
`c6b300777f6ba9d4d26c3d88df861a7b56f65c91`.
Branch `test/core29-a23-consumer-contracts`. Independent from A2.2b/c/d.

## Authority and existing execution evidence

- [Accepted CS3 A1–A11, B1–B5, C and D](../Plans/CS3-CLIENT-API-REVIEW.md),
  blob `057aec8ec16fe811ade8c542aa9a58a84a359764` at baseline.
- [Core client guide](../CLIENT.md) and the public DocC catalogs of
  MCPClient, MCPTasksClient and MCPSkillsClient.
- Frozen [2026-07-28 schema](../../Reference/Protocol/schema/2026-07-28/schema.json)
  and Resources, Prompts and Completion specification pages in Reference/Protocol.
  Frozen extension overviews: Reference/Protocol/docs/extensions/tasks/overview.mdx
  and skills/overview.mdx. These are the locally retained extension descriptions,
  not a separately fetched latest extension-specification claim.
- [Issue #29](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29) and
  [API/release contract #30](https://github.com/ThorFuchs/Swift-MCP-Server/issues/30).
- [Baseline post-merge CI 46062633342](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/46062633342):
  macOS job 140720307091 and Linux job 140720307360 checked out the exact
  baseline, Swift 6.4.2, ARM64, 16 passing bundle summaries, 368/368
  functions each. Both verify all six dependency files; macOS 15/15 DocC.
  Reviewed raw logs: the 15 existing consumer witnesses named below
  each passed exactly once on each platform. This is baseline evidence,
  not a pass of the new 27 tests.

Public API under review: Client, its configuration/views/errors/transport
interface, TasksClient and SkillsClient. Physical transports (Stdio, HTTP)
are separate owners. No change to Reference, manifests, dependencies,
public signatures, existing tests or source in this batch.

## CS3 decision inventory

Status vocabulary: BASELINE_PASS = specific pre-existing test passed in
both baseline CI legs; SOURCE_PRESENT = declaration/implementation inspected,
not complete behavioral qualification; PROBE = new test not executed;
FREEZE_REVIEW = ambiguity for #30 rather than an authorized breaking change;
DEFERRED = separately owned contract. Source and test paths below refer
to the immutable baseline unless explicitly labeled new.

| CS3 | Existing source / execution evidence | Acceptance for A2.3 | Status |
| --- | --- | --- | --- |
| A1 resources/read typed contents | Client.readResource; ClientTypes.ResourceContents; ClientCases.discoverListAndCallPreserveWhatTheServerSent; ClientTypeViews.resourceContentsRequireTextOrValidBase64 | Ordered multiple text/blob entries, exact decoded bytes, missing/optional fields handled, valid empty contents distinct from typed not-found, malformed content rejected. Raw retention question below. | BASELINE_PASS + PROBE + FREEZE_REVIEW |
| A2 PromptResult / messages | Client.getPrompt, ClientTypes.PromptResult; ClientTypeViews.promptsCompletionsTemplatesAndServerInfo | Both roles, typed content union, exact argument encoding and omitted empty arguments, raw envelope and original message metadata retained; malformed role rejected. | BASELINE_PASS + PROBE |
| A3 Content / ToolResult | ClientViews.ToolResult; ClientTypes.Content; ClientTypeViews.contentBlocksDecodeAndUnknownOnesPassThrough | Typed known blocks and text projection, preserve structuredContent, error flag and raw; direct raw view preserves unknown. Do not silently weaken frozen standard wire schema. | BASELINE_PASS + PROBE + FREEZE_REVIEW |
| A4 Completion / references | Client.complete, ClientTypes.CompletionReference and Completion; ClientTypeViews.promptsCompletionsTemplatesAndServerInfo | Both ref discriminators, exact argument/context values, omission vs empty, optional total/hasMore and raw, accept 100 values and reject 101. | BASELINE_PASS + PROBE |
| A5 ResourceTemplate / typed page | Client.listResourceTemplates, ClientTypes.ResourceTemplate; same ClientTypeViews witness | Preserve unexpanded URI template, advertised metadata and raw, opaque cursor incl empty, reject invalid template. | BASELINE_PASS + PROBE |
| A6 RejectedTool | Client.rejectedTools, ClientTypes.RejectedTool; ClientTypeViews.errorsCompareAndExposeCodes; ToolCatalogInvariantCases (A2.1) | Typed Sendable/Equatable representation, previously admitted catalog lifecycle remains intact. | BASELINE_PASS + PROBE for public type shape; retention A2.2d |
| A7 LoggingLevel | ClientConfiguration.logLevel, ClientViews.LogMessage, ClientTypes.LoggingLevel; ClientTypeViews.errorsCompareAndExposeCodes | Eight severity cases, typed configuration and delivered level; public compile witness. Further callback lifetime owned by A2.2b. | BASELINE_PASS + PROBE |
| A8 Implementation / ServerDescription | Client.discover, ClientViews.ServerDescription, ClientTypes.Implementation; ClientTypeViews.promptsCompletionsTemplatesAndServerInfo, ClientCases.discoverListAndCallPreserveWhatTheServerSent | Typed identity name/version/title, raw extra fields and declared extension settings remain available. | BASELINE_PASS + PROBE |
| A9 SubscriptionFilter | Client.listen, ClientTypes.SubscriptionFilter; ClientTypeViews.filtersAndHandlerAnswersEncodeAsTheSchemaExpects; ClientListenInvariantCases and ClientListenBoundaryCases (A2.2a) | Public typed filter and extension members; preserve already qualified admission behavior. Tasks-specific extension membership is A2.3, general identity/retention A2.2d. | BASELINE_PASS + PROBE; physical delivery DEFERRED A2.2b |
| A10 ClientError | ClientError.swift; ClientTypeViews.errorsCompareAndExposeCodes | Match typed code/message/data, required extension names, modern and legacy resource not-found; no message-string parsing. | BASELINE_PASS + PROBE |
| A11 typed handlers | ClientConfiguration and ClientTypes; ClientTypeViews.inputRequestsDecode, filtersAndHandlerAnswersEncodeAsTheSchemaExpects; ClientCases.inputRoundsAreAnsweredByTheConfiguredHandlers | Public Sendable typed signatures for elicitation, sampling, roots, raw additional handlers. Behavior across rounds, cancellation and handler failures owned by A2.2c. | BASELINE_PASS + PROBE for public shape; MRTR DEFERRED |

CS3 B1 pagination helpers, B2 typed Tool annotations/execution, B3 shared
transport retryability, B4 generic typed structured decoding and B5 OAuth
authorization-state stream are additive roadmap items, not A2.3 requirements.

CS3 C: Client actor, calling-task ownership, validation and limits are
documented; current catalog state is more detailed than the original CS3
description. A2.1 covers catalog lifecycle; A2.2b covers physical
ownership/cancellation; A2.2c covers MRTR; A2.2d covers retained schema,
resource identity and authorization isolation. A2.3 verifies the consumer
shape and standard result validation without rewriting these subsystems.
Generic Client.request validates only the JSON-RPC/result-object contract,
so extension wrappers own their additional semantics (also stated in
MCPClient DocC). Do not interpret CS3's standard validation promise as
automatic validation of arbitrary extension schemas.

CS3 D: Core DocC catalogs present and 15/15 build receipts at baseline.
Existing real fixture and ResearchExplorer client are evidence; a fresh
external package consumer, canonical README/example and final symbol
inventory belong to #30. No new manifest or example in this first batch.
HTTP client and authorization products belong to the separate HTTP audit.

## New public-wire probes

Files: Tests/MCPClientTests/PublicConsumerContractTests.swift (13 functions),
Tests/MCPTasksClientTests/PublicTasksConsumerContractTests.swift (7),
Tests/MCPSkillsClientTests/PublicSkillsConsumerContractTests.swift (7).
No internal imports. Finite scripted ClientTransport uses the actual request
ID, independently authored response frames, exact method, routing name,
params/cursor, version metadata and call counts. Each receive is awaited.
These are consumer/protocol tests, not physical transport or race proof.

### Resources / Prompts / Completion / shared types

| Test function | Acceptance and predicted baseline |
| --- | --- |
| resourcePagesPreserveRawMetadataAndEmptyCursor | PASS expected: list metadata, raw title/size/_meta, empty cursor forwarded exactly, terminal nil |
| resourceTemplatesPreserveOriginalTemplateAndOpaqueCursor | PASS expected: template/title/description/MIME/raw; opaque continuation unchanged |
| resourceReadReturnsAllTextAndBinaryEntriesInOrder | PASS expected: multiple URIs allowed, UTF-8 text and binary incl 0xff, empty text and optional MIME |
| existingEmptyResourceIsNotConvertedToNotFound | PASS expected: successful empty contents |
| resourceNotFoundPreservesModernAndLegacyTypedErrors | PASS expected: -32602 and -32002 retain code/message/data |
| resourceReadRejectsInvalidBlobAndMissingRequiredMetadata | PASS expected: malformed base64, absent cache fields, missing URI each reject before typed content |
| promptPagesPreserveArgumentsAndRawMetadata | PASS expected: raw argument definitions/title/meta and exact empty cursor |
| promptGetEncodesArgumentsAndPreservesMixedContent | PASS expected: exact name/arguments incl newline, omitted empty arguments; text/image/audio/link/embedded bytes, order, role, raw and empty message result |
| malformedPromptAndTemplateResultsDoNotReachConsumer | PASS expected: invalid role and missing URI template reject |
| completionEncodesBothReferencesAndOptionalContext | PASS expected: prompt and resource reference, prior arguments, omission, nil vs false, raw |
| completionAccepts100ValuesAndRejects101 | PASS expected: exact frozen maxItems boundary, no truncation |
| discoveryAndToolResultsKeepPublicRawViews | PASS expected: server identity/extensions, typed error result and structured payload without losing raw |
| publicViewsHandlersAndTypedErrorsNeedNoTestableImport | PASS expected: public Sendable witnesses, typed handler configuration, filter, error codes, direct non-validating raw unknown view |

These extend baseline internal view tests to actual public SDK calls.
Never introduce a new requirement that resource response URIs all equal
the request URI: the frozen Resources page explicitly permits multiple
contents. Empty successful contents are not proof of a nonexistent resource.
Completion debounce/cache is a host policy, not a speculative SDK addition.

### Tasks extension

Baseline actual witnesses in TasksClientCases: toolCallsBecomeTasksAndCompleteThroughPolling,
inputRequestsAreAnsweredOncePerKeyThroughUpdate, failedAndCancelledTasksSurfaceAsErrors,
followReceivesStatusNotificationsUntilEveryTaskIsTerminal, requestsRequireTheExtensionDeclaration.

| Test function | Acceptance and predicted baseline |
| --- | --- |
| tasksConsumerInlineAndDeferredOutcomesPreserveResult | PASS expected: inline vs task discriminator, raw state/result, working to completed polling, no extra exchange |
| tasksConsumerExplicitCancelAndTypedServerFailure | PASS expected: explicit cancel on wire, failed terminal result mapped to code/message/data |
| tasksConsumerAllRequestEntrypointsRequireDeclarationBeforeWire | PASS expected: call/get/update/cancel/follow reject missing declaration with no request |
| tasksConsumerGetCannotReturnDifferentTaskIdentity | RED predicted: reject mismatched taskId as ClientError.invalidResponse |
| tasksConsumerFollowAgreedSubsetCompletesWithoutPolling | PASS expected: only agreed task reaches terminal; no tasks/get or tasks/cancel |
| tasksConsumerFollowDoesNotExposeUnacknowledgedTask | RED predicted: valid stream ID but unagreed taskId must not reach callback or final map. Ignore or reject invalidResponse before exposure; choose/document exact policy before fix |
| tasksConsumerFollowCannotReturnSuccessWithMissingAgreedFinal | RED predicted: graceful listen completion with missing agreed terminal state is invalidResponse, not successful partial result |

Source evidence: TasksClient.get constructs TaskSnapshot directly without
matching the requested taskId. TasksClient.follow invokes onUpdate before
FollowState.record; record stores any terminal task and finals is returned
without filtering or checking completeness after a normal stream close.
The public method explicitly promises all agreed terminal states and excludes
unknown/foreign IDs. These are testable API invariants, not proven defects
until native evidence arrives. Extension-level membership belongs to
MCPTasksClient; do not modify general Core SubscriptionAdmission or transports.
Additional source audit candidates, not yet native-test decisions:
ACK containing an unrequested task ID, invalid task status/result combinations,
malformed task state/error/inputRequests, repeated terminal events, and identity
of polling updates. Existing input-key-once witness remains required.
Local wait/follow cancellation vs remote tasks/cancel is documented and
coordinated with A2.2b/c; durable persistence/approval remains host-owned.

### Skills extension

Baseline actual witnesses in SkillsClientCases: listsWithoutFetchingThenLoadsAndVerifiesFilesOnDemand,
tamperedSkillFilesAreRejectedBeforeUse, frontmatterComparisonIsFieldByField.

| Test function | Acceptance and predicted baseline |
| --- | --- |
| skillsConsumerDirectLookupLoadsOnlyExplicitlyRequestedFiles | PASS expected: discover then get by URI without list, preserve entry, fetch SKILL.md then explicitly requested binary, no read for unlisted URI |
| skillsConsumerPagesRetainRawCacheHintsAndOpaqueCursorWithoutPrefetch | PASS expected: cache hints and raw entries preserved, exact empty cursor, no content fetch |
| skillsConsumerRejectsContentForDifferentURI | PASS expected: no matching contents for manifest URI throws typed missingContent |
| skillsConsumerGetCannotSubstituteAnotherSkillURI | RED predicted: requested URI cannot silently become another skill; invalidResponse |
| skillsConsumerListAndGetRejectMissingRequiredCacheFields | RED predicted: frozen overview requires ttlMs/cacheScope; both methods reject absent fields |
| skillsConsumerRejectsNonStringContinuationInsteadOfSilentlyEnding | RED predicted: malformed cursor cannot look like a valid terminal page; invalidResponse |
| skillsConsumerFixedManifestProfileDeclinesDynamicWithoutFetching | PASS expected: existing fixed-manifest profile declines dynamic, which the frozen overview permits; no speculative new support |

Source evidence: SkillsClient.get accepts any SkillEntry returned in skill;
list/get use Client.request and check selected member shapes, not the
required cache fields; list converts wrong-type cursor to nil. The retained
Skills overview requires complete/ttlMs/cacheScope and cursor forwarding,
and binds skill identity to originating server and URI. The proposed typed
rejection is an SDK consumer policy. For tests other than explicit discovery,
the scripted peer is assumed to be an already-known supported server;
the SDK is not required to add stateful discovery or cache policy here.
Additional validation follow-up: invalid cacheScope/negative or unrepresentable
TTL and extension resultType, duplicate/missing manifest paths, digest grammar,
identity comparisons on byte-distinct Unicode. Audit existing notListed,
missingContent, sizeMismatch, digestMismatch, unsupportedDigest,
invalidFrontmatter and frontmatterMismatch behavior. Fixed manifest integrity
does not establish content trust or execution permission. Dynamic skill support
and directoryRead convenience API are not required by this batch.

## Freeze decisions and ownership boundaries

1. CS3 principles say every typed view retains raw, and A1 explicitly
   mentions raw for ResourceContents. Actual public enum ResourceContents
   has only typed text/blob cases and bytes/uri/mimeType. readResource
   returns an array, not the result envelope. The raw cache fields and per-item
   _meta cannot be recovered through that typed call. Other parent views
   (PromptResult, ToolResult) retain their full raw envelope, even when nested
   Content/PromptMessage does not. Explicitly resolve the A1/documentation
   divergence in #30; do not invent a new public representation or silently
   assert that all raw fields are preserved. Generic request is a separate,
   less-validated raw path, not equivalent to typed read.
2. CS3 says no public tuples; A6 RejectedTool implements the specific
   promised replacement. Remaining public tuples observed in
   OutgoingRequest.parameterHeaders, ToolHeaders.headers(for:),
   TasksClient.declaration and TaskSnapshot.error. Record exception or
   separately approved ADR before freeze; no test-only API redesign.
3. Content.unknown exists and raw ToolResult initialization supports it.
   The frozen standard ContentBlock schema enumerates the five known types.
   Preserve the distinction between direct raw view and validated wire
   calls; decide any documentation mismatch at #30 without weakening schema.
4. SkillsClient currently requires skill:// in SkillEntry while the retained
   overview says servers SHOULD use that scheme but MAY use another. This
   is a fixed-profile interoperability limitation to decide explicitly
   before freeze; not a mandate to add dynamic skills or directory APIs.
   Origin binding, retained-manifest authorization and byte-exact URI equality
   need coordination with A2.2d/host policy.
5. A2.2c owns host handler runtime/round execution; A2.2b owns physical
   stream cancellation and receiver lifetime. A2.2d owns catalog/schema
   retention and cross-context identity. Keep production changes, if
   supported by native RED, in the owning wrapper or agreed localized
   function. No shared Client.swift changes without coordination.
6. API-freeze application consumer feasibility (MF1/MF2/MF3): typed values,
   raw schemas/results, host sampling and typed errors are inputs to #30;
   no FoundationModels import/product, new adapters, OAuth or API freeze
   decision here.

## Next native gate and acceptance

27 new functions: 13 Core, 7 Tasks, 7 Skills. Static expectation 21 PASS
and 6 RED functions, not actual test results. Some functions contain
multiple scenarios; never count those as independent function receipts.
First three focused Debug legs on exact test-only commit:
   
    swift test --force-resolved-versions --jobs 2 -c debug --filter PublicConsumerContractCases
    swift test --force-resolved-versions --jobs 2 -c debug --filter PublicTasksConsumerContractCases
    swift test --force-resolved-versions --jobs 2 -c debug --filter PublicSkillsConsumerContractCases

Preserve each exit and raw log even if a prior leg fails. Accept only
specific named assertions after successful native compilation and valid
fixture/control receipts; a timeout, unexpected fixture failure, compile
error or unknown error is not a proved RED. If existing behavior passes,
document evidence, do not manufacture RED. Review exact failing assertion
and contract before smallest authorized production correction. All original
baseline tests remain unchanged. Additional follow-up test slices may be
needed for the source-review candidates and freeze decisions above.

After corrected candidate: same tests Debug/Release, complete Scripts/test.sh
on macOS/Linux and matching optimized fixtures, existing full HTTP
interoperability against immutable compatible graph, then sequential
integration against newest main (other A2.2 branches may have advanced).
Expected full population 395 functions only if exactly these 27 tests and
no concurrent additions are admitted. Record actual inventory; no double
counting or extrapolation. CI is canonical release evidence (ADR-0001).
No PR until required local full run, no merge, tag, or final RC1 GO.

Authoring: remote blobs verified; 74 static raw JSON literal occurrences
parse after substituting numeric request-ID placeholder where present;
dynamic interpolation/fragments excluded from that check. Two known skill
byte/digest vectors independently recomputed (53 UTF-8 bytes; 4 binary
bytes). Native SwiftPM typecheck and tests not yet executed. Launcher
performs exact source syntax checks before native testing. No new
dependency or test transport in shipping products.
