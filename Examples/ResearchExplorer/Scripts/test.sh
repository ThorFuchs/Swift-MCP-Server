#!/bin/bash
# Builds the CLI the journey tests launch, then runs all Explorer tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swift build --product wikipedia-research-explorer
export WRE_CLI="$(swift build --show-bin-path)/wikipedia-research-explorer"
swift test "$@"
