#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Capture and compare the exact six Core/stdio manifest and lockfile bytes.
# No Git worktree, global Git configuration or checkout credentials are needed.
set -euo pipefail
export LC_ALL=C
umask 077

if [[ $# != 2 || ( "$1" != snapshot && "$1" != verify ) || "$2" != /* ]]; then
    echo "Usage: $0 snapshot|verify /absolute/path/to/receipt" >&2
    exit 64
fi
mode="$1"
receipt="$2"
cd "$(dirname "$0")/.."
files=(Package.swift Package.resolved
       Examples/StdioServer/Package.swift Examples/StdioServer/Package.resolved
       Tools/StdioFixture/Package.swift Tools/StdioFixture/Package.resolved)

if [[ "$mode" == verify && ! -s "$receipt" ]]; then
    echo "Missing or empty dependency snapshot: $receipt" >&2
    exit 1
fi
scratch="$(mktemp "${receipt}.XXXXXX")"
trap 'rm -f "$scratch"' EXIT
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${files[@]}" > "$scratch"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${files[@]}" > "$scratch"
else
    echo 'No SHA-256 tool available' >&2
    exit 1
fi

if [[ "$mode" == snapshot ]]; then
    mv "$scratch" "$receipt"
    echo 'Captured Core/stdio dependency snapshot:'
    cat "$receipt"
else
    diff -u "$receipt" "$scratch"
    echo 'PASS: all six Core/stdio dependency files are byte-for-byte unchanged.'
fi
