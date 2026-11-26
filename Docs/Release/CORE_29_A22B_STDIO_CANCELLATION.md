# A2.2b.1 — Stdio exchange cancellation admission and wire ownership (#29)

Status 2026-11-26: test-first candidate prepared; native RED NOT_RUN.
Exact integrated A2.2a base `c82b0266cfd97a8dcaa82cd2eaa86a530ae7b1dd`,
tree `ef1be9e60e750624549adbaf74078912a4dd9e51`; post-merge
[CI 45804200382](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45804200382)
pending at preparation. Do not overlap the native focused run with Studio CI.

## Contract and source-level hypotheses

Authority: frozen Reference/Protocol/docs/specification/2026-07-28/basic/
patterns/cancellation.mdx and subscriptions.mdx, ClientTransport.exchange,
StdioClientTransport exchange/route, CS3 and ADR-0008. A stdio caller
cancelling an in-flight request sends notifications/cancelled with the
actual request ID. A cancellation must not invent an unissued or already
terminal request. When the host receiver throws on an active nonterminal
exchange and the SDK stops waiting, this audit adopts a fail-closed local
ownership policy: send exactly one correlated cancellation before admitting
the caller's subsequent exchange; preserve the original callback error.
A terminal response has already ended the request, even if the host's
terminal callback throws. No cancellation should be sent for that response.

At this exact source:
- `exchange` installs a cancellation handler but no cancellation check
  under the route-admission mutex. An already-cancelled task can run the
  handler before the route exists, then admit a request; a second race
  exists if cancellation occurs around admission. This is a hypothesis
  until native reproduction. The deterministic pre-cancel test exercises
  public ClientTransport directly, not Client's pre-request check.
- `route` invokes the receiver and on callback failure removes the route
  and resumes its continuation with that error, without sending cancellation.
  On a nonterminal frame the peer may still own a live request. No claim
  of a reproduced server-resource leak yet.
- Existing stdout EOF, run ownership, and typed termination protections
  from #53 remain unchanged.

## New black-box tests

Five functions in Tests/MCPClientStdioLifecycleTests/
StdioExchangeCancellationTests.swift. Real /bin/sh child, no private
transport state; synthetic newline-delimited frames, public exchange
API, complete received lines echoed to stderr. READY and ACK are explicit
rendezvous; the timeout only bounds missing evidence. One pending-request
slot, distinct recovery ID 72, expected exact request ID 71. The child
returns CLEAN after stdin EOF; run is joined before inspecting the wire.
The child accepts pre-cancelled requests and sends a terminal response
if the buggy implementation admits them, avoiding a hang-dependent RED.

| Function | Predicted baseline | Acceptance |
| --- | --- | --- |
| terminalResponseDoesNotSendCancellation | PASS | request + recovery, no cancellation |
| terminalCallbackFailureDoesNotCancelCompletedRequest | PASS | exact callback error, no cancellation, recovery |
| callerCancellationAfterACKSendsExactlyOneCancellationAndRecovers | PASS | CancellationError, exactly one cancel 71, recovery |
| nonterminalCallbackFailureCancelsActiveRequestAndRecovers | RED | exact callback error and cancel 71 before recovery |
| alreadyCancelledExchangeNeverAdmitsRequest | RED | CancellationError, no request or cancellation before recovery |

These are static predictions, not native test results. An unexpected
control failure, compile error, timeout or wrong error is not accepted
as the predicted RED. Parse and inspect actual raw receipts.

Local authoring: Swift 6.2.1 x86_64 Linux parse-only exit zero on the
exact test blob `d62c3900eb7fce15ff8ec0f2346dd469b825c328`; three real
local shell framing controls (terminal, pre-cancel and listen/cancel)
confirm expected RX/READY/CLEAN and correlated reply frames. Not SwiftPM
typechecking, native Swift 6.4.2 execution or end-to-end transport proof.

Native focused command (clean detached exact test-only revision):
    
    swift test --force-resolved-versions --jobs 2 --filter StdioExchangeCancellationCases

