# Observability and privacy

Swift Log is the host-injected diagnostic facade. Metrics provides counters/gauges/timers; Service Context
carries request correlation across structured operations. Libraries never bootstrap LoggingSystem or
MetricsSystem, choose exporters, enable system metrics, or install a tracing backend globally.

Useful metrics: admitted/rejected/completed requests by bounded method/status/transport, active handler
and subscription counts, queued bytes, request duration, schema work exhaustion, writer backpressure and
drain duration. Avoid tool/resource/request/client/principal/token strings as unbounded metric dimensions.
A host may opt into a bounded label registry; exhaustion maps to a fixed bucket rather than growing it.

Default logging records method, transport, stable reason and optional host correlation. Do not log bearer
tokens, MRTR state, tool arguments/results, elicited input, sampled messages, roots, private URIs or raw
metadata. Debug payload capture requires explicit host policy, finite size/retention and documented privacy
semantics. Error redaction applies at every layer and to conformance normalization.

Protocol notifications/message are separate wire behavior with per-request capability/level/correlation.
Swift Log severity is not implicitly forwarded to a client. Test that cancellation preserves context,
concurrent requests do not share principal/correlation, metrics cardinality is bounded and captured logs
do not contain known sentinel secrets. Testing helpers avoid introducing process-global state races.

P10 now provides opt-in RequestInstrumentation, injected directly into Server.make.
Core passes already-admitted frozen method classifications/verified identity and
uses its existing typed error observer. Raw dispatch uses unknown without reparsing.
Notification/control paths that bypass ordinary dispatch do not fabricate diagnostic
request scopes. The adapter neither acquires server admission nor resets JSON work.

The real Logger.handler public API clears inherited metadata/provider before storage.
Fresh ServiceContext contains only typed diagnostic trace; correlation never becomes
a metric label or wire ID. The fixed cache ceiling is22method buckets ×3transports
×(9counters +1timer) +5gauges =665, with1...4096active diagnostic scopes (default1024).
Host backend retention/export is host-owned. Fixed logs use debug level under the
injected host policy, with no payload/error capture option. Metrics handlers are
created directly through the injected MetricsFactory rather than global instruments.
Close rejects live scopes; successful close/deinit destroy owned handlers once.

A conforming custom core facade must await exactly one operation invocation and
preserve cancellation/errors. Core rejects missing/repeated/retained-after-return
invocations and restores an operation error even if the facade swallows it. Arbitrary
uncooperative host callbacks are not preempted. Diagnostic terminal outcomes are
fixed categories, independent from the exactly-once wire terminal owner.

Foreign admitted ingress is rejected before it reaches a different server's
diagnostic facade; its original ticket remains usable by its owner. Host log and
metric handlers must be fast and nonblocking. Backend export, retention and arbitrary
host callback cooperation remain host responsibilities. No handler can acquire a
new server permit or restore a terminal request account through this seam.
