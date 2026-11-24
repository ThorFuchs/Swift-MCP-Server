#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Report public symbols missing authored/extracted comments; not a completeness claim."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
MODULES = ("MCPProtocol", "MCPServer", "MCPStdio", "MCPServiceLifecycle",
           "MCPObservability", "MCPServerTesting", "MCPClient", "MCPClientStdio",
           "MCPTasks", "MCPTasksTesting", "MCPTasksSQLite", "MCPSkills",
           "MCPSkillsClient", "MCPTasksClient", "MCPApps")

def main():
    modules = sys.argv[1:] or MODULES
    for module in modules:
        if module not in MODULES:
            raise ValueError(f"Unknown module: {module}")
        directory = ROOT / ".build/docs/symbols" / module
        main_graph = directory / f"{module}.symbols.json"
        if not main_graph.is_file():
            raise ValueError(f"Build DocC first: {module}")
        symbols = {}
        for path in sorted(directory.glob("*.symbols.json")):
            graph = json.loads(path.read_text(encoding="utf-8"))
            for symbol in graph["symbols"]:
                if symbol.get("accessLevel") not in ("public", "open"):
                    continue
                identifier = symbol["identifier"]["precise"]
                has_comment = any(line.get("text", "").strip()
                                  for line in symbol.get("docComment", {}).get("lines", []))
                title = ".".join(symbol.get("pathComponents", [identifier]))
                before = symbols.get(identifier)
                symbols[identifier] = (title, has_comment or bool(before and before[1]))
        missing = sorted(title for title, documented in symbols.values() if not documented)
        print(f"{module}: {len(symbols)-len(missing)}/{len(symbols)} public symbol records have comments")
        for title in missing:
            print(f"  REVIEW {title}")
    print("Inventory only: inherited/synthesized symbol records may be included. DocC conversion warnings are gated separately.")

if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError) as error:
        print(f"Documentation audit failed: {error}", file=sys.stderr)
        sys.exit(1)
