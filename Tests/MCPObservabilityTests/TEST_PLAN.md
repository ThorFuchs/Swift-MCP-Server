# MCPObservability test plan

No global bootstrap, bounded metric labels, correct request context isolation, cancellation context, default redaction across failure paths and distinction from protocol logging.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.

InstrumentationTests.swift implements11 native functions using captured real
LogHandler/MetricsFactory outputs: inherited secret/context redaction, concurrent
structured principal/correlation isolation, cancellation/live close/capacity,
all665 fixed instruments/exact destruction, admitted method/typed error/gauges,
missing/repeated/swallowed/retained facade callbacks, provider payload/terminal
budget privacy, foreign-owner admission isolation, repeated ARC destruction and disabled defaults. Captures are local
Sendable Mutex values; no process-global bootstrap, exporter or tracing system.
