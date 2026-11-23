# Core #53 — A1.3 frozen client wire plan qualification

## RED evidence (observed before implementation)

A1.2 exact diagnostic SHA `f92ef607c699396c3fb954c8b627b4e486c3c912`, 16-core Studio, macOS 27.3, Swift 6.4.2: eight complete arms, both parallel-all arms fail in the two known stdio cases; six controls pass. All four affected child sidecars report `STOP readDeadline active=0 requests=0 buffered=0 events=0`. Each parallel-all log contains 28 completed schema parses, 50 compile attempts, 49 completed compilations of 15 distinct definitions, and 8 completed DiscoverResult compilations. Each serial-all log still contains 28 completed parses and 54 completed compilations. Repeated preparation is measured, not inferred from a timeout.

`Scripts/check-core53-wire-cache.py` was executed against the original A1.2 archive before the implementation: all eight cache-count checks failed, exit status 1. It reads either an evidence directory or the existing tar.gz without extracting it. Raw machine logs and archive paths are not committed.

## GREEN acceptance

Run the same four-arm, two-repetition diagnostic on a fresh checkout of the implementation SHA using the unchanged `Scripts/diagnose-core-stdio-53-v2.sh 2` and a fresh evidence directory. Keep the original 26-test MCPClientTests population unchanged; run the new cache test target separately and in the full suite. Evaluate the archive using the checker:

    python3 Scripts/check-core53-wire-cache.py /path/to/evidence

Expect 8/8 passing selected arms, one completed frozen-document parse per test process, at most one successful compilation per definition, actual evaluations and cache hits, and no default-cache capacity fallback in this measured workload. Failures/cancellation may interrupt compilation attempts; never assume a missing completion is a success. Retention limits are independent of per-operation limits. Bound-exhaustion tests separately establish correct cold validation; they do not promise single-flight retention of entries that cannot fit.

Verify the new concurrency/cancellation/retention tests, macOS and Linux full suite on the exact PR SHA, and HTTP fixture interoperability before closing #53. No idle deadline change, test skips, serialization of existing suites, dependencies, or public API changes.

The separate subprocess exit/SIGPIPE finding from A1.2 is explicitly A1.4, not silently fixed or masked by this cache PR.
