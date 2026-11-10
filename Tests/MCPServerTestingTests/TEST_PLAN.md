# MCPServerTesting test plan

Deterministic manual clock behavior, ordered bounded recordings, fake atomic-state semantics, harness cancellation/terminal ownership, and tests that expose production errors rather than masking them.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.
