# Core #53 — A1.5 combined qualification snapshot

This is a temporary integration branch, not a release or a merge to main. No source changes beyond the three immutable reviewed branch heads:

- A1.3 shared frozen wire preparation, PR #58: `74f0ff89e12060c0d9c886de0be4949ddd7ee7bb`.
- A1.4 stdio child lifetime, PR #59: `b173846dcbd8267a50878b7cf3bf515d42414b2c`.
- A0 opt-in ARM64 Linux routing, PR #56: `660c6d48cca14822a0c0693dda25ebcab3060992`.

The only overlapping paths are Package.swift and Docs/CLIENT.md; both additive edits are preserved. Keep the independent PRs and their original qualification SHAs intact. A2/#29 and the hygiene PR are not included.

Local evidence already reported: the A1.3 original eight-arm Studio matrix passed; its six new cache tests and full macOS job passed. A1.4 RED 0/6, initial candidate 5/6, corrected fixture 6/6 in 0.307 seconds (maintainer console, SHA follows the runbook, not embedded in the excerpt). PR #56 Linux job ran successfully on `linux-arm64-studio-swift-mcp-server` ([run 45266798765](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45266798765)). None of those receipts qualifies this combined SHA yet.

## Qualification on an idle Studio

    swift test --filter 'ClientFrozenWirePlanCacheCases|StdioChildLifecycleCases'
    MCP_CORE53_OUTPUT_DIR=/absolute/path/to/new-evidence bash Scripts/diagnose-core-stdio-53-v2.sh 2
    python3 Scripts/check-core53-wire-cache.py /absolute/path/to/new-evidence

Retain the unchanged original 26-client-test population and all eight arms. Capture git SHA and all tracked Package.resolved diffs before and after; any changed resolved dependency revision must be examined before using the receipt for release. For each fixture CLEAN sidecar correlate child PID with returned termination status `exited(0)`. No STOP readDeadline and no abnormal exit for a normal CLEAN child. Full arms include intentional oversized-message tests whose run throws instead of returning a status; record missing terminal receipts explicitly and distinguish those cases. Do not equate a green cache checker or test exit alone with clean process lifecycle.

After the Studio proof, use `gh workflow run ci.yml --ref diagnostic/core53-a15-integrated-proof --repo ThorFuchs/Swift-MCP-Server` to run the full Core suite on the selected macOS and Linux runners; `USE_SELF_HOSTED_LINUX=true` selects the opted-in Linux runner. Avoid running the diagnostic and a heavy CI job concurrently on the Studio. The combined branch is qualification only; merge decisions remain subject to actual required checks, review and maintainer approval.

Before closing #53, reconcile lockfiles, qualify the final exact integrated main SHA (macOS/Linux, HTTP interoperability, AMD64 as appropriate), and remove temporary CORE53_DIAGNOSTICS source probes or deliberately retain reviewed test diagnostics. No issue closure, release tag or public visibility change is authorized by this snapshot.
