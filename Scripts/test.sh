#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build the real subprocess/example binaries, then run the full selected suite.
# Usage: Scripts/test.sh [extra swift test arguments]
# MCP_STRICT_RESOLUTION=1 forbids automatic dependency resolution.
# MCP_FIXTURE_CONFIGURATION=release pairs optimized test runs with optimized fixtures.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if command -v xcrun >/dev/null 2>&1; then
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
fi

configuration="${MCP_FIXTURE_CONFIGURATION:-debug}"
case "$configuration" in debug|release) ;; *) echo "Invalid fixture configuration: $configuration" >&2; exit 64 ;; esac

run_swift() {
    local command="$1"
    shift
    if [[ "${MCP_STRICT_RESOLUTION:-0}" == 1 ]]; then
        swift "$command" --force-resolved-versions "$@"
    else
        swift "$command" "$@"
    fi
}

run_swift build --package-path Tools/StdioFixture -c "$configuration" --product StdioFixture
run_swift build --package-path Examples/StdioServer -c "$configuration" --product ExampleStdioServer

MCP_STDIO_FIXTURE="$(run_swift build --package-path Tools/StdioFixture -c "$configuration" --show-bin-path)/StdioFixture"
MCP_EXAMPLE_STDIO="$(run_swift build --package-path Examples/StdioServer -c "$configuration" --show-bin-path)/ExampleStdioServer"
export MCP_STDIO_FIXTURE MCP_EXAMPLE_STDIO

run_swift test "$@"
