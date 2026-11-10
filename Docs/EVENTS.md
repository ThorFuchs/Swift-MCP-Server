# Subscriptions and request events

subscriptions/listen establishes a request-scoped stream. Correlate acknowledgement and events to the
subscription ID, and acknowledge that ID before sending its events. Unrelated traffic may interleave.
Keep agreed filters and feature capabilities stable for its lifetime. Notification matching, updates
and list-changed events honor principal visibility. Do not broadcast a private resource update globally.

Bounded queues enforce event count, per-subscriber bytes and server/global queued bytes. Define event
coalescing only for semantically replaceable events; loss of a noncoalescible event terminates with the
documented reason. Overflow/slow writer has one terminal owner, releases capacity and cancels producers.
Never buffer indefinitely behind a blocked HTTP or stdio sink. Long-lived streams have finite lifetimes.

Progress and protocol logging are correlated to their original request; they are not subscription events.
Progress increases, stays within optional total and obeys rate/deadline rules. No progress/logging after
terminal completion. Protocol log level comes from the modern request contract, not an old logging/setLevel
method. Swift Log diagnostics are separate from notifications/message and use host injection/redaction.

Server-initiated teardown on either transport uses acknowledgement → events → cancellation
notification → the existing D02 complete response → close while writable. Cancellation prose
MUST and subscription graceful-complete SHOULD compose; see the RC1-S01 decision below.
Client cancellation/disconnect ends internal work without inventing a reply. Broken transport
cannot deliver terminal bytes; record local termination without retrying a nonexistent session.

## Implemented in-process v0.5 contract

Server.dispatchEvents is the explicit multi-message boundary. Server.handle/dispatch retain
one-response semantics and reject subscriptions/listen. EventCollector records bounded production
dispatch frames. DeliveryMode alone is an in-process ordering policy. Subsequent Q07/Q08 receipts
separately qualify actual stdio subprocess and HTTP/TLS delivery with the approved local NIO
candidate. Aggregate Q06 retains its independent not_run state; an injected mode alone is
never real transport evidence.

The request structurally owns provider, serial writer, deadline and finite prepaid observer.
EventChannel reserves count and stream/principal/global bytes before reported validation/encoding,
shrinks to actual encoded size and releases on write/drop. Queue/copy/write work is separately
prepaid while the main account is live. The existing terminal account remains disjoint.
There are no detached tasks, unbounded AsyncStreams or task-per-event waits.

Defaults:64 queued/in-flight/preparing events,256KiB stream/notification,1MiB principal,16MiB global
and4096 lifetime events. Separate request admission/result buffering further constrain concurrency.
Saturation or encoding failure aborts the channel and drops queued frames; a cooperative blocked sink
is cancelled and joined. Delivery after disconnect is unavailable; no second terminal attempt occurs.
Logical limits do not claim measured physical RSS/CPU bounds.

Only queued list-change or same-URI update events coalesce; an in-flight frame is never replaced.
Progress, logs, acknowledgment and cancellation do not coalesce. Late emission fails eventsUnavailable.
Finishing drains accepted queued frames before the single terminal response when writable.

### Subscriptions

Quota is reserved before preparing acknowledgment; publication begins after ack is queued.
Exact subscriptionId accompanies ack/events/server-cancel/complete. Opt-in stable filters acknowledge
only registered authorized resource URIs; dynamic template URIs are omitted. Defaults:32 global
subscribers,16 per principal,256 URI filters,60-second lifetime, also constrained by ordinary request
deadline (default120seconds) and cumulative work.

Server.publish requires explicit host audience: principal or required scopes; empty scopes explicitly
declare public visibility. The subscription must also authorize/request each URI. Catalog replacement
does not auto-broadcast or revise filters. Streams release catalog generation leases before waiting.
Hosts publish visible changes and call revokeSubscriptions on authority change; old captured authority
does not automatically refresh.

D02 remains the recorded frozen-source interpretation. Real stdio server-close sends cancelled
then complete; its native subprocess coverage also preserves ack-first and silent client cancellation.
The HTTP-mode test sends complete then closes in-process. Subsequent real HTTP/TLS ordering and
peer lifetime checks are recorded in Docs/Evidence/NIOQualification/Q08-passed.json.
Client cancellation/revocation/disconnect does not invent a reply. Lifecycle/referee qualification
remains separate; the subsequent official referee receipt is Q09 in Docs/Evidence/Referee.
Connection close matches both verified principal and origin; it cannot close another
origin or principal using the same Server.

### Progress and opt-in deprecated logging

RequestContext.progress preserves exact string/integer progressToken and fractional/exact JSONNumber.
Accepted values are nonnegative, strictly increasing and within optional total. Small private native
schema predicates perform ordering because JSONNumber has no public comparison. Their compile/evaluate
reports use the same cumulative account; there is no copied comparator or per-event raw protocol compile.
Messages are at most4096bytes; calls faster than40ms return false without advancing the previous value.
Missing channel/token, concurrent preparation, subscription context, cancellation or closure cannot emit.

Protocol logging is default-off; EventPolicy.logRedactor opts in to this deprecated modern feature.
Enabled discovery advertises logging. A request needs io.modelcontextprotocol/logLevel; missing level,
lower severity or50ms throttling returns false. Invalid levels follow frozen invalid-params behavior.
Logger is at most256bytes. Redactor input/output is bounded; hosts remove private data and cooperate with
cancellation. The SDK does not automatically log state, tokens or credentials. Logs/progress use the
originating response channel, never subscriptions. No logging/setLevel or legacy negotiation exists.

Host publication has a separate independently admitted finite requestWork account for audience/URI
checking, subscription filtering and copying, before subscriber accounts encode their frames.
Oversized host audience/URI data rejects before matching, including when there are no subscribers.


## RC1-S01 source correction — 27 October 2026

The HTTP branch now shares server-initiated cancellation notification → complete ordering
with stdio. Correlation, quota/work limits and the event writer remain unchanged. The v0.5
paragraphs and old native receipts above describe historical behavior, not qualification of
this correction. New public-core delivery-mode, principal/origin, exact-ID, client-cancel
and failed-cancellation-write tests are authored but uncompiled/unrun. They are not real
HTTP/TLS proof; those remain separate sprints.
