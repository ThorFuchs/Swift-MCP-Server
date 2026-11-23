#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Diagnostic matrix only. No retries, test exclusions or relaxed deadlines.
# Usage: bash Scripts/diagnose-core-stdio-53.sh [repetitions: 1..9]
set -euo pipefail

repetitions="${1:-3}"
if [[ ! "$repetitions" =~ ^[1-9]$ ]]; then
    echo "Expected 1..9 repetitions" >&2
    exit 64
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
out="${MCP_CORE53_OUTPUT_DIR:-$root/.build/core53-evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
{
    printf 'git_sha='; git rev-parse HEAD
    printf 'git_status:\n'; git status --short
    printf 'host='; hostname
    printf 'kernel='; uname -a
    if command -v sw_vers >/dev/null; then sw_vers; fi
    if command -v xcodebuild >/dev/null; then xcodebuild -version; fi
    swift --version
    printf 'cpu_count='; sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN || true
    printf 'timestamp_utc='; date -u +%Y-%m-%dT%H:%M:%SZ
    printf 'repetitions=%s\n' "$repetitions"
} > "$out/provenance.txt"
cat "$out/provenance.txt"

# Identical fixture binaries for all four arms; no change to tests or execution limits.
if command -v xcrun >/dev/null 2>&1; then
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
fi
swift build --package-path Tools/StdioFixture --product StdioFixture 2>&1 | tee "$out/build-fixture.log"
swift build --package-path Examples/StdioServer --product ExampleStdioServer 2>&1 | tee "$out/build-server.log"
MCP_STDIO_FIXTURE="$(swift build --package-path Tools/StdioFixture --show-bin-path)/StdioFixture"
MCP_EXAMPLE_STDIO="$(swift build --package-path Examples/StdioServer --show-bin-path)/ExampleStdioServer"
export MCP_STDIO_FIXTURE MCP_EXAMPLE_STDIO
[[ -x "$MCP_STDIO_FIXTURE" && -x "$MCP_EXAMPLE_STDIO" ]] || { echo "Fixture not executable" >&2; exit 2; }

printf 'repetition\tarm\texit_status\tnonempty_test_run\tlog\n' > "$out/results.tsv"
failed=0
run_arm() {
    local iteration="$1" arm="$2"
    shift 2
    local log="$out/$(printf '%02d' "$iteration")-$arm.log" status=0 observed=0
    echo "=== iteration=$iteration arm=$arm ==="
    if swift test "$@" > "$log" 2>&1; then status=0; else status=$?; fi
    # An empty filter match must not count as a green diagnostic.
    if grep -Eq 'Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?' "$log"; then observed=1; fi
    if (( status != 0 || observed == 0 )); then failed=1; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$iteration" "$arm" "$status" "$observed" "$log" >> "$out/results.tsv"
    grep -E 'core53|Test run with|Executed [0-9]+ tests?|error:|failed|passed|Issue recorded' "$log" | tail -n 28 || true
}

for ((iteration=1; iteration<=repetitions; iteration++)); do
    # Original parallel behavior first; then isolate each suite and run a serial control.
    run_arm "$iteration" parallel-both --filter MCPClientTests
    run_arm "$iteration" parallel-stdio --filter StdioClientCases
    run_arm "$iteration" parallel-edge --filter StdioClientEdgeCases
    run_arm "$iteration" serial-both --filter MCPClientTests --no-parallel
done
printf '\nDiagnostic matrix:\n'
cat "$out/results.tsv"
echo "Evidence directory: $out"
if (( failed != 0 )); then
    echo 'At least one diagnostic arm failed or ran zero tests; inspect all logs.' >&2
    exit 1
fi
echo 'All diagnostic arms executed nonempty tests and returned success; this is not proof that the earlier parallel failure is fixed.'
