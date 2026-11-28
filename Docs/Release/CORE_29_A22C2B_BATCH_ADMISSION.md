# A2.2c.2b — atomic input-batch admission (#29)

Status 2026-11-28: test-only preparation. Native RED/control run NOT_RUN.

## Immutable baseline

[Accepted A2.2c.2a native GREEN](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7241688419):
commit `5d763f593bced0b2f327d9c00b366f1e7543bf49`, tree `60bb1d1cf880e5b444ae7bf7896b94e7465a3573`.
Original archive core-a22c2a-green-MGq0qsPA.tar.gz, SHA-256
`d86dfd2246b2826e66855bc730be619bb638399201e3a87d2eecae4f060aa37c`.
Reopened for this sprint: archive hash, three source blobs, six archived
dependency hashes, raw stage totals 24/24/416, and 126 envelope case
markers rechecked. Client.swift `ebbb68aa07f140665448ef573f62e778610d639f`,
MRTR tests `1b62d295e3065090dc8eed79092f46ab757599ca`, envelope tests
`58fb0e6706dc51c700304c935acb9da8b8c2720b` remain unchanged.

## Authority and local policy

Use frozen [MRTR](../../Reference/Protocol/docs/specification/2026-07-28/basic/patterns/mrtr.mdx),
[elicitation](../../Reference/Protocol/docs/specification/2026-07-28/client/elicitation.mdx),
[sampling](../../Reference/Protocol/docs/specification/2026-07-28/client/sampling.mdx),
[roots](../../Reference/Protocol/docs/specification/2026-07-28/client/roots.mdx),
[schema](../../Reference/Protocol/schema/2026-07-28/schema.json)
(blob `213c58f6d9a1c2ce6ad055afe90bbdb095a29ee8`), CS3 A11/C,
and the public answerInputRequests entry used by TasksClient.wait.
The frozen ordinary InputRequests union includes ElicitRequest,
CreateMessageRequest and ListRootsRequest; do not expand it to raw
extension methods. The direct extension-owned entry supports registered
raw handlers and validates result objects. Generic Request has string
method and optional object params. For direct input maps, adopt local
defensive shape admission (entry object, string method, absent/object
params), including registered extensions. Absent params retain existing
empty-object behavior; explicit null/scalar/array params are invalid
under this policy. Preserve arbitrary members and nested values within
valid extension params/results; do not invent an extension-specific
schema or require additional extension capability declarations.

Full-batch admission before any input handler runs is a deliberate SDK
policy to prevent avoidable host side effects, not a universal wire
requirement on other clients. It is not transactional execution: a later
host error or invalid *result* can stop the batch, but cannot undo
earlier host work. Exact local invalidResponse for malformed inputs;
unsupportedInput(method:) for a well-shaped unavailable handler or
unadvertised supported-mode/feature request. No extra JSON-RPC exchange
or partial response map on rejection. Existing validation and typed
error behavior are retained. Progress/log callbacks outside the input
batch are not part of this guarantee.

## Source audit

Client.perform validates the full ordinary InputRequiredResult before
answer, but Client.answer currently iterates each entry, checks its
handler and capability, executes it, validates the response, appends it,
then moves to the next. The direct answerInputRequests path opts into
per-known-entry frozen request validation. Consequently a structurally
valid first entry may trigger a host callback before a subsequent
unavailable handler, disabled elicitation mode, unadvertised sampling
tools/toolChoice, or malformed direct request is found. A direct entry
without a string method currently falls back to an empty string;
registered raw extension params are not required to be objects at this
boundary. These are source hypotheses, not runtime observations.

Proposed architecture after RED: separate preparation/admission of all
entries (including typed request projection, handler availability and
capability checks) from sequential execution. Keep preparation local
to the batch and caller, preserve key identity/raw payloads, avoid
duplicated validation where the ordinary wire map already provides it.
Do not allocate unbounded tasks, change public API, touch the transport,
introduce provider logic, or broaden schema semantics. Detailed
cancellation before/between/after handlers is A2.2c.2c, sampling content
semantics 2d, key identity and retry/round budgets 2e. Validate form
response content after execution as before; whether additional
requestedSchema compilation preflight is needed is a separate witness,
not established here. User consent/URL handling and real root access
remain host responsibilities.

## Focused test-first batch

