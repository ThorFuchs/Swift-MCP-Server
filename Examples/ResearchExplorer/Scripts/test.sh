#!/bin/bash
# Builds the CLI the journey tests launch, then runs all Explorer tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swift build --product research-explorer
export RE_CLI="$(swift build --show-bin-path)/research-explorer"
swift test "$@"
