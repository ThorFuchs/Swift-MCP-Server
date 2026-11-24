# Core #53 — A1.2: wire validation and fixture exit evidence

> Historical investigation. The temporary probes and executable diagnostic scripts are preserved on the immutable [A1.5 snapshot](https://github.com/ThorFuchs/Swift-MCP-Server/tree/94b80a5a2a437af8b28d38b4312f30e822606706), not in the cleaned release path. See [integrated qualification](CORE_53_INTEGRATED_QUALIFICATION.md).

Diagnostic-only follow-up to PR #54, parent d854b7ebd3c4d5e9ce05f0603b4aed991794a4f1. Do not merge these probes into a release branch.

## A1.1 evidence
The Studio archive `SwiftMCP-Core53-Studio-20261123T194742Z.tar.gz` records 12/12 arms on macOS 27.3 / Swift 6.4.2 / 16 CPUs. All three parallel MCPClientTests arms fail in the same two cases; the nine isolation/serial controls pass. In all six failing target traces, `fixture.stderr READY` precedes `run.return` by approximately 30.027–30.204 seconds; `discover.ready` occurs after `run.return`. No terminal fixture stderr receipt was captured. The default server read idle policy is 30,000 ms, but the actual exit reason and slow stage were NOT measured.

## A1.2 instrumentation
Only enabled by command-line `-Xswiftc -DCORE53_DIAGNOSTICS`. No API, manifest, dependency pin, timeout, cancellation behavior, validation logic, or test expectation change. Keep this draft diagnostic branch separate from production.

- `[core53-process]`: actual child PID from swift-subprocess 1.0.2, stdout EOF, and exact returned termination status. The status is observed but not converted into an error in this experiment.
- `[core53-fixture]` sidecar: independent per-event files in the arm evidence directory. Child PID, monotonic tick, START, PREPARE_BEGIN/END, actual POLICY, READY, STOP/CLEAN/FAIL. Records are written before stderr; missing terminal sidecar is missing evidence, not proof of a clean exit.
- `[core53-wire]`: client object ID and unique validator UUID, request method/ID, response parse, exchange end, validation await begin/end, frozen schema read/parse/root/compile and evaluation. No wire body, schema content, or credentials are logged.
- Test traces correlate client/transport object identities within one test process, and add monotonic ticks. Match fixture sidecars by child PID (do not assume stderr delivery order equals child event order). Ticks are useful for elapsed times; use explicit causal boundaries rather than timestamps alone.

## Run
On an idle Studio from a fresh checkout of the exact A1.2 commit:

    bash Scripts/diagnose-core-stdio-53-v2.sh 2

Four arms per repetition: complete parallel MCPClientTests, exactly the two failing tests in parallel, the same pair plus SchemaValidationCases and InvalidServerOutputCases, and complete serial MCPClientTests. The original A1.1 matrix is preserved. All arms use the same instrumented fixture binary. Inspect full logs to verify selections and correlate every target; minimum receipt counts are not a substitute for per-PID evidence. The script finishes all arms and returns nonzero for failed tests or missing minimum receipts.

## Decision gates
1. A fixture STOP readDeadline plus matching subprocess status establishes the immediate exit cause for that child; a stdout EOF alone does not.
2. Compare exchange.end to validation.await.end and schema read/parse/root/compile/evaluation intervals; distinguish actor wait/scheduling from measured synchronous work.
3. Compare pair vs pair+schema vs all vs serial. Failure disappearing with tracing is a perturbation observation, not a fix.
4. Keep normal product code and default policy unchanged pending evidence. A shared frozen-schema cache and child-exit error propagation are separate hypotheses, not authorized fixes in this slice.

## Validation status
Normal A1.1 CI passed macOS/Linux; A1.2 diagnostic flag requires execution on Swift 6.4.2. The normal CI without the flag cannot establish correctness of the diagnostic-only code. No new build or test success is claimed before executing A1.2.
