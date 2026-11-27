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


## Native RED accepted; integrated A2.2b.1 closed (2026-11-27)

The [post-merge CI 46062633342](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/46062633342)
on exact integrated `415f62594e87a573ebea1f2bb701d5c24ad92cc1` completed SUCCESS at
20:44:53 UTC (21:44:53 CET). Raw jobs 140720307091 and 140720307360
confirm Swift 6.4.2, actual macOS arm64/Linux aarch64 checkouts, 368
passing functions each across 16 bundle summaries, 15/15 macOS DocC
and successful symbol inventory, six unchanged dependency files on
each platform; no observed compiler warning or issue diagnostic.
Optimized step intentionally skipped for push. A2.2b.1 accepted total
3,326 planned executions plus 368 successful Debug executions from
the interrupted first optimized attempt = 3,694 cumulative (not unique).
No AMD64 or final RC1 claim.

Original maintainer archive `core-a22b2-red-EkYp370e.tar.gz`,
13,355 bytes, SHA-256
`47e50b3bcc13a687246f61c57db21274a63bb2c7109f987eb06fe9a4ce18a7aa`.
Reopened without extraction, 20 regular members. Exact RED
`1b4b9d8dcc6e3a9cdf64e88bce3b65da03432c80`, tree `a9043d656b4c285c322dd02ee2ea6564adf5aed9`.
The two archived Swift sources independently Git-blob hashed:
`ce802ba4b2eaa1e8a1c8071175a561849b2e4b00` (test),
`f387f498bac78d0ca67e727ed63ec901d96eb810` (production).
Other test blob receipts preserved; six before/after dependency
hashes identical, final working tree clean, static 13-pin comparison
for three workspaces, not actual checkout graph verification.
macOS 27.3 arm64 / Swift 6.4.2 / Xcode and SDK 27.2. Build
129.56 s, test execution 10.146 s, test exit 1, tee exit 0,
integrity PASS; 1 control PASS and 3 reproduced RED, nine issues.

Both joining tests observe cancelled caller return while entered=1,
exited=0 and cancelled=false; receiver subsequently exits without
cancellation. Nonterminal request sends exactly one cancel ID 71
before recovery 73; terminal request sends none. No join guard.
The reentrant peer receives listen 71 and nested 72, emits outer and
nested terminal frames, then explicit nested guard fires. Outcome
nestedDeadline, trace [outer-enter]; both requests cancelled, recovery
73 succeeds and peer CLEAN. Exact accepted progress RED, not mere
suite timeout. All three negative predictions confirmed. No
production change until after this accepted receipt.

A2.2c, A2.2d, A2.3 now run on separate branches from integrated base.
This branch owns MCPClientStdio only; avoid changing shared Client.swift,
configuration, reference or dependency files. Merge remains serialized.


## GREEN candidate: caller-owned bounded delivery

Production commit `f4c5c749a8fee483eaacedea66b7effcf49b3102`,
StdioClientTransport.swift blob `3c3a195dec42ea6eb03bfbb8ead574b2333d16e8`.
The stdout reader frames, parses and demultiplexes synchronously into
per-route bounded AsyncStreams; it never awaits host receiver code.
The exchange caller iterates its own inbox and awaits the receiver
directly on its own task. No new SDK task, dependency, signature or
deadline. Cancellation stops admission and queues at most one
correlated wire cancellation when still active. The slot remains
occupied until the caller's receiver unwinds. The route UUID guards
retirement and cancellation. Cancellation observed before completion
is authoritative; without caller cancellation the original receiver
error is preserved. Admission checks cancellation under the same
mutex, and delivery admission checks cancellation before invoking
host code. A callback already admitted may run on the cancelled
context; arbitrary noncooperative host code cannot be forcibly stopped.

