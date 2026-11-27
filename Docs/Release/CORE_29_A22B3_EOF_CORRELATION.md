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

