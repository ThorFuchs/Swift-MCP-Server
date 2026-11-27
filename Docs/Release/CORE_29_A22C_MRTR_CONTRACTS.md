# A2.2c — MRTR and host-handler contract audit (#29)

Status 2026-11-27: source audit and first transport-neutral test batch
prepared; native RED/PASS NOT_RUN. Separate from A2.2b and A2.2d/A2.3.

Immutable integrated base `415f62594e87a573ebea1f2bb701d5c24ad92cc1`, tree
`c6b300777f6ba9d4d26c3d88df861a7b56f65c91`. Branch
`test/core29-a22c-mrtr-contracts`. No transport, production, manifest,
dependency or frozen reference changes. No Apple frameworks or provider
implementation; no API freeze, merge or release decision.

## Authority and audit boundaries

Use the repository's frozen 2026-07-28 revision, not the moving upstream
main. Authority: [MRTR](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/mrtr.mdx),
[elicitation](../../Reference/Protocol/docs/specification/2026-07-28/client/elicitation.mdx),
[sampling](../../Reference/Protocol/docs/specification/2026-07-28/client/sampling.mdx),
[roots](../../Reference/Protocol/docs/specification/2026-07-28/client/roots.mdx),
[cancellation](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/cancellation.mdx),
[frozen schema](../../Reference/Protocol/schema/2026-07-28/schema.json),
[CS3 A11/C](../Plans/CS3-CLIENT-API-REVIEW.md), [client contract](../CLIENT.md).
Frozen schema blob `213c58f6d9a1c2ce6ad055afe90bbdb095a29ee8`;
MRTR blob `a66d667094e73a65a202ed512bd4d398676c9287`.
Elicitation `13dbbb5a050934801563011c0a780fae6e36f55b`;
sampling `2b1ed914ba8f8ccdc0ce093014954bd9e4ff562f`;
roots `0f22031afd184da466f468ea859d9ff377952727`.

Source reviewed at base: Client.swift blob
`7953099ee15fcf9999af33894a1359498fd59e75`, especially lines 225–359
(perform, request, answerInputRequests, answer); ClientConfiguration.swift
`ae4569cfa74bd37feae80c76e1525f1c80521c5c` (capabilities, bounds);
ClientTypes.swift (typed inputs and outputs); ClientError.swift
`85684f3f20bf78220c7b9484f200801deeb5c89d`; ClientTransport.swift
`9ca9412836b87eb599c64336da040a5c3bf22345`; WireValidator and the
TasksClient.wait caller of answerInputRequests. No inspection of private
state in tests. Source and schema observations are not runtime results.

Distinguish normative wire rules from SDK fail-closed acceptance. When
a server violates a known protocol rule, we adopt local rejection before
host side effects where possible, ordinarily ClientError.invalidResponse,
or the existing unsupportedInput for unsupported handlers/capabilities.
The exact local error category is a test contract, not a protocol-wide
requirement on other clients. Preserve typed host/server errors.
A callback already in progress is host-owned cooperative work: no
promise of forced termination or transport teardown in this audit.
Sampling model execution, token counting, human approval, browser URL
opening, root accessibility and filesystem authorization are host
responsibilities; do not claim they are enforced by the wire SDK.

## Contract inventory and source findings

