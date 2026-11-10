# ``MCPServiceLifecycle``

Own a finite dependency graph of provider and transport lifetimes.

``TransportService`` declares dependencies, readiness, shutdown and optional force-close
callbacks. ``ServerService`` admits at most64components, validates the graph and starts
dependants only after their dependencies report readiness. ``RuntimeReadiness`` is a
read-only view; listener binding alone is not whole-runtime readiness.

``DrainCoordinator`` supplies one absolute monotonic deadline across admission stop,
reverse shutdown and completion. Escalation closes only explicitly owned I/O and cancels
the child, then joins it. Uncooperative host callbacks remain owned and can delay return;
the library does not claim preemption. Shared-core hosts choose a connection-specific
admission stop seam; the core-owning convenience stops the supplied core.

``EmbeddedServerGroup`` privately configures ServiceLifecycle with no installed Unix
signals or maximum-cancellation timer. The host owns run and requests shutdown.
The full consumer binds real stdio and TLS HTTP components, checks two joined children
and verifies zero activity under graceful shutdown and parent cancellation.
Standalone signal examples and measured resource qualification remain separate work.

## Topics

### Runtime ownership
- ``ServerService``
- ``TransportService``
- ``RuntimeReadiness``
- ``DrainCoordinator``
- ``EmbeddedServerGroup``
