# ``MCPServerTesting``

Observe production in-process exchanges with explicit finite test resources.

``InProcessHarness`` uses the real dispatcher and records ordered requests/responses in
``RecordedExchange`` values. Count and retained-byte ceilings are independent of server
work; exhausted recording fails even when a provider produced a response. It owns no
credentials, global clock or server task. ``ManualClock`` is an explicit monotonic test
input for host-owned cursor/state policies. ``EventCollector`` bounds event observations.

In-process delivery ordering cannot qualify real sockets or pipes. The full consumer
uses a single recorded exact-ID exchange, then exercises the same core through actual
stdio and TLS HTTP with lifecycle ownership. Native transport and referee evidence
remain separate from simulated event-mode checks.

## Topics

### Bounded observations
- ``InProcessHarness``
- ``RecordedExchange``
- ``ManualClock``
- ``EventCollector``
