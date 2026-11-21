#!/bin/bash
# Builds the CLI the journey tests launch, then runs all Explorer tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swift build --product research-explorer
export RE_CLI="$(swift build --show-bin-path)/research-explorer"
# Through a pipe (CI) the test process block-buffers its output, so a stalled run
# shows nothing about which test is running (#28). A pseudo-terminal makes every
# test event line-buffered; `script` returns the child's exit status unchanged.
if [ ! -t 1 ] && command -v script >/dev/null 2>&1; then
    exec script -q /dev/null swift test "$@"
fi
exec swift test "$@"
