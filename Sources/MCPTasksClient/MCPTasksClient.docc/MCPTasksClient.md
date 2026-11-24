# ``MCPTasksClient``

Consume task-backed tools and task state through a configured MCP client.

## Overview

Declare the Tasks extension in client configuration, and inspect discovery for server support. ``TasksClient`` distinguishes ordinary completed tool results from task outcomes. It can fetch state, answer input, follow subscriptions, poll for completion and explicitly cancel a task.

Polling is bounded by the configured polling interval range. Cancelling a local wait is distinct from sending a task cancellation request; the remote task remains server-owned.

## Topics

- ``TasksClient``
- ``TaskSnapshot``
- ``ToolCallOutcome``
- ``TasksClientError``
