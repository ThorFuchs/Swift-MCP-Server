# MCPServiceLifecycle test plan

Startup failure cleanup/readiness, reverse shutdown, signals opt-in only, active request/subscription/connection drain, borrowed FD preservation, actual dependency cancellation behavior and repeated lifecycle leaks.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.

OwnershipTests.swift implements12 native functions: dependency order/readiness,
reverse drain/provider lifetime, startup failure/partial graph cleanup, invalid and
finite graphs/policies, one-shot shutdown/run, read-only runtime readiness and clock overflow, injected startup and drain deadlines,
late run/shutdown/admission callbacks, pinned embedded cancellation without abort,
repeated embedded lifetimes and real owned stdio descriptor/core admission closure.
MCPHTTPTests/LifecycleListenerTests.swift adds2 functions (one with plaintext/trusted
TLS rows) for accepted subscription channel/listener closure and active provider
cancellation. Existing133 stdio baseline functions and all HTTP sprint cases remain
byte-identical. Embedded signals remain disabled; standalone host signal qualification,
full consumption and measured resource/performance evidence remain pending.
