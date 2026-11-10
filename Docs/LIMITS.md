# Finite resource policy

Contracts/limits.json defines conservative, balanced (default) and trusted profiles. These are initial
finite policies requiring native calibration, not protocol-mandated sizes or inherited application quotas.
Zero is invalid rather than unlimited. Larger values remain subject to normative protocol limits, such as
completion's maximum 100 values. All arithmetic must check overflow and all error paths release accounting.

Enforce message/result/header/string bounds before allocation growth; enforce decoded mirror/base64 sizes
too. Bound connections, active handlers, admission queues, schema cache count/weight, catalog/page entries,
state/token/claims, MRTR rounds/inputs, event queues, global queued bytes and all I/O deadlines. Reservation
occurs before insertion/write/launch, and release occurs exactly once on cancellation/overflow/completion.

Logical retained weights are deterministic accounting, not an RSS ceiling. Count shared immutable plans
according to documented ownership without accidentally double crediting or undercharging them. Measure
actual allocation/RSS peaks separately on target hardware. Request work accounting includes the public
Swift-JSON reports and library-controlled state/header/cursor encoding; it cannot bound arbitrary provider
CPU behavior. Enforce cumulative remaining-work limits across stages, not a fresh limit per helper.

Before releasing a profile, test limit-1, limit, limit+1, integer overflow, deeply nested/reference-heavy
schemas, expanded strings, slow sockets, cancellation and high concurrency. Every limit needs an owner,
debit location, failure mapping and verification link. Record calibration in Benchmarks/RESULTS.md.

Qualification adds a private process-lifetime frozen wire-plan cache:48definitions,
32MiB reported retained upper bounds including its document,1active cold preparation
and256queued owners. Each registry snapshot retains its own33,554,432byte ceiling.
Warm references pay conservative fixed lookup/copy work; cold/validation reports
remain caller-owned. These logical bounds do not assert measured RSS or throughput.


ServerConfiguration.preparation selects one finite cumulative account per initial
catalog or replacement. Defaults remain256Mwork,128Mcompilation,32Mevaluation and
8Mnumeric/regex compilation/regex aggregate. All fields must be positive, at most
total, with total capped at1billion. A richer trusted host may choose a larger
explicit profile; each helper still uses that account and unchanged stage ceilings.
The conformance catalog requires a larger cold evaluation allowance than defaults;
failed cold and successful warm attempts remain separate evidence, never a reset.

Envelope inspection uses a separate finite admission controller with the configured
activeRequests/queuedRequests ceilings. It shares the server's cumulative request
and buffer accounts, but never consumes the direct cancellation lane. Stopping
admission rejects queued/future inspections. Activity.inspections and
queuedInspections expose the current owned counts; they are logical work counts.

## Effective v0.6 profiles

`ResourceProfile` is an explicit opt-in factory, with balanced matching server/event/state
defaults. It does not propagate every historical Contracts/limits.json proposal into all
subsystems. The calibration ledger identifies the actual owner and effective cap of each
field; independent I/O/header/cursor/schema policies require explicit host configuration.
Historical proposals remain in initial-limits.json. Trusted consumption entries are16384
with32-byte SDK digest keys so settlement fits its independent16MiB reserve; generic host
stores retain their existing independently configured key policy.

Request work, terminal serialization, per-result bytes, retained-buffer capacity and active
requests are coupled ceilings. Reserve/settle arithmetic is checked; a failed or cancelled
account cannot resume. User callbacks, arbitrary domain allocations and scheduling are
outside logical work accounting. Benchmarks report actual debug wall nanoseconds/RSS,
without hard CPU/RSS bounds or unsupported throughput claims.
