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
