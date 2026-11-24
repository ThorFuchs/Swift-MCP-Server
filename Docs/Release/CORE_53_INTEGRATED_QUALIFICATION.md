# Core #53 — integrated reliability and performance qualification

## Immutable A1.5 evidence

Historical measured receipt for commit `94b80a5a2a437af8b28d38b4312f30e822606706`, not release approval of later bytes. This snapshot combined A1.3 #58 (`74f0ff89e12060c0d9c886de0be4949ddd7ee7bb`), A1.4 #59 (`b173846dcbd8267a50878b7cf3bf515d42414b2c`) and A0 #56 (`660c6d48cca14822a0c0693dda25ebcab3060992`).

Studio archive `SwiftMCP-Core53-A15-Studio-20261124T085306Z.tar.gz`; SHA-256 `db5b4233f569c61b0b18ddc601ea338fdc6c1cf4f6240a11da868450c31e58ff`. macOS 27.3, Xcode 27.2, Swift 6.4.2, ARM64, 16 CPUs. Exact SHA and initially clean status captured. Raw machine-local evidence remains outside Git.

| Arm (two repetitions) | A1.5 passes | Parses / successful compiles / hits / evaluations per process |
|---|---:|---|
| parallel-all | 52/52 | 1 / 15 / 55 / 70 |
| parallel-pair | 4/4 | 1 / 5 / 6 / 11 |
| parallel-pair-schema | 12/12 | 1 / 10 / 27 / 37 |
| serial-all | 52/52 | 1 / 15 / 55 / 70 |

12/12 separate invariants plus 120/120 matrix executions. All eight checker arms PASS, no capacity fallback or duplicate completed compile per definition. 32 child launches, 28 CLEAN sidecars matched to 28 exited(0) receipts, no STOP readDeadline, no recorded SIGPIPE. Four expected framing/oversize failure paths did not return a termination receipt; their OS exit status is not established. A1.3 alone recorded 28 CLEAN children with 28 signaled(13) statuses.

Full parallel suite mean duration: A1.2 128.808 s (failed runs), A1.3 64.078 s, A1.5 60.020 s. A1.2 -> A1.5 is a 53.4% observed workload time reduction, not a generic SDK speedup. Completed schema parses 28 -> 1, completed compiles 49 -> 15, DiscoverResult compiles 8 -> 1. A1.5 full runs complete 70 evaluations each. Original idle and framing deadlines unchanged.

### Provenance limitation

A1.5 started clean; afterward both fixture/example lockfiles gained the same missing Swift-SQLite 1.2.0 pin (`df12fe55265de81e2fc4bca91cb85704343b528f`); existing pins unchanged. Root selected 1.0.0. Native SQLite task-store behavior on 1.2.0 is not established by the stdio proof. ADR-0009 unifies the graph and requires fresh qualification.

### Reproduce the instrumented experiment

The temporary flag, sidecars and test traces are retired from shipping source. Reproduce on the exact [A1.5 snapshot](https://github.com/ThorFuchs/Swift-MCP-Server/tree/94b80a5a2a437af8b28d38b4312f30e822606706), not the cleaned candidate:

    git checkout --detach 94b80a5a2a437af8b28d38b4312f30e822606706
    swift test --filter 'ClientFrozenWirePlanCacheCases|StdioChildLifecycleCases'
    MCP_CORE53_OUTPUT_DIR=/absolute/path/to/new-evidence bash Scripts/diagnose-core-stdio-53-v2.sh 2
    python3 Scripts/check-core53-wire-cache.py /absolute/path/to/new-evidence

The offline checker remains available for historical archives. It is not a substitute for tests of uninstrumented source.

## A1.6 final integration

Integrate #55, #56, #58, #59. Retain the two permanent invariant suites; restore the original 26 MCPClientTests and fixture sources before #54, removing only temporary instrumentation. Upgrade SQLite per ADR-0009. Qualify the exact cleaned candidate with strict resolution, full macOS and Linux CI, optimized builds, DocC and repeat parallel Client tests without added flags. HTTP interoperability, the remaining client API audit and release contract stay open. Historical receipts do not qualify changed source or dependencies. No automatic issue closure or release tag.
