# ``MCPClient``

Discover and call MCP servers using revision 2026-07-28 with typed results and structured concurrency.

## Overview

Create a ``Client`` with a host-supplied ``ClientTransport`` and ``ClientConfiguration``. The client does not own connection tasks, credentials or a session. Every request carries the dated protocol and capability metadata. The transport owns delivery; the client owns protocol interpretation.

Use discovery to inspect the server's capabilities before invoking optional functionality. Tools, resources, resource templates and prompts are available as typed pages that preserve their raw JSON. Pass opaque cursor values unchanged; pages do not promise a server snapshot across requests.

Standard responses and supported notifications are validated against the frozen schema. Multi-round input requests are answered through explicitly configured host handlers. Application-specific extension results need the corresponding extension consumer's validation. A server-provided schema is never fetched over the network.

## Topics

### Client and configuration

- ``Client``
- ``ClientConfiguration``
- ``ClientTransport``
- ``OutgoingRequest``
- ``ClientError``

### Discovery, tools and resources

- ``ServerDescription``
- ``Page``
- ``Tool``
- ``ToolResult``
- ``Resource``
- ``ResourceTemplate``
- ``ResourceContents``
- ``Prompt``
- ``PromptResult``
- ``Completion``
- ``Content``

### Host input and events

- ``ElicitationRequest``
- ``ElicitationResponse``
- ``SamplingRequest``
- ``SamplingResponse``
- ``Root``
- ``SubscriptionFilter``
- ``ListenEvent``
- ``Progress``
- ``LogMessage``

### Routing and validation

- ``ToolHeaders``
- ``RejectedTool``
- <doc:FrozenWireValidation>