Test source [ClientBatchAdmissionTests.swift](../../Tests/MCPClientTests/ClientBatchAdmissionTests.swift),
commit `31d83a918012026045599c733d4bf56fb41ef4ff`, blob `21c24c210175e79eebebd92bbd9ccff6c67482b5`.
17 functions, eight predicted controls PASS, nine predicted RED;
these are static predictions. The 11 rejection functions exercise
27 labelled invalid-input combinations, each with good-first and
bad-first placement (54 case receipts). The pinned Swift-JSON 1.9.0
JSONObject is an ordered collection, with insertion-ordered members
and order-independent equality; the fixture explicitly verifies
decoded key order before exercising the API. Order is a witness
mechanism, not a new wire-map semantic requirement. Script records actual
outgoing requests, renders each response with actual request ID, offers
one valid continuation to expose erroneous retries, and throws on
exhaustion. Direct path expects zero exchanges.

| Test function | Contract | Prediction |
| --- | --- | --- |
| validWireBatchAnswersAllKeysExactlyOnce | valid roots/form/sampling, original keys, state, distinct IDs | PASS |
| validDirectBatchPreservesRawExtensionParamsAndKeys | mixed typed/raw, absent params -> empty object, raw result and keys | PASS |
| emptyDirectBatchReturnsEmptyObjectWithoutHost | no work or transport | PASS |
| malformedWireBatchIsRejectedBeforeAnyHandler | whole-map schema rejects three known malformed requests, both placements | PASS |
| wireInputUnionDoesNotAdmitRegisteredRawExtension | registered extension remains direct-only | PASS |
| unavailableWireHandlerPreventsAllCallbacks | no sampling/roots handler, both placements | RED |
| unadvertisedWireElicitationModePreventsAllCallbacks | URL/form disabled, both placements | RED |
| unadvertisedWireSamplingFeaturePreventsAllCallbacks | tools/toolChoice, both placements | RED |
| malformedDirectKnownRequestPreventsAllCallbacks | known schemas before earlier extension callback, both placements | RED |
| unregisteredDirectExtensionPreventsAllCallbacks | missing extension handler, both placements | RED |
| malformedDirectEntryCannotBeTreatedAsUnsupportedMethod | null/array/missing or numeric method, both placements | RED |
| malformedDirectExtensionParamsPreventsAllCallbacks | null/array/number/string params, both placements | RED |
| unavailableDirectHandlerOrModePreventsAllCallbacks | missing sampling/roots, disabled URL, both placements | RED |
| unadvertisedDirectSamplingFeaturePreventsAllCallbacks | tools/toolChoice, both placements | RED |
| hostFailureStopsExecutionWithoutPretendingToRollbackEarlierWork | exact host error, no later handler/response, both paths | PASS |
| invalidHandlerResultStopsExecutionWithoutPartialResponse | invalid sampling result, earlier effect retained, both paths | PASS |
| failedBatchDoesNotPoisonNextIndependentCall | recovery uses fresh logical call/state, no stale response | PASS |

For each of 54 A22C2B_CASE receipts require unique label/path/order and
record actual matched error category, exchange count, host trace.
GREEN expectation: matched=true, exchanges=1 wire / 0 direct, host=[].
Valid-first cases must demonstrate actual prior callback(s) or wrong
admission to accept RED; wrong error category is a separate concrete
failure. A timeout, compile failure, fixture exhaustion or failed
positive control is not accepted RED. Preserve all existing tests.
No timing-based ordering, network, process, model or UI in these tests.

Authoring: exact local test bytes parsed by Swift 6.2.1 Linux x86_64;
language-mode-6 typecheck with public API stubs (including Testing macros
and concurrency checks) passed. Remote test blob equals locally parsed
file. Neither check is actual SDK compilation or native evidence.

## Native gate

On reserved Studio, native Swift 6.4.2/macOS 27 ARM64 and exact clean
detached checkout, locked graph:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter ClientBatchAdmissionCases

Preserve actual commit/tree and source blobs, archived dependency bytes,
before/after six hash receipts and static pin inventory, raw test log,
named starts/terminal outcomes, all 54 case receipts and command/tee
exits. Review against the static predictions before any production
change; do not count subcases as separate test functions. Native
full regression after a fix expected 433 test functions (416+17);
focused Debug+Release+full Debug would be 467 cumulative executions.
No native run performed here. A2.2c.2c–e, integrated real transport and
cross-platform qualification remain open. No production, transport,
API, dependency, frozen Reference or CI changes; no PR, merge, tag
or release authorization. Coordinate Studio and Client.swift ownership
with parallel A2.2b, A2.2d and A2.3. release_gate NOT_EVALUATED.