| ID | Contract and source observation | Evidence to obtain |
| --- | --- | --- |
| C01 | Each input round uses original method/params, new request ID and metadata; perform uses fresh identifier, original params plus local continuation. | Four exchanges, unique IDs and progress tokens, exact original tool params, capabilities, info. |
| C02 | requestState is opaque and present only when supplied in immediately preceding result; continuation is reset each round. | State-only, mixed and input-only rounds, exact UTF-8 of decoded state (not necessarily identical wire escape syntax). |
| C03 | Response keys correspond to current input map; answer appends entry.key.string, not method; no carryover. | Three different typed handlers in one input map, replacement by new keys. Concurrent calls use same key but different state/results. |
| C04 | Only tools/call, resources/read and prompts/get may receive core InputRequiredResult; perform currently branches without method admission. | Positive resource/prompt state-only controls; negative tools/list with valid sampling must not invoke host or retry. Full unsupported method inventory follows. Extension rules separately scoped. |
| C05 | InputRequiredResult must contain inputRequests or requestState. Frozen definition describes rule but required array contains resultType only. | Missing both rejected without retry. Empty but present inputRequests requires separate semantic decision; do not conflate absence and emptiness. |
| C06 | Response correlation: perform matches numeric ID and rejects second response, but does not visibly verify jsonrpc version before selecting result. | Previous-round ID rejection control and wrong-version response with otherwise valid input. Envelope XOR/error shape, duplicate terminal and token filtering follow. |
| C07 | Frozen InputRequests union checks known request shapes as part of normal input-required validation. Direct public answerInputRequests used by TasksClient.wait goes straight to answer; typed projection may default missing fields. | Malformed mixed wire batch rejects all callbacks; direct malformed sampling/elicitation/roots each rejected before host. Direct known+unknown batches and extension error shape follow. |
| C08 | Declared capabilities reflect configured handlers; mode guard exists. Both-disabled Elicitation can emit empty declaration (legacy implies form); no sampling.tools or sampling.context configuration. | Exact unsupportedInput for absent handlers and URL mode; preserve valid implicit form and explicitly admitted URL. Both-disabled config policy separate. |
| C09 | Form accept must supply content matching requestedSchema; answer checks content only if present. URL accept must omit content; result schema is shape-only and current check does not distinguish modes. | Reject form accept nil with required field and URL accept carrying form data; valid decline/cancel and URL accept nil. Existing wrong-content/remote-schema tests remain. |
| C10 | Sampling request tools/toolChoice require declared sampling.tools, with client error explicitly required by schema descriptions. Current capability projection declares sampling:{} and answer invokes host without feature check. | Both tools (even empty present array) and toolChoice rejected without callback or retry. Do not introduce a new capability API. |
| C11 | Typed SamplingRequest preserves raw and host owns provider/model policy; CreateMessageResult checked. | Basic typed request and exact response, malformed response rejected. Follow-up raw fields, role/content mixtures, tool-result balance and deprecated context/feature boundaries. |
| C12 | Roots are deprecated in this revision but existing compatibility retained. Root.uri MUST be file://; schema uses format uri, no prefix restriction. Root projection simply serializes URI. | Valid named file root, empty roots, reject https URI before sending. Host path access/permissions remain separate. |
| C13 | Errors propagate, ordinary server failures not retried. Version error -32022 has one deliberate compatibility retry. | Exact thrown host error and typed server error after input round, exact exchange count. Version-retry interaction with input state/round budget follow-up. |
| C14 | Caller cancellation stops rounds; perform checks at each iteration and WireValidator checks around validation. Direct answer has no visible entry guard before host. | Pre-cancelled call no exchange; in-flight handler observes cancellation and no continuation; pre-cancelled direct answer no host. Batch-between-handler and cancellation-after-transport-return follow-up. |
| C15 | maximumInputRounds bounds input rounds, not initial request; constructor clamps to >=1. perform increments and checks before answer. | Exact boundary success and excess rejection before next handler, counts, constructor clamp. Audit configured limits and interaction with retries, not a new wall-clock timeout. |
| C16 | Raw extension input handlers intended for direct extension-owned inputRequests (TasksClient.wait); frozen ordinary InputRequests union contains only known Core methods. | Preserve direct raw params/result/key without any transport. Existing ordinary-wire unknown method rejection remains. No broadened union or authorization claims. |

Existing coverage: ClientCases typed round trip for elicitation/roots/sampling,
missing capability/handler, cancellation; ClientCompatibilityCases legacy
resultType and one version retry; InvalidServerOutputCases schema failures,
foreign response and malformed frames; SchemaValidationCases accepted form
content and tool output schema checks. A2.1 captures tool metadata for the
logical call, including MRTR. Preserve all these tests. A2.3 owns general
consumer coverage; A2.2d owns cache/retention/authorization-context lifetime;
A2.2b owns real transport receiver join/backpressure/cancel/EOF.

## First transport-neutral RED/control batch

Test source:
[ClientMRTRContractTests.swift](../../Tests/MCPClientTests/ClientMRTRContractTests.swift),
commit `fa042df7bc4334d83030cd82355f37c106d00643`, blob `1b62d295e3065090dc8eed79092f46ab757599ca`.
24 named Swift Testing functions (several contain explicit finite subcases).
Predicted 15 controls PASS and 9 RED, **not observed results**.
For negative controls PASS means correct rejection, not successful RPC.

