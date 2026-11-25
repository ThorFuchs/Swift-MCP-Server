# A2.2 — Client exchange and lifecycle contracts (#29)

Status (2026-11-25): test-first A2.2a prepared; native execution NOT_RUN.
Base: `02115c26feba8a85d53631344bd501f36b1a8700` (N4.5 exact
post-merge [CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45693638165)
344/344 per native ARM64 platform).

## A2.2a: subscription admission and correlation

Authority: frozen `Reference/Protocol/docs/specification/2026-07-28/basic/patterns/subscriptions.mdx`,
`cancellation.mdx`, corresponding schema and examples; `Client.listen` and
`ListenEvent.acknowledged` documentation, `ClientTransport.exchange` contract.
The server MUST acknowledge each stream before events for that subscription,
MUST NOT emit unrequested types, and carries the initiating JSON-RPC ID in
subscription metadata. Acknowledged filters may be a subset. Stdio MUST
demultiplex by subscription ID; don't mistake a test of an already routed
exchange for proof of physical stdio routing. Enforce local fail-closed
admission of invalid known core subscription sequences as an SDK policy
(`ClientError.invalidResponse`), not a newly asserted protocol MUST that every
client throw this exact error. Unknown extension filters and events have
separate contracts; do not apply closed-world assumptions to them.

Source review: `Client.perform` correlates JSON-RPC response IDs and validates
frozen result/notification definitions but `dispatch` is stateless with
respect to ACK/order/filter/subscription ID. Schema membership alone
does not enforce cross-message equality or ordering. The nine new
black-box functions use public APIs and a finite synchronous-delivery
script (async receive is awaited), actual request ID, synthetic frames,
observable callback and delivery counts, no sleeps or private state.

| Test function | Contract | Static expectation only |
| --- | --- | --- |
| acknowledgedSubsetReceivesOnlyAgreedEventsAndCloses | Supported subset, ACK first, valid tools event, graceful terminal metadata | control |
| callbackFailureTerminatesExchangeWithoutLaterDelivery | Exact host error and no additional callbacks on compliant scripted transport | control |
| eventBeforeAcknowledgementDoesNotReachHost | Pre-ACK core event rejected before delivery | likely RED |
| foreignAcknowledgementDoesNotReachHost | Foreign subscription ID never acknowledged | likely RED |
| duplicateAcknowledgementDoesNotReachHost | Second ACK rejected | likely RED |
| acknowledgementCannotExpandRequestedFilter | Server cannot grant unrequested prompt events | likely RED |
| foreignEventDoesNotReachHost | Wrong subscription ID rejected | likely RED |
| requestedButUnacknowledgedEventDoesNotReachHost | Omitted/unsupported prompt event rejected even if originally requested | likely RED |
| foreignTerminalSubscriptionMetadataIsRejected | Matching response id is insufficient if terminal subscription ID differs | likely RED |

The original A2.1 scripted callback/relist control contains literal string
subscription IDs (`"listen-1"`) rather than its actual numeric outgoing ID.
Preserve that historical test evidence. If correlation enforcement is
implemented, correct only that fixture's ID correlation using its actual
request ID, with separate review and unchanged assertions/intent. Do not
interpret an old fixture mismatch as a production regression or weaken
assertions to get green.

Authoring checks: exact new test file Git blob
`0958149436c367f89acddac099aee221897cb5f0` matches local file parsed by
Swift 6.2.1 x86_64 Linux (`swiftc -frontend -parse`, exit 0);
six representative same/foreign ID JSON template renderings parse.
This is syntax/fixture sanity only, not SwiftPM typechecking, Swift 6.4.2
compilation or test execution. No production change, no altered existing
tests, pins, deadlines or API. Native test-only branch; do not merge RED.

## Follow-up slices (proposed order, not passed)

- A2.2b: actual transport ownership: server cancellation versus graceful
  completion and unexpected EOF; route removal/cancellation/join on callback
  errors, late response and restart, bounded listen/backpressure. Distinguish
  stdio cancellation notification from HTTP SSE close. Audit `StdioClientTransport.route`
  and cancellation admission/receive ownership; source findings require
  deterministic wire or native evidence, not speculative fixes.
- A2.2c: MRTR per-round correlation/opaque requestState, exact input keys,
  maximumInputRounds, typed unsupported input, handler errors and cooperative
  cancellation with bounded rendezvous; no automatic reexecution after failure.
  Test multi-input callbacks and invalid or unexpected input/terminal frames;
  existing schema/output checks remain mandatory.
- A2.2d: extension and retention contracts, resource URI/filter identity,
  client-local catalog/schema bounds and explicit authorization-context
  lifetime. Separate unsupported extension semantics from malformed known
  core frames. No universal interpretation of arbitrary extension filters.
- A2.3: public consumer coverage for resources, prompts, completion,
  representative Tasks/Skills; API review against CS3. Provide application
  integration feasibility inputs for #30 (MF1/MF2/MF3): transport-neutral
  call/list, original schema and result semantics, context-aware registration,
  host sampling and ownership/error/cancellation. Do not add FoundationModels
  or Apple frameworks to Core or require optional adapters to ship before RC1.

## Next native gate

From a clean detached checkout of the exact test-only SHA, Swift 6.4.2,
with locked dependencies:

    swift test --force-resolved-versions --filter ClientListenInvariantCases

Record all nine function names, exact assertion/error receipts, provenance,
exit and unchanged dependency bytes; first establish actual RED and controls.
Then implement the smallest accepted production fix, prove identical
regressions GREEN and review the A2.1 fixture identity correction separately.
Before integration: full Scripts/test.sh with locked graph on macOS/Linux,
optimized tests with matching fixtures and external HTTP qualification; new
native stdio/HTTP coverage when lifecycle/transport behavior changes.
No PR merge, release or #29 closure authorized by this test-first batch.
