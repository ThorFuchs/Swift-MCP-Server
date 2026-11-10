# MCPStdio test plan

Owned subprocess fragmented/coalesced lines, strict UTF-8, limits, partial I/O/EINTR/EOF/EPIPE, stalled sinks, descriptor ownership, protocol-only stdout and graceful/forced drain.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.

Implemented native cases are in SubprocessTests.swift and
TransportOwnershipTests.swift. PrimitiveTests.swift remains unchanged.
Subprocess tests require the actual MCP_STDIO_FIXTURE executable path; the probe
records its digest. The default-backend outside-root fixture is the public-product
consumer, while the native Testing backend stages only generated resources.
No portable result counts as a native transport test. Actual case counts and
source/input identities are recorded separately in Docs/Evidence/Stdio.