Preserve actual test exit, all five test outcomes, toolchain, six input
hashes, clean checkout and stderr/stdout assertion receipts. Implement
a minimal fix only after observed RED. Keep the test bodies unchanged.
No production edit, public API, new dependency, deadline or existing
test modifications in this batch.

## Subsequent A2.2b gates

1. A2.2b.1: cancellation/route admission and active callback failure.
2. A2.2b.2: receiver ownership while suspended, cancellation and joining,
   reentrant RPC from callbacks (stdout reader must not deadlock), stale
   route identity across cancellation/reuse. Require deterministic tests.
3. A2.2b.3: server cancellation, graceful terminal and abrupt EOF,
   per-stream ID/notification routing and late responses.
4. A2.2b.4: bounded outbound/inbound queues, backpressure and restart.
   The source uses an unbounded AsyncStream for outgoing lines; a pending
   route limit alone is not proof of a cumulative queue bound.
5. A2.2b.5: verify counterpart HTTP SSE cancellation/cleanup on exact
   isolated B3 graph, native controls and full Core Debug/Release matrix.

No claim that this synthetic child proves actual server provider teardown,
callback join, all races, HTTP ownership or MRTR. A2.2c/d remain separate.

## Platform qualification

Daily qualification remains self-hosted macOS/Linux ARM64. User reports
GitHub hosted runners available again. Add an explicit hosted Ubuntu AMD64
lane on an exact integrated candidate, pinned Swift 6.4.2 multiarch digest;
require actual uname x86_64, target and checkout SHA, matching Debug and
Release fixtures, full locked suite and unchanged six dependency bytes.
Do not toggle USE_SELF_HOSTED_LINUX globally during current CI or treat
an ARM64 result as AMD64. Prefer a separately reviewed opt-in lane and
record hosted quota/cost. This is an independent platform/RC gate;
no hosted job dispatched or workflow modified here. No release tag or
final release decision.


## Native RED return and independent diagnostic follow-up

Original [native RED receipt](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7195911421):
`core-a22b1-red-y1Na4fVt.tar.gz`, 4946 bytes, SHA-256
`367e8eafc1d9477e6d2fc5550d7d5c031aadce5be68874cf8784e478c0e2b35b`.
Test-only commit `792de228b067ac58b3f55c60fb88d48899147004`, exact tree,
clean final status, all six dependency hashes unchanged, native Apple
Swift 6.4.2/macOS 27.3, build successful (90.66 s). Three positive controls
PASS. Nonterminal callback failure precisely reproduced missing
notifications/cancelled (two assertions, actual methods
[subscriptions/listen, probe/recover], no cancellation ID, 0.005 s).
Pre-cancel case hit suite time limit and returned serverExited instead
of CancellationError at teardown (two issues, 60.528 s), without a
complete peer-wire receipt. Under the acceptance contract above this
is **partial RED, one confirmed and one inconclusive**, not two accepted
REDs. Preserve original test file and archive.

The new independent `StdioPrecancelDiagnosticCases` suite is at blob
`f296984a2b1df83cb2a23dea443800e7538bbef9`. Parent explicitly parks
a task, cancels it before releasing the gate, and records Task.isCancelled
immediately before the actual public transport exchange. A finite shell
peer emits READY, RX, ADMITTED and CLEAN markers to the captured test log
as they arrive. If an erroneous request reaches the peer, it replies
and exits instead of waiting for an unbounded subsequent operation.
A separate ordinary-exchange positive control uses the same gate and
peer. An independent 5-second test-only guard shuts down stdin on
missing completion, emits a guard marker and fails the test; it is not
an accepted admission RED by itself. All owned tasks are joined on
ordinary completion/error paths. Preserve typed cancellation outcome,
callback count, exact wire inventory and same-transport recovery on the
correct cancelled path. No changed SDK timeout.

Local authoring evidence: Swift 6.2.1 Linux parse-only succeeds for the
exact new source blob; isolated signal/gate definitions compile in
Swift language mode 6 and pass 50 cancellation-flag observations
(25 normal and 25 externally cancelled). Both actual /bin/sh peer
framing controls (probe and recovery) pass, including IDs and markers.
These are not full SDK typechecking, Swift 6.4.2 native transport
execution or proof of a route-admission defect.

