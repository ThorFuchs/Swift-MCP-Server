# Frozen wire validation

Reuse immutable protocol preparation without sharing request or application state.

## Preparation and evaluation

The package verifies the bundled MCP 2026-07-28 schema and prepares its frozen definitions offline. A process-local actor owns one retained document and the immutable, Sendable definition plans. The preparation path has no suspension between an admitted miss and publication, so concurrent callers reuse a retained artifact. Evaluation remains per response and outside that shared actor.

The cache has independent retention ceilings of 48 definitions and 32 MiB of reported logical retained bytes, not a process RSS promise. When an artifact cannot fit, the caller still compiles and evaluates it; retention exhaustion is not permission to bypass validation. Cancellation is checked around preparation and evaluation. Failed preparation never publishes a partial plan.

Server-supplied tool and elicitation schemas remain in a client-local cache. No credentials, authority, request values, server catalogs or response data enter the shared frozen cache.

## Measured workload

In the recorded 16-core Studio integration experiment, the same 26-test parallel client workload changed from 28 completed document parses and 49 completed compilations to one parse and 15 compilations. The old workload failed two tests; the corrected workload passed all 26 in both repetitions. These are historical, workload-specific measurements, not a universal throughput or memory guarantee. The original idle deadline was unchanged.

See ADR-0007 and the commit-bound Core #53 qualification record in the repository for the full evidence and limitations.
