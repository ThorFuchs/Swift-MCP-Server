# Runtime and concurrency

The runtime receives a decoded admitted envelope, captures an immutable catalog/schema generation and
establishes a typed request context. Middleware order is deliberate: raw transport admission → envelope
and version metadata → identity verification → capabilities/extensions and scopes → schema validation →
handler → output validation → terminal response. Logging/metrics wrap that flow without changing authority.
Registration is deterministic, scalar-exact and rejects duplicate names/invalid schemas before exposure.

Bound active handlers and admission queues. Queued requests expire/cancel without consuming handler slots.
Saturation emits a deterministic documented error/status, not unbounded task creation. Per-principal
limits use verified identities, not claimed client metadata. Anonymous limits use an explicit host policy.
Each request owns a finite budget, deadline, child tasks and emitter. A single terminal owner serializes
success/error/cancellation/disconnect completion and releases capacity exactly once.

Use structured task groups and cancellation-aware AsyncSequences/I/O. No Task.detached for convenient
lifetime escape. Actors own mutable shared catalog/event/state state; immutable snapshots can cross actor
boundaries when Sendable is proven. Do not hold actor critical sections while invoking host providers.
Define callback cancellation cooperation, executor behavior and reentrancy. An arbitrary host callback
cannot be forcefully preempted: limits bound library-controlled work and queues, with honest diagnostics
when a handler ignores cancellation. Avoid exposing such callbacks as a hard CPU deadline guarantee.

Tests must orchestrate double-completion, queued cancellation, disconnect during validation/write,
catalog replacement in-flight, same-ID concurrency, handler throw versus tool error, scope isolation,
work exhaustion and teardown races. Trace IDs are observability only. No client capability grants a host
permission, and no transport-specific fixture switch exists in production code.
