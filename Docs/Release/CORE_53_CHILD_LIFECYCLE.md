# Core #53 — A1.4 child process and stream ownership

## Observed evidence before this slice (A1.3)

On 2026-11-24 both original Studio archives were re-read. See [PR #58](https://github.com/ThorFuchs/Swift-MCP-Server/pull/58) for the exact SHA-256 receipts, CI job and provenance. On the 16-core Studio, the shared frozen plan cache removed the original read-idle failures in both parallel-all repetitions (8/8 matrix arms, 120/120 tests). Full parallel runs: parses 28 -> 1; successful compiles 49 -> 15; mean suite duration 128.808 -> 64.078 seconds. Baseline failed; the after checkout had two modified fixture/example lockfiles. These are workload-specific measurements, not a universal benchmark.

Independently, in A1.3, 32 child launches produced 28 CLEAN sidecars and 28 matching `signaled(13)` termination receipts, with 4 launches lacking a termination receipt. No STOP readDeadline sidecar remained. Existing success assertions therefore do not establish clean process exit.

## Source-level finding

The pinned swift-subprocess 1.0.2 (`dbe21bd7dfd4ffef8c32588918542a8abfa1b54c`) documents nonzero termination as a returned `ExecutionResult.terminationStatus`, not a thrown error. Its `API.swift` closes stdout/stderr sequences when the execution body returns. Its process monitor cancels process-owned I/O and drains buffered output after child termination. Our stdio client's body instead cancels both child tasks on stdout EOF, ignores group errors, and discards the termination status. Early stderr abandonment is a strong candidate for the observed SIGPIPE; the archive alone does not identify the exact triggering write.

## RED / GREEN qualification

The new separate `MCPClientStdioLifecycleTests` target exercises actual lightweight shell children through public APIs. Run the RED commit before running the candidate correction. Preserve logs for all six cases. No new test has been run on native Swift 6.4.2 in this authoring environment.

    swift test --filter StdioChildLifecycleCases

Cases: late stderr after stdout closes; nonzero exit; signal exit; restart after failure; caller cancellation; a pending exchange that must fail at stdout EOF before the child can finish its final stderr (explicit per-test acknowledgement). The one-minute test trait and finite fixture guard are test safety bounds, not changes to production deadlines.

The original 26-test A1.2 matrix remains separately comparable. A1.3 and A1.4 are independent PRs based on the same main baseline. After both are integrated and dependency provenance verified, rerun the combined instrumented matrix: all tests green, normal CLEAN child exits zero with complete stderr receipts; distinguish intentionally failing oversize/cancellation cases. Do not expect success for intentionally failed children. Full native macOS/Linux and HTTP interop remain required.

Do not merge RED-only or unqualified changes. No dependency update, signal handler, new retry, validation skip, timeout increase, or global suite serialization.

## Candidate correction (not yet natively qualified)

See ADR-0008. All three stream tasks are joined; stdout EOF ends exchanges but does not cancel stderr. Reaped nonzero/signal status is a typed run-owner error, caller cancellation remains CancellationError, and primary I/O failures are propagated. GREEN tests assert exact status values and reject a second run while the previous child is still draining stderr. Neither RED nor GREEN native execution has been observed for the new isolated tests. Do not interpret static predictions as a test receipt.
