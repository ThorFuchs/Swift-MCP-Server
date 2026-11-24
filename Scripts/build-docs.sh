#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build one DocC archive per public product, using the active Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
DOCC="${DOCC:-$(command -v docc || xcrun --find docc)}"
ALL="MCPProtocol MCPServer MCPStdio MCPServiceLifecycle MCPObservability MCPServerTesting MCPClient MCPClientStdio MCPTasks MCPTasksTesting MCPTasksSQLite MCPSkills MCPSkillsClient MCPTasksClient MCPApps"
if [[ $# -eq 0 ]]; then
    set -- $ALL
fi
for module in "$@"; do
    case " $ALL " in
        *" $module "*) ;;
        *) echo "Unknown public product: $module" >&2; exit 64 ;;
    esac
    [[ -f "Sources/$module/$module.docc/$module.md" ]] || { echo "Missing catalog: $module" >&2; exit 1; }
done

# Follow the Swift-SQLite build-docs pattern, without a new package plugin.
mkdir -p .build/docs
swift package --scratch-path .build/docs/build --force-resolved-versions \
    dump-symbol-graph --minimum-access-level public

# Convert every requested module so one documentation error does not hide
# the diagnostics of the remaining catalogs. The overall gate still fails.
passed=0
failed=0
for module in "$@"; do
    symbols=".build/docs/symbols/$module"
    archive=".build/docs/$module.doccarchive"
    rm -rf "$symbols" "$archive"
    mkdir -p "$symbols"
    find .build/docs/build -path '*symbolgraph*' -name "$module.symbols.json" \
        -exec cp {} "$symbols/" \; -quit
    if [[ ! -s "$symbols/$module.symbols.json" ]]; then
        echo "DocC failed: $module (missing primary symbol graph)" >&2
        failed=$((failed + 1))
        continue
    fi
    find .build/docs/build -path '*symbolgraph*' -name "$module@*.symbols.json" \
        -exec cp {} "$symbols/" \;
    bundle="com.github.thorfuchs.$(printf '%s' "$module" | tr '[:upper:]' '[:lower:]')"
    echo "Converting DocC: $module"
    if "$DOCC" convert "Sources/$module/$module.docc" \
        --fallback-display-name "$module" \
        --fallback-bundle-identifier "$bundle" \
        --additional-symbol-graph-dir "$symbols" \
        --warnings-as-errors \
        --output-path "$archive"; then
        echo "DocC archive: $archive"
        passed=$((passed + 1))
    else
        rm -rf "$archive"
        echo "DocC failed: $module" >&2
        failed=$((failed + 1))
    fi
done
printf 'DocC summary: %d/%d archives built, %d failed.\n' "$passed" "$#" "$failed"
[[ "$failed" -eq 0 ]]
