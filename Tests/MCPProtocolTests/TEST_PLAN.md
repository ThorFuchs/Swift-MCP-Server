# MCPProtocol test plan

Exact IDs/keys/Unicode, presence/null, every definition/content variant, 21 method inventory, mandatory per-request metadata, resultType/cache hints, malformed envelopes/batches/responses and unknown allowed fields.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.