| Function | Contract | Baseline prediction |
| --- | --- | --- |
| multipleRoundsReplaceOpaqueStateAndExactResponseKeys | C01–03,C08–09,C11–12 | PASS |
| resourceAndPromptSupportStateOnlyContinuation | C01–04 | PASS |
| parallelCallsKeepIdenticalInputKeysAndDifferentStateIsolated | C01–03 | PASS |
| unsupportedCoreMethodRejectsInputRequiredBeforeHost | C04 | RED |
| inputRequiredWithoutEitherFieldDoesNotRetry | C05 | RED |
| previousRoundResponseIDIsRejectedBeforeHost | C06 | PASS |
| wrongJSONRPCVersionCannotTriggerHost | C06 | RED |
| malformedWireInputBatchIsRejectedBeforeAnyHost | C07 | PASS |
| undeclaredKnownHandlersReturnExactUnsupportedInput | C08 | PASS |
| unadvertisedURLModeDoesNotReachHandler | C08 | PASS |
| acceptedFormCannotOmitRequiredContent | C09 | RED |
| acceptedURLCannotReturnFormContent | C09 | RED |
| declineCancelAndURLAcceptanceHaveNoContent | C08–09 | PASS |
| samplingToolsAndToolChoiceRequireAdvertisedCapability | C10 | RED |
| invalidSamplingResultCannotBeRetriedToServer | C11 | PASS |
| nonFileRootIsRejectedBeforeContinuation | C12 | RED |
| directAnswerValidatesMalformedKnownRequestsBeforeHost | C07 | RED |
| directExtensionHandlerPreservesRawParamsAndKey | C16 | PASS |
| handlerErrorPropagatesUnchangedWithoutRetry | C13 | PASS |
| cancellationDuringHandlerPreventsAnotherRound | C14 | PASS |
| preCancelledDirectAnswerCannotInvokeHost | C14 | RED |
| preCancelledCallDoesNotStartExchange | C14 | PASS |
| inputRoundLimitPermitsBoundaryAndRejectsNextBeforeHandler | C15 | PASS |
| ordinaryServerErrorAfterInputRoundIsNotReexecuted | C13 | PASS |

The scripted ClientTransport stores actual parsed request bodies/IDs, uses
finite reply plans keyed by request.name or method, and rejects unexpected
calls instead of repeating the last response. It does not implement or
change a production transport. Each scripted reply uses the actual ID
except the explicit previous-ID witness; no sleep selects successful
ordering. Parallel call handlers use a two-party rendezvous. Cancellation
uses explicit handler entry and an AsyncStream that returns when the
calling task is cancelled; failure cleanup cancels and joins the test task.
Ten-second test-only rendezvous limits and suite guard are diagnostic
bounds, not production timeouts. No model, filesystem, external URL,
network call, server process or credentials needed. Raw outgoing assertions
capture expected typed outcomes, exact callback count and exchange count.
A compiler error, unexpected harness exhaustion/error, guard timeout or
failed positive control is not accepted RED evidence. Preserve test
bodies and raw native receipt before any production correction.

Authoring evidence: Swift 6.2.1 Linux x86_64 syntax parse succeeds;
Swift language mode 6 typecheck with stubbed public JSON/MCP APIs succeeds
(including Testing macros and concurrency checks). This is not SDK typecheck.
16 representative generated JSON-RPC frames checked using Foundation
JSONSerialization in Swift, including exact decoded Unicode state bytes,
stale ID and intentionally wrong JSON-RPC version. This is syntax/fixture
sanity, not frozen schema or runtime conformance. Remote test blob equals
the locally checked file. Native Swift 6.4.2 and locked SDK graph NOT_RUN.

## Qualification and remaining audit work

First run on idle native Studio (or separately reserved equivalent host):
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientMRTRContractCases

Use exact test-only revision on /Volumes/Backup with clean detached
checkout. Archive actual commit/tree, new test and reviewed production
source bytes, raw test logs, actual command/tee exits, six-file dependency
snapshot/verification and static pin inventory. Review all 24 individual
functions, not just summary. Record actual PASS/RED/UNRESOLVED; fix only
reproduced contracts, retain original test bytes. Next focused Debug and
Release + full Core matrix after fixes, expected 392 full functions if
only these 24 are added to the 368-function base. Add further focused
tests for open inventory boundaries above before claiming A2.2c complete.
Final cross-platform and native real Stdio/HTTP evidence must use the
then-integrated A2.2b ownership model and newest reviewed main tree.
Do not treat transport-neutral tests as real wire cancellation proof.

Coordinate changes to Client.swift request engine and handler sections
with A2.2d (retained state) and A2.3 (consumer APIs). Do not edit shared
CI/manifests/Reference or rebase other branches. Native host access is
coordinated to avoid concurrent heavy Studio builds; separate analysis
and test authoring can proceed independently. Integrate serially,
requalify exact resulting tree; #29 remains open, final release_gate
NOT_EVALUATED. No production fix in this test-only batch.
