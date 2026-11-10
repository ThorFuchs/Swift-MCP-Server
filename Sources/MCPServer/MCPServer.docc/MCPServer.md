# ``MCPServer``

Run a server-only MCP 2026-07-28 core with bounded ownership and immutable catalogs.

Create ``Server`` with host identity, ``ServerCatalog`` and ``CursorProtector`` keys.
``ToolRegistration`` supports typed complete providers; resources, templates, prompts
and completion use the same coherent generation. Admitted requests retain their
catalog through validation, header callbacks and output encoding. ``RequestBudget``
owns finite cumulative work, subsystem ceilings and terminal behavior after failure.

``MultiRoundProvider`` explicitly returns complete or input-required outcomes.
``RequestStateProtector`` authenticates purpose-separated state with a host namespace,
epoch and clock. Integrity protection does not promise one-use or exactly-once effects;
the host supplies its replay/effect policy and atomic consumption where required.

The core owns response attempts, admission permits and bounded event writers. Hosts
supply verified principals and own transport/task lifetimes. Optional protocol logging
is disabled by default. JSON and JSON Schema stay in Swift-JSON behind the private
adapter; no network schema resolver or helper allowance reset is provided.

The eight-product consumer uses typed registration, input/output validation and an
instrumented core across in-process, stdio and TLS HTTP. It checks graceful shutdown,
parent cancellation and zero remaining activity. Public package availability remains
separate from these native behaviors.

## Topics

### Runtime and catalogs
- ``Server``
- ``ServerCatalog``
- ``ToolRegistration``
- ``RequestContext``
- ``RequestBudget``

### Protected continuation
- ``MultiRoundProvider``
- ``RequestStateProtector``
- ``CursorProtector``


## Middleware and supplemental routes

Register ``RequestMiddleware`` with `Server.make(middleware:)`. Call
``MiddlewareContinuation/proceed(for:)`` with the supplied ``MiddlewareRequest`` or return
``MiddlewareDecision/reject(_:)``. Admission callbacks join before provider execution;
completion callbacks run in reverse order. Retained, duplicate or foreign continuations
cannot execute providers. ``RequestContext`` retains checked authority/generation/budget.

``ExtensionRegistration`` prepares immutable offline schemas. Only current advertised
namespace/settings activate ``ExtensionRequest``, ``ExtensionInput``, ``ExtensionResult``
and ``ExtensionNotification`` forms. ``RequestMethod`` separates frozen core methods and
supplemental routes. Explicit multi-round providers bind declared plans and current settings;
ordinary custom handlers do not inherit MRTR privileges. Notify through the owned context.

``ResourceProfile`` supplies finite coupled runtime policies; I/O and credentials remain
host-owned. The actual AcceptanceConsumer and standalone examples compile the public APIs.

## Provisional typed providers and trace context

ResourceProvider.typed, ResourceTemplateProvider.typed and PromptProvider.typed
use explicit host definitions and the same per-request Swift-JSON coder budget.
Their encoded complete result still passes ordinary wire validation. Typed prompt
arguments decode omitted input from an empty object and preserve explicit null.
Multi-round behavior remains available through the existing rounds initializers.

RequestContext.traceContext exposes validated traceparent, tracestate and baggage
as caller-provided diagnostic data. It is not identity or authorization, is not
automatically logged and can contain private information. The host decides whether
to pass it to tracing. APIs remain provisional until external consumers compile.
