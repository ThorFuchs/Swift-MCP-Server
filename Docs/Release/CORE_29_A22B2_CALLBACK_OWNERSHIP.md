# A2.2b.2 — Stdio callback ownership and reentrant routing (#29)

Status 2026-11-27: test-first preparation, native RED NOT_RUN.
Integrated A2.2b.1 base `415f62594e87a573ebea1f2bb701d5c24ad92cc1`,
tree `c6b300777f6ba9d4d26c3d88df861a7b56f65c91`.
[PR #63](https://github.com/ThorFuchs/Swift-MCP-Server/pull/63) merged
after all scoped pre-merge gates. [Post-merge CI 46062633342](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/46062633342)
was queued at preparation. Do not overlap Studio native test execution
with post-merge CI or other heavy local work.

## Goal and source audit

Make an admitted exchange own its receiver's lifetime, without
serializing unrelated exchanges behind a suspended receiver. The public
ClientTransport contract already specifies in-order callbacks, backpressure
and cancellation. The following stronger local ownership acceptance is
an explicit SDK design decision for this audit, not a new wire-level
MCP normative requirement.

- A cancelled caller must receive CancellationError only after its
  admitted cooperative receiver has unwound; request cancellation must
  reach that receiver's execution context. Do not promise forcible
  termination of arbitrary noncooperative host code.
- Cancel an active wire request once, using its actual ID. Do not cancel
  a request whose terminal frame has been admitted. Preserve the A2.2b.1
  contract and original callback errors.
- Keep callbacks for each exchange ordered and non-overlapping. A receiver
  may issue a nested exchange on the same running transport, subject to
  normal admission capacity. A blocked outer receiver must not stop the
  stdout reader from routing that distinct nested response.
- No detached/unowned work, lock held across an await, unbounded task
  per frame, unbounded queue, API or dependency change. Full queue-budget,
  EOF/late-frame and cross-transport qualification remain distinct gates.

Integrated production blob `f387f498bac78d0ca67e727ed63ec901d96eb810`:
the stdout task calls `try await self.route(Data(line))`; route awaits
`receive` inline. Thus an awaited nested RPC needs a reader that is
already occupied by the outer callback. The cancellation handler retires
the matching route and resumes the exchange continuation without awaiting
the receiver. Its execution context is the run-owned reader, not the
cancelled caller's task. Source evidence supports both hypotheses; native
reproduction remains required.

## First bounded RED slice (four test functions)

[StdioCallbackOwnershipTests.swift](https://github.com/ThorFuchs/Swift-MCP-Server/blob/1dbd35355f52e9758a2c5f0a031b51d7e5a0b79b/Tests/MCPClientStdioLifecycleTests/StdioCallbackOwnershipTests.swift),
blob `ce802ba4b2eaa1e8a1c8071175a561849b2e4b00`. Test-only source
commit `1dbd35355f52e9758a2c5f0a031b51d7e5a0b79b`. Uses real /bin/sh child and public transport API,
two pending slots, distinct outer ID 71, nested ID 72 and recovery ID
73. Synthetic peer echoes actual request lines to stderr, sends finite
JSON-RPC frames, and records READY/CLEAN and nested terminal emission
markers. All callback/order assertions use the actual public receiver.

| Function | Predicted baseline | Required GREEN behavior |
| --- | --- | --- |
| ordinaryTerminalAndRecoveryPreserveWireOrder | PASS | terminal and recovery, no cancel |
| cancelledNonterminalExchangeJoinsSuspendedReceiver | RED | CancellationError after receiver exit with cancellation observed; exactly one wire cancel 71, then recovery |
| cancelledTerminalExchangeJoinsSuspendedReceiverWithoutWireCancel | RED | same join/cancellation ordering, no wire cancel after terminal receipt, recovery |
| reentrantExchangeProgressesWhileOuterFramesRemainOrdered | RED | nested RPC completes, outer callbacks stay ordered, recovery, no cancel |

The two join probes park the receiver on a cancellation-sensitive
AsyncStream and wait for its explicit entry rendezvous. On cancellation,
the caller wrapper snapshots entered/exited/cancelled state **before**
releasing the gate. Premature-return evidence is therefore positive
observation (entered=1, exited=0), not a sleep-based negative assertion.
The wrapper releases the gate for baseline cleanup; a correct
implementation instead unwinds the cooperative receiver first. The
test-only watchdog may release and shut down the peer if missing
completion; a fired guard is failure, not a successful proof.

For the reentrant probe the child sends outer terminal before nested
terminal on stdout, after actually receiving the distinct nested
request. Expected receiver trace:
`outer-enter, nested-response, outer-exit, outer-terminal, outer-return`.
Structured nested task-group watchdog bounds the wait to ten seconds,
cancels the outstanding nested exchange on failure and allows the
baseline outer callback to unwind. An accepted baseline progress RED
requires the ordinary control PASS, actual peer RX of probe/nested,
both TX markers, missing nested delivery and explicit
A22B2_NESTED_GUARD / nestedDeadline evidence, then recovery and CLEAN;
a generic suite timeout, crash or compile failure is not accepted.
For the two join RED cases require actual admitted frame, explicit
A22B2_RETURN snapshot of an unjoined receiver, subsequent callback exit,
correct cancellation outcome and expected wire cancellation policy,
clean recovery and no join watchdog. Record all discrepancies instead
of reclassifying them to fit the prediction.

## Authoring evidence and native run

Swift 6.2.1 Linux x86_64: exact test blob parses; the same test code
typechecks in Swift language mode 6 with stub JSON/MCP/Subprocess API
types (including Swift Testing macro expansions and concurrency checks).
Three actual /bin/sh controls pass for normal terminal/recovery,
active cancel/recovery, and nested response framing including both
TX markers and clean EOF. These are not actual SwiftPM SDK typechecking
or Swift 6.4.2 native transport results.

Run focused native RED against the exact test-only revision, after
post-merge CI and when Studio idle:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter StdioCallbackOwnershipCases

Use disposable checkout on mounted Backup, exact SHA/tree and test and
production blobs, preserve six dependency-file hashes, static pin check,
raw logs and actual exit. One positive control and three predicted RED
functions (not yet observed). Keep all seven A2.2b.1 tests unchanged.
After a valid RED receipt, design the minimal owned per-exchange
delivery mechanism; it must not resolve cancellation by returning early,
deadlock nested calls, or replace the current reader with unbounded
per-frame Tasks. Explicitly test stale route identity and bounded
delivery in subsequent focused increments. Full Core count then
372 functions if these four tests are admitted without other changes.
Do not start implementation or claim GREEN until native evidence.

## Boundaries

A2.2b.2 is not yet complete after these four probes. In addition to
the three contracts above, audit cancellation-versus-receiver admission,
route identity across reuse, concurrent delivery order and run teardown.
A2.2b.3 addresses remote cancellation, EOF and late-wire-ID correlation;
A2.2b.4 all cumulative queue/resource bounds and restart; A2.2b.5 actual
HTTP counterpart. No final API/RC1 decision, tag, dependency change or
AMD64 qualification in this batch.