Run only the new focused suite against the unchanged production
baseline, plus a separate recheck of the confirmed nonterminal callback
regression. Record exact exit codes and raw logs for both legs. A valid
pre-cancel admission RED requires observed cancelled-at-entry plus
actual peer ADMITTED/RX evidence, positive control and clean receipt.
If only the guard fires or a control fails, investigate instead of
claiming admission proven. Original five tests remain untouched.
No production changes yet. After accepted reproduction, implement the
minimal cancellation/route-admission correction, rerun all seven
functions in Debug/Release and full Core suite. No release decision.


## RED2 accepted; scoped GREEN implementation prepared

[Native RED2 receipt](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7196247273):
`core-a22b1-red2-dwY7BO9Q.tar.gz`, 5,392 bytes, SHA-256
`c801a99dd6b5e9a669d6a18df0a9170e444345128e6c17265e1612de0ea5f472`.
Actual archive reopened and both logs inspected. Exact test-only commit
`a7738088965943f805389a5adf10245f9165b955`, tree
`81bc973949007c62769e91fbde502c0aaa60476e`, actual test blob receipts
match remote. Native build successful (71.09 s and 1.18 s incremental);
both test exits 1, both tee exits 0. All six dependency hashes unchanged,
clean final status. Three-workspace 13-pin receipt is static only.

Ordinary finite-peer control PASS (0.004 s). Precancel RED (0.002 s,
four assertions): cancelled-at-entry true, real child RX request 71,
ADMITTED, CLEAN, outcome serverExited, guard=false, recovery=false.
No callback delivered on this run. Nonterminal callback failure again
RED (0.005 s, two assertions): listen followed by recovery, no cancel
frame and no cancellation ID. The two defects are now independently
reproduced without timeout evidence.

Production commit `35b9186e19855ec1b9a27045db7d8fe0f222aaba` changes only
`Sources/MCPClientStdio/StdioClientTransport.swift`, blob
`f387f498bac78d0ca67e727ed63ec901d96eb810`. Both native RED test files
remain byte-identical.

- Check cancellation before request preparation and again under the
  route-admission mutex. A cancellation handler that ran before route
  registration cannot be followed by unnoticed admission.
- Prepare the correlated cancellation line before admission (an encoding
  failure is returned before the request is issued). Every admitted route
  owns a distinct internal UUID, its cancellation bytes and a terminal
  receipt flag. No new public API.
- Retire only the matching route identity. Enqueue cancel for a still
  active request on the existing outgoing stream under the same mutex,
  before releasing the slot and resuming the caller. Preserve the typed
  callback error. The channel may already be closed; enqueue is not
  proof of physical delivery in that case.
- Mark terminal receipt before delivering its callback. No cancellation
  frame for a terminal response even when the callback throws.
- Continuations are resumed outside the lock; no extra tasks, deadlines,
  dependency or protocol-reference changes.

This prevents double retirement of the same local route, not arbitrary
late-wire-ID aliasing, full callback join, reentrant request progress,
remote cancellation or cumulative queue bounds. Those remain explicit
A2.2b.2–5 gates. A sender's cancellation is not proof that provider
resources have been released.

Authoring check: isolated Swift 6.2.1 Linux harness compiled in Swift
language mode 6 with the changed Route, State, exchange/route/retire
logic and stub codec, request and outgoing stream. Six controls pass:
pre-cancel without output, active and terminal callback errors with
recovery, active cancellation, cancellation during terminal callback,
and pre-cancelled same-ID caller leaving an active route intact. This
does not exercise real Swift-JSON, SwiftSubprocess, native stdio or
full SDK compilation. No native GREEN result claimed yet.

Next: exact-candidate native GREEN, 7/7 focused functions in Debug,
7/7 in optimized Release, then 368/368 full locked Debug functions
with real fixtures. Keep original RED receipts and both test blobs.
No PR or merge until native GREEN and subsequent qualification.
Final release gate NOT_EVALUATED.
