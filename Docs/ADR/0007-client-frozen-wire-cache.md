# ADR-0007: Share only immutable frozen client wire plans

- Status: **Proposed for review** (2026-11-23)
- Scope: Core #53 / A1.3; internal client preparation, no public API change.

## Context

The A1.2 16-core Studio traces establish that discovery replies arrive before client schema preparation completes. The fixture then reaches its unchanged 30-second read-idle deadline. Each full parallel run performs 28 parses and 49 completed compilations for only 15 distinct frozen definitions. Instance evaluation is separate. The existing server cache is a useful precedent, but its request-owned accounting and admission policy do not belong in the client.

## Decision

- Allow a narrow exception to the no-global-state rule: one process-local actor retaining only immutable Sendable plans and the document of the hash-verified, offline MCP 2026-07-28 schema. Never share application/tool/elicitation schemas, credentials, request values, response data or authorization context. Those remain client/invocation owned.
- The cache prepares one miss synchronously at a time, with no await between miss and publication. No detached tasks, global logging bootstrap, new waiter registry, or application-owned queue. Actor scheduling belongs to the caller's tasks; this does not claim bounded actor mailbox length.
- Bound retained entries independently by 48 definitions and 32 MiB of aggregate upstream reported peak logical retained bytes for the document and retained plans. This is conservative logical accounting, not an RSS guarantee. An entry that cannot fit is compiled, returned and evaluated without retention; existing warm entries are not evicted. Single-flight reuse is conditional on retention. Existing per-operation JSON limits are unchanged.
- A successful parse or compile can safely publish an immutable artifact even if the caller is subsequently cancelled. Failed operations never publish partial plans. Check cancellation before preparation, between stages and before returning/validating; check again after evaluation. No exception or response validity is suppressed.
- Keep evaluation outside the shared actor with the existing fresh `WireDefinitionPlan.validate` implementation. Per-client server-supplied schema caches are unchanged.

## Evidence and consequences

Isolated cache tests check concurrency, count/byte bounds, cancellation, preparation errors and application-schema separation. The A1.2 before/after matrix (unchanged 26-client-test filter) and trace checker must show retained cold-start reuse and green tests on Studio without deadline changes. The new cache tests live in a separately named test target so the original 26-test experimental population stays comparable. Full native CI and HTTP interoperability are still required. A1.4 subprocess exit ownership is independent.
