#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# A1.2 / Core #53: independent fixture termination receipts + wire stage timing.
# Diagnostic only. No production deadline, concurrency, validation or assertion change.
set -euo pipefail
repetitions="${1:-2}"
[[ "$repetitions" =~ ^[1-9]$ ]] || { echo "Expected 1..9 repetitions" >&2; exit 64; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
out="${MCP_CORE53_OUTPUT_DIR:-$root/.build/core53-v2/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
[[ ! -e "$out/results.tsv" ]] || { echo "Evidence directory already contains a run" >&2; exit 2; }
{
    printf 'git_sha='; git rev-parse HEAD
    printf 'git_status:\n'; git status --short
    uname -a
    if command -v sw_vers >/dev/null; then sw_vers; fi
    if command -v xcodebuild >/dev/null; then xcodebuild -version; fi
    swift --version
    printf 'cpu_count='; sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN
    printf 'timestamp_utc='; date -u +%Y-%m-%dT%H:%M:%SZ
    printf 'repetitions=%s\n' "$repetitions"
    printf 'build_flag=CORE53_DIAGNOSTICS\n'
} | tee "$out/provenance.txt"
if command -v xcrun >/dev/null 2>&1; then
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
fi
flags=(-Xswiftc -DCORE53_DIAGNOSTICS)
swift build --package-path Tools/StdioFixture --product StdioFixture "${flags[@]}" 2>&1 | tee "$out/build-fixture.log"
swift build --package-path Examples/StdioServer --product ExampleStdioServer 2>&1 | tee "$out/build-server.log"
MCP_STDIO_FIXTURE="$(swift build --package-path Tools/StdioFixture "${flags[@]}" --show-bin-path)/StdioFixture"
MCP_EXAMPLE_STDIO="$(swift build --package-path Examples/StdioServer --show-bin-path)/ExampleStdioServer"
export MCP_STDIO_FIXTURE MCP_EXAMPLE_STDIO
[[ -x "$MCP_STDIO_FIXTURE" && -x "$MCP_EXAMPLE_STDIO" ]] || { echo "Missing fixture binaries" >&2; exit 2; }
if command -v shasum >/dev/null; then
    shasum -a 256 "$MCP_STDIO_FIXTURE" "$MCP_EXAMPLE_STDIO" > "$out/fixture-sha256.txt"
fi
pair='concurrentRequestsProgressAndShutdownOverOneChannel|listenOverStdioAcknowledgesAndCancelsCleanly'
pressure="$pair|SchemaValidationCases|InvalidServerOutputCases"
printf 'repetition\tarm\texit_status\ttest_summary_seen\tpair_started\tchild_launches\tchild_termination_receipts\tfixture_terminal_receipts\twire_exchange_ends\tlog\n' > "$out/results.tsv"
failed=0
run_arm() {
    local iteration="$1" arm="$2"
    shift 2
    local stem log status=0 summary=0 started=0 launches exits terminal exchanges
    stem="$(printf '%02d' "$iteration")-$arm"
    log="$out/$stem.log"
    export MCP_CORE53_TRACE_DIR="$out/$stem-fixtures"
    mkdir -p "$MCP_CORE53_TRACE_DIR"
    echo "=== iteration=$iteration arm=$arm ==="
    if swift test "${flags[@]}" "$@" > "$log" 2>&1; then status=0; else status=$?; fi
    if grep -Eq 'Test run with [1-9][0-9]* tests?' "$log"; then summary=1; fi
    for name in concurrentRequestsProgressAndShutdownOverOneChannel listenOverStdioAcknowledgesAndCancelsCleanly; do
        if grep -F "$name() started." "$log" >/dev/null; then started=$((started + 1)); fi
    done
    launches="$(grep -c 'event=child.launched' "$log" || true)"
    exits="$(grep -c 'event=child.terminated' "$log" || true)"
    exchanges="$(grep -c 'event=exchange.end' "$log" || true)"
    # No matching files is an explicit zero, not an assumed successful termination.
    terminal="$(find "$MCP_CORE53_TRACE_DIR" -type f -name 'fixture-*.log' -exec grep -El 'event=(STOP|CLEAN|FAIL)( |$)' {} + | wc -l | tr -d '[:space:]')"
    if (( status != 0 || summary != 1 || started != 2 || launches < 2 || exits < 2 || terminal < 2 || exchanges < 2 )); then failed=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$iteration" "$arm" "$status" "$summary" "$started" "$launches" "$exits" "$terminal" "$exchanges" "$log" >> "$out/results.tsv"
    grep -E 'core53-process|core53\]|Test run with|error:|failed' "$log" | tail -n 24 || true
}
for ((iteration=1; iteration<=repetitions; iteration++)); do
    run_arm "$iteration" parallel-all --filter MCPClientTests
    run_arm "$iteration" parallel-pair --filter "$pair"
    run_arm "$iteration" parallel-pair-schema --filter "$pressure"
    run_arm "$iteration" serial-all --filter MCPClientTests --no-parallel
done
cat "$out/results.tsv"
echo "Evidence directory: $out"
echo "Diagnostic only: correlate parent and fixture PID, object ID and stage ticks before assigning cause."
if (( failed != 0 )); then
    echo "At least one test or minimum evidence check failed; retain all logs." >&2
    exit 1
fi
echo "All arms passed minimum receipt checks. This alone does not prove #53 fixed."
