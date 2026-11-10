# Frozen wire contract

Authority: Reference/Protocol/schema/2026-07-28/schema.ts and schema.json at
c518f7a927cff918bce35d3522fcdb046d264d7c, plus the dated specification text in that snapshot.
The observed 2026-07-28 tag points to 5f5440bb26a62e2cf3440b92da5a667efa03b267; retain the approved
dated snapshot rather than silently changing it to a newer main/tag. All 155 definitions need coverage.

Every request supplies `_meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"` and
`_meta["io.modelcontextprotocol/clientCapabilities"]`; clientInfo is optional self-reporting.
`server/discover` is the discovery request. A client may issue configured operations without discovery.
Capabilities/settings are evaluated for each request and retry; no session-wide authority is created.

Incoming request IDs are strings or exact mathematical integers, not null or fractional numbers. Scalar
equality matters for strings and object keys. Malformed/unidentifiable envelope errors use the JSON-RPC
unknown-ID null convention as the explicit interpretation in DECISIONS; never fabricate ID zero.
Reject batches and incoming client response envelopes. Preserve permitted unknown extension/metadata
fields and reject malformed defined fields. Notification handling follows its defined no-response rules.

Successful results carry `resultType: "complete"`. Multi-round intermediate results carry
`resultType: "input_required"`; extra result types require a negotiated extension. Complete results
from server/discover, tools/list, prompts/list, resources/list, resources/templates/list and resources/read
include `ttlMs` and `cacheScope`. Conservative unspecified host caching defaults to 0/private.
Pagination applies to the four list methods: omitted, null (if forbidden) and empty cursors are distinct;
page cacheScope must remain consistent. Completion cannot exceed its normative maximum of 100 values.

Contracts/method-registry.json enumerates 21 frozen entries. Ten inbound requests, three MRTR inputs and
eight server notifications are the exact inventory. Cancellation notifications are bidirectional where
permitted, with no independent JSON-RPC server requests. No initialize/initialized/ping/logging-setLevel,
resources/subscribe/unsubscribe, old sessions or historical method aliases are implemented.

Error handling distinguishes parse/envelope, unknown method, version/capability, schema, resource missing,
authorization, policy limit, handler and cancellation failures. Use literal error codes and data forms
from the frozen schema/text. HTTP admission errors and tool `isError` content are different layers.
HTTP error status/body/challenge rules need independent wire tests. Never expose host secrets in errors.

See Contracts/wire-coverage.json for one entry per schema definition, initially unresolved. Populate
actual model/projection paths and positive/negative test links; no definition is complete solely because
a generic JSON enum can hold it. Include images/audio/embedded resource/resource links, structured tool
content, annotations, completions, roots, URL/form elicitation and modern sampling content variants.
