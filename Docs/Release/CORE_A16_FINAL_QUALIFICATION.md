# A1.6 — clean Core integration candidate

This candidate includes the original A1.5 integration of #56, #58 and #59 plus
#55, four observed compiler-warning corrections, SQLite 1.2.0, retired temporary
instrumentation, public API comments, all fifteen DocC module catalogs and strict
locked CI. A2/#29 remains independent. No release tag or issue closure yet.

## Evidence

[Integrated qualification](CORE_53_INTEGRATED_QUALIFICATION.md) is the immutable
A1.5 receipt. It does not establish that the new dependency graph and cleaned
source pass. ADR-0009 identifies exactly one updated version and two added pins.
The other twelve Core/stdio selected revisions remain unchanged.

## Required native gates

- Fresh checkout of the exact candidate SHA, Swift 6.4.2; no package edit overrides.
- `python3 Scripts/check-core-dependency-pins.py`; native strict resolution of all three workspaces.
- Full normal `MCP_STRICT_RESOLUTION=1 Scripts/test.sh` on macOS and Linux ARM64, with all fixture tests including the new cache and child lifecycle tests.
- Optimized `MCP_STRICT_RESOLUTION=1 MCP_FIXTURE_CONFIGURATION=release Scripts/test.sh -c release` on both platforms. This uses optimized fixture binaries too.
- Three independent repetitions of the original `MCPClientTests` filtered workload on the idle 16-core Studio, no `--no-parallel`, temporary flags or changed deadlines.
- SQLite task-store conformance and durability/reopen checks on the new 1.2.0 selection.
- `bash Scripts/build-docs.sh`, all 15 module archives, DocC warnings are errors. `python3 Scripts/audit-docs.py` inventories per-symbol comment gaps for the broader A3 API freeze; the presence of a catalog is not a claim of 100% individual symbol coverage.
- Review fresh build logs for compiler warnings. The known four warning sites are fixed, but a clean full native build is required to establish zero warnings.
- No changes to the three locked manifests or resolved files during testing. Preserve the evidence outside Git.
- Qualify the final merged SHA and HTTP interop/external consumers before closing #53 or tagging. Linux ARM64 does not substitute for the separate AMD64 release check. Research Explorer has its own Core/HTTP URL-based consumer graph.

CI retains its existing normal macOS and Linux jobs and pinned Linux container.
A manual workflow dispatch with `qualify_release=true` additionally runs the
optimized tests. The macOS job converts all DocC catalogs and inventories comments.
The normal PR workflow does not claim release qualification by itself.

    gh workflow run ci.yml --repo ThorFuchs/Swift-MCP-Server \
      --ref release/core-a16-integration-hygiene -f qualify_release=true

Use the repository's established trusted self-hosted runner configuration.
Do not run the heavy Studio diagnostics concurrently with another heavy Studio
CI job. No CI artifact quota bypass or test weakening.

After a successful review and native qualification of this consolidated candidate,
merge only this integration PR, not the component PRs independently. Reconcile
the superseded PRs and keep their immutable evidence and history.


## A1.6 first native CI receipt and A1.6a gate correction

[CI run 45369333372](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45369333372) on exact commit `3a0ebaa01843544d2e18917931b34279a3db7fec`, 2026-11-24:

- Linux ARM64, Swift 6.4.2: 325/325 test functions passed. The job failed afterward at the Git-based lockfile check (exit 129, "Not a git repository"). No lockfile mutation was established by this error.
- macOS ARM64: 324/325 test functions passed; the lockfile gate passed. The single issue was in the existing `borrowedFlagsUnchangedOwnedDescriptorsClosedAndSingleUse` test at TransportOwnershipTests.swift:117. DocC conversion was skipped after that test failure.
- Both jobs passed 6/6 shared cache, 6/6 child lifecycle, 26/26 client and 5/5 SQLite task-store tests (including conformance and reopen). All three workspace builds selected SQLite 1.2.0. No Swift compiler warnings appeared in either log. Linux emitted the Git warning above.
- A1.6a replaces the Git-dependent final command on both jobs with an exact SHA-256 before/after receipt for all three manifests and three lockfiles. Capture immediately after checkout, outside the source tree; compare even after a test/DocC failure when capture succeeded. Missing input, receipt, hash utility or any byte change fails. Strict SwiftPM resolution and macOS static pin consistency checks remain enabled. No broad Git safe-directory exception.
- Authoring-host shell control, in a temporary non-Git directory: script syntax valid; unchanged snapshot passes; edited lockfile, edited manifest, deleted lockfile and missing receipt each fail; restored inputs pass. Native CI execution of the new gate is still required.


## A1.6b — descriptor identity and close proof

The first A1.6 CI reported `fcntl(ownedInput.readEnd.rawValue,F_GETFD) == -1`
as false (returned 1). It does not establish whether that integer still
identifies the original pipe. The constructor first prepares duplicates, then
closes the transferred originals exactly once and emits the existing
`transferred.input` / `transferred.output` probe events only after successful
close; ambiguous close errors are retained through run settlement.

An isolated Linux authoring-host control created a pipe, duplicated its read
end, closed the original descriptor, and opened an unrelated file with that
same numeric descriptor. F_GETFD returned success even though the original
had closed. After closing the retained duplicate, the original pipe's peer
reported EPIPE. This demonstrates the invalid inference in the former test;
it is not a direct replay or proof of the historical macOS event.

Keep the original borrowed-flag checks, single-use assertion, shutdown/run
and activity assertions. Replace the two stale-integer assertions with:

1. Exactly one successful original transfer-close receipt for each endpoint
   at construction, with no worker activation or prepared-endpoint close yet.
2. Both endpoint joins and exactly one close receipt for each of the six
   prepared descriptors/wake-pipe ends after settlement.
3. Independent EPIPE and EOF observations on the test-owned original pipe
   peers after joining, under the existing 100 ms kernel observation bound.
   No unexpected payload or other I/O error is accepted. Use the existing
   test-only SIGPIPE suppression helper, never add an SDK signal handler.
4. Close originals in test cleanup only if transfer did not succeed. Never
   inspect or close a stale transferred descriptor number.

This changes only the ownership test and its documentation, not production
StdioTransport, FileDescriptorIO, policy, deadlines, test count or suite
parallelism. Test-only CLOEXEC pipes reduce unrelated child inheritance.
The strengthened test needs native parallel-suite qualification on both
platforms, followed by repeated Studio runs. An observed failure must
still be investigated; the earlier macOS event is not retroactively declared
a proven FD reuse event.
