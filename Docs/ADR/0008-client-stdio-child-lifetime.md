# ADR-0008: Separate stdio exchange EOF from child termination

- Status: **Proposed for review** (2026-11-24)
- Scope: Core #53 / A1.4; `MCPClientStdio`

## Context

After the shared frozen wire cache change, all 8 Studio diagnostic arms passed, but 28 CLEAN fixture receipts were followed by signaled(13) child termination. Pinned swift-subprocess 1.0.2 documents unsuccessful termination as a returned status and closes sequence descriptors at the end of its execution closure. The existing transport cancels its stderr reader at stdout EOF and ignores the exit status. The observed signal is real; the exact triggering write is not established solely by the traces.

## Decision

- The execution closure owns three structured tasks: stdin writer, stdout router and stderr reader. Normal stdout EOF closes the outgoing stream and fails outstanding exchanges with serverExited immediately. It does not cancel stderr or relinquish the run permit.
- Join all three tasks and let swift-subprocess close descriptors and reap its child. A real task error is observed through group.next, triggering structured sibling cancellation and upstream teardown. The existing host-owned lifetime and terminationGrace remain unchanged; the host can cancel a noncooperating child. No new polling loop or timeout.
- Return success only for a successful reaped child. Add public StdioClientTransportError.unsuccessfulTermination(TerminationStatus) to expose the exact nonzero code or signal to the run owner. This additive enum case affects exhaustive switches; record before the 1.0 freeze. In-flight exchange errors remain serverExited, and the old error cases remain available.
- Host run cancellation is CancellationError even if the cleanup exit is signaled. A primary I/O or framing failure takes precedence over a later termination status; no errors from the inner task group are swallowed.
- No new process-global signal handlers, manual descriptor closes, detached tasks, dependency updates, or changes to frame/read/idle/grace limits. Do not change validation or Tool Catalog state in this slice.

## Acceptance

Run the isolated public-API lifecycle RED tests on the original transport, then the candidate with exact status assertions. Prove that late stderr arrives, a pending exchange ends before the child finishes stderr, restart is possible after reaping, a simultaneous run is refused, nonzero/signal exit is not success, and cancellation remains cancellation. Full combined Studio, Linux and HTTP qualification is required after A1.3 and A1.4 integrate. See CORE_53_CHILD_LIFECYCLE.md.

## Measured implementation receipt

The combined A1.5 Studio receipt is recorded in [integrated qualification](../Release/CORE_53_INTEGRATED_QUALIFICATION.md). Both new invariant suites and all eight original matrix arms passed; existing deadlines remain. A1.6 removes temporary probes and requires independent qualification of the final clean source and pins. This ADR remains subject to merge review.
