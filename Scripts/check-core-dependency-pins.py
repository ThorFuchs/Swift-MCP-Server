#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check that all three local Core/stdio workspaces select the same graph."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
WORKSPACES = (ROOT, ROOT / "Examples/StdioServer", ROOT / "Tools/StdioFixture")
SQLITE = {"version": "1.2.0", "revision": "df12fe55265de81e2fc4bca91cb85704343b528f"}

def main():
    expected = None
    for workspace in WORKSPACES:
        label = str(workspace.relative_to(ROOT))
        lock = json.loads((workspace / "Package.resolved").read_text(encoding="utf-8"))
        digest = hashlib.sha256((workspace / "Package.swift").read_bytes()).hexdigest()
        if lock.get("version") != 3 or lock.get("originHash") != digest:
            raise ValueError(f"{label}: stale v3 origin hash")
        pins = {pin["identity"]: pin for pin in lock["pins"]}
        if len(pins) != len(lock["pins"]) or pins["swift-sqlite"]["state"] != SQLITE:
            raise ValueError(f"{label}: duplicate pins or wrong SQLite release")
        if expected is None:
            expected = pins
        elif pins != expected:
            raise ValueError(f"{label}: dependency graph differs")
        print(f"{label}: {len(pins)} matching release pins; SQLite 1.2.0")
    print("PASS: three Core/stdio graphs agree (static receipt, not native resolution).")

if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
