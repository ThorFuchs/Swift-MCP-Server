# ``MCPTasks``

Run task-backed MCP tools with bounded ownership, explicit input requests and durable state contracts.

## Overview

The task runtime owns admitted jobs within its host-controlled run lifetime. A task is associated with an issuer, subject and resource; the same owner is required for later access. Terminal states are final. The runtime supports polling, input requests, cancellation and restart policy.

Choose a ``TaskStore`` appropriate for the application. The in-memory backend is not durable. The separate MCPTasksSQLite product supplies durable SQLite storage. Persisted state does not by itself guarantee exactly-once execution of external effects.

## Topics

- ``TaskRuntime``
- ``TaskRuntimeConfiguration``
- ``TaskContext``
- ``TaskStore``
- ``InMemoryTaskStore``
- ``TaskRecord``
- ``TaskOwner``
- ``TaskStatus``
- ``TaskRestartPolicy``
- ``TaskMode``
