# Core #53 — Stdio startup and parallel-suite diagnostic

> Historical investigation. The temporary probes and executable diagnostic scripts are preserved on the immutable [A1.5 snapshot](https://github.com/ThorFuchs/Swift-MCP-Server/tree/94b80a5a2a437af8b28d38b4312f30e822606706), not in the cleaned release path. See [integrated qualification](CORE_53_INTEGRATED_QUALIFICATION.md).

**Scope:** diagnostic evidence only. This PR does not fix the root cause or relax test assertions. Baseline: Core `e74557366c04a671973403f6911cb60fc02a88e3`, macOS 27 / Swift 6.4.2.

## Established before this PR

- On the 16-core Mac Studio, `Scripts/test.sh --filter MCPClientTests` failed in two stdio tests in multiple runs. On the same machine `--no-parallel` passed 26/26. MacBook 10-core CI passed.
- Suites `StdioClientCases` and `StdioClientEdgeCases` are separately `.serialized`, not mutually exclusive.
- Existing `discover()` readiness loops may report `.notRunning` whether `run()` has not yet begun, is unable to launch the child, or has already exited. **This ambiguity is not proof of a Subprocess or production bug.**

## Instrumentation

Two existing tests capture just `READY`/`CLEAN`/`STOP`/`FAIL` fixture stderr lines and use `StdioStartupTrace` for `run.enter`, `run.return`, `run.throw`, discover readiness retries, and subscription acknowledgement. Other test cases and the production transport remain unchanged. Trace sequence numbers provide local per-test order; emitted stderr lines from independent tasks may interleave and do not establish global causal order.

## Controlled four-arm matrix (run on idle Mac Studio)

    bash Scripts/diagnose-core-stdio-53.sh 3

Arms are `parallel-both` (original filtered MCPClientTests invocation), `parallel-stdio` (StdioClientCases alone), `parallel-edge` (StdioClientEdgeCases alone), and `serial-both` (MCPClientTests --no-parallel). Each arm uses the same fixture binaries and test deadlines. Three iterations are the default. Results and full test output are preserved under `.build/core53-evidence/<UTC timestamp>` or `MCP_CORE53_OUTPUT_DIR`.

**Run conditions:** Mac Studio idle of HTTP CI and other heavy Swift builds. Capture OS, Swift toolchain, exact Core SHA, dirty status, CPU and environment. Run the identical script on MacBook as a control. Do not blindly turn on the deliberately stopped Core Studio CI runner.

## Interpret failures before changing production code

1. `discover.notRunning` before `run.enter` suggests a startup/scheduling race, but timestamps from separate tasks alone are not proof.
2. `run.throw` or `run.return` before readiness means examine the exact underlying launch/exit error and fixture diagnostics.
3. `run.enter`, `fixture.stderr READY`, but persistent `.notRunning` requires inspection of the transport state/exchange startup handshake.
4. If each suite alone passes but combined parallel fails, investigate cross-suite subprocess contention and fixture isolation. Do not make suites globally serialized without establishing the cause.
5. If the failure disappears with instrumentation, retain that as a Heisenbug/perturbation observation; reproduce on unmodified main for contrast.

## Acceptance boundary

- The regular Core macOS and Linux CI must compile and pass on the PR SHA.
- Independent evidence from the same 16-core Studio is required before declaring #53 fixed. The new diagnostic script returns nonzero for any arm failure or an empty test selection, but a green matrix does not prove the original issue resolved.
- No new timeout, retry count, `withKnownIssue`, skipped assertion, or product behavior change.
- Next PR only after the evidence localizes a specific lifecycle/scheduling fault; add failing regression first and a minimal correction second.
