# Repository instructions

Process: [ADR-0001](Docs/ADR/0001-lean-process.md). Branch → PR → CI → squash merge. Record
decisions that change public API, dependencies, platform floor, security or release scope as a
short ADR in `Docs/ADR/`.

Use Swift tools 6.4, language mode 6 and a macOS/SDK 27 development host. Deployment
minimums are macOS 15, iOS 18 and Linux (ADR-0002); keep Linux building and tested. No package-owned unsafe compiler flags,
retroactive Sendable escapes, silent validation skips, network schema fetches or detached unowned
tasks. Any narrow unsafe interop boundary needs ownership/cancellation justification and native
tests. Never bootstrap process-global logging/metrics, install signals or own host credentials
from a reusable library.

Swift-JSON (`ThorFuchs/Swift-JSON`) is an external dependency: do not rewrite or duplicate it
here. Report candidate issues upstream and use the smallest justified fix.

Use `rg` to locate code. Keep edits focused and add meaningful Swift Testing tests for changed
behaviour, including race/failure paths and wire semantics, not tests that mirror the
implementation. Run `Scripts/test.sh` before opening a PR and report results truthfully.

Preserve `Reference/` bytes and upstream licenses. Never commit machine paths, credentials,
private corpora or generated evidence. Push, tag and release only on maintainer request.
