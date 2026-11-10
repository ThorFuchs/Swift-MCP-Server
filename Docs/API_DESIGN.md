# API design brief

Proposed names are design starting points, not implemented signatures. P00/P03 must compile a small
independent consumer and review discover/register/call/cancel/shutdown ergonomics before freezing them.

- `MCPServer`: immutable configuration plus a lifecycle-controlled actor/runtime. Registration produces
  catalog generations; convenience builders validate schemas and duplicate names at registration time.
- `RequestContext`: request ID/method, protocol version, client capabilities, negotiated extension settings,
  deadline/cancellation, verified optional principal and correlation-aware emission. Self-reported client
  info and opaque metadata are explicitly separate from authenticated principal.
- Tool/provider inputs use Swift-JSON `JSON`, presence and exact scalar names; typed convenience adapters
  may use its native coder with strict limits and clear schema ownership. Avoid Foundation JSONSerialization
  and lossy Double/Dictionary conversions. Tools return complete or input-required outcomes; application
  failures use tool-result error content when appropriate, not an invented JSON-RPC error for every failure.
- Resource/prompt/completion providers accept bounded input and return typed modern content forms.
  Host-supplied pagination/cache decisions stay independent of transport. Support unknown allowed fields.
- Request-state key, clock and atomic consumption providers are injected. Model integrity and replay policy
  separately. Subscription event publication declares loss/coalescing behavior and a bounded subscriber queue.
- Extension descriptors own namespace, capability/settings schema and additional wire forms. Validation and
  dispatch only activate descriptors negotiated for the current request. No global permission via metadata.
- Transport initialization requires bind/authority/authorization and ownership configuration. Standalone
  convenience construction is explicit about loopback development, stdout ownership and signal handling.

Value types should conform to Sendable with compiler proof. Use typed errors distinguishing malformed wire,
schema failure, capability rejection, limits, cancellation and host failures. Error details are bounded and
redact sensitive data. Do not expose internal plan representation or general JSON helpers as MCP API.
Avoid overload families that make absent/null interchangeable. Documentation examples must compile.
Public testing helpers record ordered exchanges without storing bearer tokens or unbounded payloads.

## Acceptance v0.6 additions

The eight product boundaries are unchanged. MCPServer now exposes RequestMiddleware,
MiddlewareRequest/Decision/Continuation/Outcome, RequestMethod, supplemental declarations
and ResourceProfile. Private compiled schema plans, terminal permits and dispatch ownership
remain private. Middleware is ordered provider admission: callbacks join before the owned
provider starts; completion callbacks run in reverse order. Rejection is explicit. No
continuation executes a provider directly, replaces identity/generation, or supplies raw
wire output. Duplicate, foreign, missing, escaped and swallowed failed admission reject.
Completion observes provider return, not successful subsequent validation/delivery.
Built-in catalog listing does not invoke provider middleware. See EXTENSIONS and LIMITS.

`ResourceProfile` configures coupled server/events/continuation/32-byte consumption-store
policies. Transport/schema/cursor policies remain independently owned and explicitly
configured. Zero is invalid. A maximum byte count is not a promise of success when other
work/terminal/buffer limits are smaller. Claims, deadlines and shutdown remain cooperative.
The examples are actual standalone signal-owning executables; reusable products do not
install signals, own credentials, or bootstrap logging/metrics.
