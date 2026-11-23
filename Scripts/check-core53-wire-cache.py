#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check A1.2 evidence without extracting or trusting absolute log paths."""
import collections
import csv
import io
from pathlib import Path
import re
import sys
import tarfile

ARMS = ("parallel-all", "parallel-pair", "parallel-pair-schema", "serial-all")
TRACE = re.compile(r"\[core53-wire\] pid=(\d+) tick_ns=\d+ validator=\S+ event=(\S+)(?: definition=(\S+))?")


def check(read):
    provenance = dict(line.split("=", 1) for line in read("provenance.txt").splitlines() if "=" in line)
    repetitions = int(provenance["repetitions"])
    if not 1 <= repetitions <= 9:
        raise ValueError("invalid repetition count")
    rows = list(csv.DictReader(io.StringIO(read("results.tsv")), delimiter="\t"))
    expected = {(i, arm) for i in range(1, repetitions + 1) for arm in ARMS}
    actual = [(int(row["repetition"]), row["arm"]) for row in rows]
    if set(actual) != expected or len(actual) != len(expected):
        raise ValueError("incomplete or duplicate matrix")
    failures = []
    print("arm\tpid\tparses\tcompile_attempts\tcompiled\tdistinct\thits\tevaluations\tresult")
    for row, (iteration, arm) in zip(rows, actual):
        stem = f"{iteration:02d}-{arm}"
        log = read(stem + ".log")
        if any(row.get(k) != v for k, v in {"exit_status": "0", "test_summary_seen": "1", "pair_started": "2", "selection_verified": "1"}.items()):
            failures.append(stem + ": test/selection failure")
        events = collections.defaultdict(list)
        for pid, event, definition in TRACE.findall(log):
            events[pid].append((event, definition))
        if not events:
            failures.append(stem + ": no wire receipts")
        for pid, trace in sorted(events.items()):
            counts = collections.Counter(event for event, _ in trace)
            compiled = collections.Counter(definition for event, definition in trace if event == "schema.compile.end")
            ok = (counts["schema.parse.end"] == 1 and bool(compiled)
                  and compiled.get("DiscoverResult") == 1 and all(n == 1 for n in compiled.values())
                  and counts["plan.hit"] > 0 and counts["evaluate.end"] > 0
                  and counts["cache.document.notRetained"] == 0 and counts["cache.plan.notRetained"] == 0)
            print(f"{stem}\t{pid}\t{counts['schema.parse.end']}\t{counts['schema.compile.begin']}\t{sum(compiled.values())}\t{len(compiled)}\t{counts['plan.hit']}\t{counts['evaluate.end']}\t{'PASS' if ok else 'FAIL'}")
            if not ok:
                failures.append(stem + ": shared-cache invariant failed for pid " + pid)
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


def main():
    if len(sys.argv) != 2:
        print("Usage: check-core53-wire-cache.py EVIDENCE_DIRECTORY_OR_TAR_GZ", file=sys.stderr)
        return 64
    path = Path(sys.argv[1])
    if path.is_dir():
        return check(lambda name: (path / name).read_text(encoding="utf-8"))
    with tarfile.open(path, "r:*") as archive:
        def read(name):
            member = archive.getmember("evidence/" + name)
            if not member.isfile() or member.size > 32 * 1024 * 1024:
                raise ValueError("invalid evidence member: " + name)
            return archive.extractfile(member).read().decode("utf-8")
        return check(read)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, tarfile.TarError) as error:
        print("Evidence error:", error, file=sys.stderr)
        sys.exit(2)
