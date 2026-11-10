#!/bin/bash
# Builds the binaries the subprocess/example tests need, then runs the full test suite.
# Usage: Scripts/test.sh [extra swift test arguments]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

swift build --package-path Tools/StdioFixture --product StdioFixture
swift build --package-path Examples/StdioServer --product ExampleStdioServer

MCP_STDIO_FIXTURE="$(swift build --package-path Tools/StdioFixture --show-bin-path)/StdioFixture"
MCP_EXAMPLE_STDIO="$(swift build --package-path Examples/StdioServer --show-bin-path)/ExampleStdioServer"
export MCP_STDIO_FIXTURE MCP_EXAMPLE_STDIO

swift test "$@"