Explicit local policy: at most 16 waiting frames and at most
configuration.maximumMessageBytes queued payload bytes per route,
plus the single frame being delivered. A finite backlog is needed
for reentrant routing on one shared byte stream. When either bound
is exceeded, fail the affected exchange with the existing typed
.busy error, stop delivery rather than silently drop and continue,
and enqueue one wire cancellation only if no terminal frame has
been admitted. Other routes remain routable. The .busy documentation
now includes this overload case (no new enum case or public signature).
The reader does not apply transport-wide head-of-line blocking to a
full route. This is a bounded fail-closed policy, not proof of
complete aggregate transport memory bounds or lossless indefinite
producer backpressure. The existing outgoing stream remains
unbounded; its misleading source comment was corrected, its behavior
not changed. A2.2b.4 owns cumulative queue and resource budgets.
Per-route capacity is an internal implementation policy chosen for
this candidate, subject to review before stable release.

Terminal wire receipt is marked under the lock, before callback
delivery or inbox admission failure. Subsequent same-route frames
are not admitted. EOF closes inboxes so already admitted frames,
including a terminal response, may drain in order; missing terminal
throws serverExited. The process owner still joins the actual child
and I/O; caller tasks own their callbacks, not the run owner.
A new run is refused with the existing .alreadyRunning error while
a previous caller still owns a route, even after process exit.
This is intentional local isolation. Run cancellation does not
forcibly cancel separately owned host tasks. Actual remote cancellation,
late-wire-ID aliasing and teardown of noncooperative receivers remain
A2.2b.3/4 topics; cancellation delivery is not provider teardown proof.

Four additive black-box boundary functions in
Tests/MCPClientStdioLifecycleTests/StdioInboxBoundaryTests.swift,
commit `e3d1095b9b9aaa609e076c0aca6305aed01dbaab`, blob `f21bc9f8eac0b975471e5be6984ffb988dd23bad`:

- cancelledReceiverRetainsSlotUntilItUnwinds: cancellation-insensitive
  test gate, cancellation signal in host receiver, same/different ID
  admission refused with one slot, then release and join, exactly one
  wire cancellation 71 and recovery 73.
- frameOverflowFailsOnlyTheOverloadedExchange: 32 frames while outer
  receiver awaits nested 72, large byte budget; nested response arrives
  after the flood, outer fails busy, no extra callbacks, one cancel 71
  and successful recovery.
- byteOverflowFailsOnlyTheOverloadedExchange: three 445-byte individual
  frames under 512-byte per-line limit but above queued byte budget;
  same isolation and typed failure contract.
- admittedTerminalSurvivesChildEOFWhileReceiverIsParked: real child
  emits terminal and exits; process owner joins while caller receiver
  remains parked. New run refuses until old slot retires, original
  terminal completes after release, no spurious cancellation.

These are new GREEN boundary controls, not separately reproduced RED
claims. Original four RED tests and both seven-function A2.2b.1
test blobs remain unchanged. No new production changes in the
parallel MRTR, retained-state or consumer branches.

Authoring (Linux x86_64, Swift 6.2.1): exact new source and test
parse successfully, Swift-6 typecheck of the candidate exchange,
route, stop and finishAll logic and both new/RED suites with stub
JSON/MCP/Subprocess APIs (run implementation substituted). Eight
isolated executable route/receiver controls passed; twenty repeat
runs = 160/160 executions of those eight controls, covering active
and terminal cancellation, slot retention, reentrant order, both
overflow limits, terminal EOF and restart refusal, active/terminal
callback errors. Four real /bin/sh peer framing controls passed.
The actual SwiftSubprocess run implementation, JSON codec, native
SwiftPM build and Swift 6.4.2 SDK tests have NOT been executed here:
network resolution unavailable and local toolchain differs.
Remote production/boundary blobs match the locally parsed sources.
No native GREEN claimed.

Native GREEN next: exact detached candidate; focused Debug and Release
15 functions each (7 unchanged A2.2b.1 + 4 original RED + 4 new boundary
controls), full locked Debug via Scripts/test.sh 376 functions
expected (368 integrated + 8 new), total 406 cumulative executions.
Require exactly one pass per named function in each stage, proper
join and reentrant trace markers, all four boundary receipts, no
test watchdog/issue and six unchanged dependency bytes, clean source
and blob receipts. Archive exact new and original RED source bytes
and actual commands/exits. Preserve failures; no PR or merge before
native GREEN. Coordinate Studio slots with other audit branches;
no global runner config change, no release tag or final RC1 GO.
