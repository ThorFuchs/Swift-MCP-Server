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
