# Lifecycle and resource ownership

ServiceLifecycle adapters wrap explicit runtime/transport closures rather than forcing both transports
into every server. A dependency-ordered service group starts configured providers/registries, binds the
listener/FD loop, marks ready after validation and then admits traffic. Readiness is a local host seam,
not a fabricated MCP protocol method or global health server.

Shutdown stops admission, closes listener, cancels/ends subscriptions, drains bounded in-flight work and
writers until deadline, then force-closes owned I/O resources and awaits child tasks. Reverse dependency
order keeps providers alive while admitted handlers drain. Ownership covers accepted channels as well as
listening sockets; tests must prove they close. Borrowed FDs and host services remain host-owned.

Embedded service groups use empty signal arrays and no process-wide bootstrap. Standalone examples install
SIGTERM/SIGINT at the application boundary. Qualify the exact candidate lifecycle maximum-cancellation
behavior: its fatalError path must not be reachable as an embedding library's routine drain policy.
Prefer explicit transport close and awaited cancellation with bounded host-reported failure; document any
uncooperative host callback rather than aborting the process or claiming it was preempted.

Swift Testing cases use injected clocks for state transitions and real listeners/subprocesses for owned
I/O. Verify startup failure cleanup, duplicate start/stop, graceful success, deadline escalation, signal
opt-in, child failure, stalled writer, uncooperative callback and repeated create/destroy resource counts.

P07 now implements a connection-owned stdio shutdown seam: shutdown stops input,
closes only matching principal/origin subscriptions, drains until the configured
deadline and awaits structured request/worker cleanup. Cancelling run aborts both
directions. Native EOF, parent cancellation, stalled output, repeated teardown
and cooperative-after-delay provider cases exercise this seam. It does not
implement ServiceLifecycle adapters, host signals, HTTP channel shutdown or the
aggregate Q10 gate. A provider ignoring cancellation delays completion; no SDK
fatalError or process termination substitutes for joining it.

P10's adapter now implements this dependency graph and ownership seam. A component
name/dependency is bounded ASCII (1...64bytes), graphs have1...64nodes and run is
one-shot. The entire drain uses one absolute monotonic deadline, including the
admission-stop and component shutdown callbacks. A delayed callback can leave the
runtime in draining with a visible failure report until it cooperates; it remains
owned and is joined. `forceClose` must be fast, synchronous and close only component-
owned I/O; it must not create unowned work. Cancellation of the enclosing run is
preserved as CancellationError after all children join.

EmbeddedServerGroup's private configuration sets empty signal arrays and nil
maximumCancellationDuration/maximumGracefulShutdownDuration. The exact2.12.1 timer
fatalError branch is therefore unreachable through this wrapper's routine drain
policy. This is a narrow configuration claim, not a claim that the dependency has
no other programmer-invariant fatalErrors. No upstream source is changed. Standalone
signal examples, measured process RSS/performance and full consumer/referee gates
remain separate work; local logical ownership/native I/O tests are not their pass.

The runtime exposes a read-only RuntimeReadiness view. Only the owning service
changes its state. A listener address is available before the service processes
the readiness event; callers must await the runtime's ready state. Invalid/overflowed
clock values fail closed and force-close declared owned resources before joining.
