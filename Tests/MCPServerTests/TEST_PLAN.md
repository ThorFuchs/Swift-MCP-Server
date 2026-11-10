# MCPServer test plan

Registration/catalog replacement, all providers/cache/pagination/completion, extension gates, MRTR modes/retries/state tamper/expiry/replay/claims, subscription acknowledgement/filter/overflow, progress/logging/terminal races, principal isolation and admission/cancellation.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.
