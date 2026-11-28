# A2.2b.3 — EOF and wire correlation (#29)

Status: first test-only slice PREPARED, native RED NOT_RUN.
Stacked deliberately on exact native-GREEN A2.2b.2 candidate
`d3a0bdcceaca43dd7dc8d05762524928b3293ee4` (tree `0e48f0d522a45115f7acfa6b38c45d0742ffa082`),
not yet integrated into main. [PR #64](https://github.com/ThorFuchs/Swift-MCP-Server/pull/64)
is separately qualifying this base. No production changes on this branch.
After #64 integration, compare the actual merged tree with that candidate,
replay/rebase only this slice onto the then-current main, reverify the
unchanged test blobs, and qualify the combined exact candidate. Do not
open or merge a competing production PR based on the stacked branch.

## Authority and source observations

Frozen 2026-07-28 reference at the base above:
- basic/index.mdx: outstanding request IDs must be distinct, integer or
  string; a response correlates to its request ID.
- basic/patterns/progress.mdx: progress tokens can be strings or integers,
  unique among active requests, and must identify the active request.
- basic/patterns/subscriptions.mdx: subscription metadata identifies the
  originating listen request on stdio; graceful completion has matching
  response ID and subscriptionId. EOF without a terminal response is not
  graceful completion.
- basic/patterns/cancellation.mdx: server cancellation only for listen;
  invalid cancellation should be ignored, late responses to cancelled
  requests should be ignored. Cancellation does not promise a response.
- basic/transports/stdio.mdx: newline-delimited JSON-RPC, shared channel.
  A valid JSON object without its required newline at EOF is not an
  admitted frame.

`RequestID.swift` represents exact mathematical integers and scalar
strings; `ScalarText.swift` deliberately compares UTF-8 scalar identity.
The exact source `StdioClientTransport.swift`, blob
`3c3a195dec42ea6eb03bfbb8ead574b2333d16e8`, still uses Swift String
dictionary keys for request IDs, including a String equality comparison
for the progress token. Swift String equality uses canonical equivalence:
scalar-distinct IDs may be mistaken for the same wire identity. Also
progress token extraction and routing only use .stringValue. These
hypotheses concern the public low-level exchange API; the higher-level
Client currently generates numeric request IDs and string progress tokens.

The local UUID introduced in A2.2b.1 protects retirement from a stale
local owner. It cannot identify a late wire frame carrying a reused ID.
After cancellation of an unanswered request the slot is removed at caller
unwind; current admission can then reuse that ID even though the old
response may arrive. The base protocol prohibits reuse while an issued
request remains unanswered; choose the existing typed busy as this
test's proposed local admission policy for an unresolved retired ID.
This is not a protocol-mandated error enum, and is not a prohibition of
all reuse after a genuine terminal response. Never add an unbounded
tombstone set to fix the witness. A bounded retirement/poison policy,
terminal reconciliation and actual reuse across new run lifetimes need
explicit design and further evidence, coordinated with A2.2b.4.

Current routing first uses subscriptionId metadata without checking
requestId on notifications/cancelled. The matching pair is used by
the actual SubscriptionHub graceful teardown, which sends cancellation
then the successful terminal response. For the raw transport adopt
the narrow fail-closed local routing policy that a cancellation with
conflicting identities is not delivered to the wrong listen receiver.
The correctly correlated cancellation remains a notification, not an
invented success/terminal or a client-initiated cancel. A higher-level
typed Client/extension contract must be coordinated with A2.2c/d;
no changes to Client.swift in this first slice.

## Eight new public black-box test functions

[Test file](https://github.com/ThorFuchs/Swift-MCP-Server/blob/476bcd93a3806873e1dcca948c62c6a6dc04fb9d/Tests/MCPClientStdioLifecycleTests/StdioEOFCorrelationTests.swift),
blob `4c0b26902de0d9e3c247488838896b8d3893bdda`.

| Function | Baseline prediction | Evidence for acceptance |
| --- | --- | --- |
| stringProgressTokenDoesNotAliasIntegerToken | PASS | Both token types offered; string 17 only then terminal and recovery |
| integerProgressTokenIsDeliveredWithoutStringAliasing | RED | Integer 17 offered but omitted; exact terminal and recovery |
| scalarDistinctResponseCannotCompleteAnotherStringID | RED | Foreign decomposed ID delivered instead of composed ID; both offered and recovery |
| serverCancellationAndGracefulTerminalPreserveOrder | PASS | ACK, matching server cancel 71, terminal; no outbound cancel; recovery |
| conflictingCancellationIdentityDoesNotReachListenReceiver | RED | Foreign requestId 72 delivered on subscription 71, then valid cancellation and terminal; recovery |
| acknowledgedListenWithoutTerminalFailsAtEOF | PASS | ACK only, typed serverExited; clean child exit; no cancel |
| unterminatedJSONLineCannotBecomeGracefulTerminal | PASS | ACK and offered incomplete final line, typed serverExited, no false graceful completion |
| cancelledUnansweredIDCannotBeReissuedIntoOldResponse | RED | After one caller cancellation 71 and join, same ID reaches peer and old response reaches receiver instead of admission refusal; unique ID 73 recovery |

All predictions are static, not executed results. Synthetic shell peer
uses actual public exchange API and finite response sequences, readiness
and ACK rendezvous, exact wire RX log, TX emission witnesses, callback
trace, typed error and CLEAN. No delay chooses successful sequencing.
TX records offered frames, not independent evidence all bytes reached
the receiver. The reuse test intentionally attempts a disallowed
outstanding ID reuse; the peer will return a finite stale response if
the buggy implementation admits it, so RED does not require timeout.
Four predicted controls and four predicted defect functions; accept only
actual named outcomes and the corresponding positive trace/peer evidence.
A generic timeout, compile failure or failing positive control is not
accepted RED. Retain all original fifteen scoped A2.2b.1/2 functions
and their exact source blobs. No production fix until native RED.

## Native run and later slices

On a disposable detached checkout of the final test-only revision:
    
    swift test --force-resolved-versions --jobs 2 -c debug --filter StdioEOFCorrelationCases

Exact SHA/tree, baseline-relative two added paths, source blobs,
six dependency bytes, clean status, static pins, raw log, command and
exit evidence. Run when Studio is idle after #64's qualification
work or an explicitly allocated non-overlapping runner slot. The
launcher checks syntax on Studio; authoring via remote GitHub contents
API, no native SwiftPM execution claimed at preparation.

A2.2b.3 remains broader than these eight tests. Subsequent slices:
1. Exact key/token representation and matching cancellation metadata;
   preserve string/integer distinctions, numeric equality and independent
   active routes. Add duplicate-token and simultaneous stream probes.
2. Unanswered ID retirement, bounded reuse policy, late terminal/error/
   progress/notification isolation and restart; no silent misdelivery,
   no unbounded retained identities.
3. Real native server teardown: valid cancel routing, provider and
   subscription cleanup, exact terminal versus EOF, abrupt process exit,
   unrelated concurrent requests and fresh run. Synthetic probes alone
   cannot prove provider release or all run-cancellation behavior.
4. Requalify previous A2.2b.1/2 joining and inbox contracts; after
   integration on the new base run full locked Core and external HTTP
   regression. Full transport memory/queue budgets remain A2.2b.4,
   HTTP ownership A2.2b.5; no speculative API, dependency or deadline
   change, no tag or RC1 GO.



## First native attempt: compilation blocked; test-only RED2 correction

Maintainer archive `core-a22b3-red-qqYlODMK.tar.gz`, 22,378 bytes,
SHA-256 `efd16c306dcf3a7891266284ce4860383d4469c1e294cd26fce53fe41e80f768`.
Opened without extraction: 26 unique members, 25 regular files.
Exact attempt `fa226f4e624d251097cd7f6dc793176ba6a4c9a6`, tree
`c6e9e29bdbaaf347354bdac56d75f7cc324f23e3`, expected base
`d3a0bdcceaca43dd7dc8d05762524928b3293ee4`. All six archived Swift
files independently Git-blob hashed and matched archived receipts.
Six before/after dependency hash receipts match, expected two added
paths, clean status. Three workspaces have 13 matching pins, SQLite
1.2.0 (static receipt, not native resolution). Native macOS 27.3
ARM64, Swift 6.4.2, Xcode/SDK 27.2. Syntax preflight passed.
Test command exit 1, tee exit 0, integrity PASS, release_gate
NOT_EVALUATED.

**BUILD_BLOCKED, not accepted RED.** Native compiler diagnosed
`StdioEOFCorrelationTests.swift:277:67` in the nested receiver
closure: macro expansion of `#expect(try listenWitness(bytes) == "ack")`
reported "errors thrown from here are not handled". No test started;
zero of eight contracts executed. No compiler warning observed.
Keep the original archive and commit.

Test-only correction `e2b2c773e652d3606796a2f891672861052a5a3f`, new test blob
`e3f048e2aec3715ce34b6b9360fa43e143d8861e`:
evaluate `let witness = try listenWitness(bytes)` before
`#expect(witness == "ack")`, then unchanged ack.send().
Exactly one replacement, reversing it reproduces original test
bytes. No assertion removed, no change to peer, test guards, predicted
outcomes, existing tests or production source. Local Swift 6.2.1
x86_64 frontend parse of exact corrected test and Swift-language-6
typecheck of an isolated equivalent throwing receiver/expectation
closure succeed. Not a full SDK typecheck or native execution.
The remote blob matches the locally parsed corrected bytes.

Repeat the same focused native command on the corrected immutable
revision with all six source checks and dependency integrity checks.
Require all eight actual named outcomes and exact traces; four expected
controls and four hypothesized REDs remain unverified. No production
fix until accepted reproduction. Run after competing Studio CI/external
work completes. Preserve failed attempt and new return separately.


## RED2 accepted; A2.2b.3a exact wire identity candidate

[Native RED2 acceptance](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7238300366).
Original archive core-a22b3-red2-VThWYg8a.tar.gz, 21,230 bytes, SHA-256
1661254bfd7281a356689ac3127c0f6c5d162d506fe3dced06e35315da734215.
Reopened archive and rehashed all six Swift sources, including unchanged
RED2 test e3f048e2aec3715ce34b6b9360fa43e143d8861e and baseline
transport 3c3a195dec42ea6eb03bfbb8ead574b2333d16e8. Actual native build
76.65 s; eight tests in 0.030 s, four controls PASS, four REDs (eight
issues), test exit 1, tee 0, integrity PASS. Numeric token callback
missing, canonically equivalent foreign scalar response delivered,
conflicting server cancellation delivered, and cancelled unanswered ID
reused into stale response. EOF controls pass. The preceding
compile-blocked attempt remains preserved.

This slice fixes the first three reproduced defects, not retirement.
Original eight RED2 functions remain byte-identical; the reuse witness
must still fail with exactly its original four issues. Do not mark
the full suite green, skip the test, or weaken its assertions.

### Source and design

Pinned Swift-JSON 1.9.0 revision
f2a0d12da7028edfbcb0cb307f19a921a3a12d03 (root Package.resolved).
[JSONNumber.swift](https://github.com/ThorFuchs/Swift-JSON/blob/f2a0d12da7028edfbcb0cb307f19a921a3a12d03/Sources/JSON/Number/JSONNumber.swift),
blob 64c5763b6c88f05f2effa0669dbf1af1de90683b, explicitly implements
equality and hash through normalized DecimalComponents, including
integer/decimal storage and zero identity. ScalarText, blob
ffc6d9f7e565de985907efec96b26d818d2fa5d8, compares exact UTF-8 bytes.
No dependency changes or duplicate number canonicalization.

Production commit `7cd30eca8d2520d01a1b94239823ce1d254eb01f`, transport blob
c6a7be78f9d76f95a0de7608155ab3dcd367877d. Private Hashable WireIdentity
uses ScalarText or JSONNumber with isInteger; dictionary keys and
progress tokens share this representation without Int64/Double narrowing,
description-based fallback or Unicode normalization. Non-integer/invalid
keys cannot select routes; explicitly supplied malformed progress token
is refused with existing WireFailure.invalidRequest. The request body
is still inspected as before; this is not a complete outgoing envelope
validation audit.

Under the existing mutex, admission reserves a progress token for
the local route lifetime, including receiver unwind. A duplicate is
refused with existing busy before sending a request; no arbitrary
dictionary winner. This intentionally strengthens local admission
even while a terminal callback is unwinding. The raw transport
uses OutgoingRequest.method metadata to distinguish listen ownership
from ordinary requests. Notification routing requires absent top-level
id and a string method. Progress uses its token, not subscription
metadata (a progress notification carrying subscriptionId is not
admitted by this local policy). Other subscription notifications
require exact subscription identity and a listen owner. Cancellation
also requires requestId to match subscriptionId. Invalid/conflicting
correlation is ignored, not delivered to another route. Valid server
cancellation remains a notification; the terminal response or EOF
determines the outcome. Higher-level Client schema validation and
extension semantics are unchanged. Caller-owned callbacks, inbox bounds,
terminal receipt and route UUID protections unchanged. No new tasks,
public signature, SDK deadlines or dependency change.

### Additive boundary tests

Test-only commit 0450070ef3ea79275ec5dcb4f87d03ede4237e1f precedes the
production fix, new StdioExactIdentityTests.swift blob
9f198976b383f8fcce4eba61c851ab52fc6cea22. Four additional functions:
- simultaneousScalarDistinctIDsAndTokensRemainIndependent: distinct
  composed/decomposed IDs and progress tokens live at the same time;
  actual outer-start, inner-progress, inner-terminal, outer-progress,
  outer-terminal order, clean recovery.
- largeMathematicalIntegerIDsAndTokensUseEquivalentSpellings: above
  Int64 request ID, equivalent exponent notation terminal, numeric
  progress token 10^23 with exponent notation; no string-token alias.
- duplicateActiveProgressTokenRefusesSecondRequest: occupied token
  cannot be used by a distinct ID; exact busy, no request on wire,
  unique nested request and recovery.
- subscriptionNotificationsCannotReachOrdinaryRequest: forged
  subscription cancellation and event at an ordinary request ID are
  ignored, ordinary terminal and recovery remain successful.

These are additive boundary controls, not independently observed native
REDs. Original 15 A2.2b.1/2 regressions and eight RED2 functions unchanged.

### Authoring and native scoped acceptance

Local Swift 6.2.1 x86_64: reconstructed the exact archived transport
via the same anchored replacements and independently Git-blob hashed
it; exact new test bytes also independently hashed. Both match the
remote blobs above. Both files parse. Swift-language-6 typecheck of
the changed route/exchange/stop/lifetime state logic with substituted
run body, stub JSON/MCP/Subprocess APIs, and new Swift Testing macros
passes. Five isolated executable controls of that stubbed route logic
pass (simultaneous scalar IDs/tokens, ordinary integer vs string
progress, duplicate token refusal, conflicting cancellation and
non-listen cancellation). Five real /bin/sh framing controls pass
(including both accepted and hypothetical duplicate-token admission).
These are not the pinned JSON codec, exact large integer runtime,
SwiftSubprocess integration or native SDK test results. Local network
resolution of GitHub unavailable; actual Swift 6.4.2 native build
and execution NOT_RUN.

Run focused Debug and Release on the final immutable candidate:
15 preserved A2.2b.1/2 + 8 original A2.2b.3 RED2 + 4 additive = 27
named functions per mode. Require 26 PASS and exactly one known,
unfixed retirement witness (cancelledUnansweredIDCannotBeReissuedIntoOldResponse,
four original issues), command exit 1, tee 0, all expected wire and
callback receipts, six unchanged dependency bytes and clean source.
The local runner may classify this exact partial outcome as
PASS_SCOPED_A22B3A_IDENTITY_WITH_RETIREMENT_RED, with a separate
retirement status RED and release_gate NOT_EVALUATED. This is not
a full GREEN or integration decision; an unexpected pass of the
remaining RED must be investigated as well. No other failing test
or compile/watchdog failure accepted. Archive actual commands, raw
logs, sources, dependency byte pairs and the receipt checks.

### A2.2b.3b design gate (not implemented)

The outstanding ID reuse RED and analogous late-progress token reuse
need a bounded retired-identity policy for the run lifetime. A local
UUID does not distinguish old wire frames. Reserve enough retirement
capacity when admitting a request, or use an explicit fail-closed
admission/poison policy if the budget is exhausted. Account for both
identity count and retained key bytes, including numeric lexemes;
no arbitrary eviction reopening a retired identity. Keep request IDs
and progress-token namespaces separate, and reserve unresolved
retired tokens as well as IDs so a fresh ID cannot receive old progress.
Conservative retention until actual process/run teardown is a viable
first option; terminal reconciliation, if supported, needs proof
that no valid old frames can still alias and that malformed frames
cannot release capacity. Test saturation, no silent eviction, recovery
with distinct identities when budget allows, valid reuse after genuine
terminal, and reset only after old process and caller routes have
finished. Real server cleanup remains distinct from synthetic proof.
Implement only after reviewing the scoped 3a return; full locked Core
suite, optimized and external qualification then follow on the
reconciled integrated base.

PR #64 remains exact native-qualified candidate and draft, external
HTTP receipt pending. This slice is stacked only on that candidate;
reconcile with actual integrated main before any A2.2b.3 PR. No
production edit on #64 or main, no release or merge authorization.
