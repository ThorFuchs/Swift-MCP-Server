# Implemented runtime core

Use the public `MCPProtocol`, `MCPServer` and `MCPServerTesting` products. [CoreConsumer](../Tools/CoreConsumer/Sources/CoreConsumer/main.swift) compiles and executes typed-tool, resource, prompt and completion exchanges through these products. The eight-product consumer retains later target guards.

`Server.make(info:catalog:cursors:configuration:)` prepares native frozen wire plans, descriptor schemas, tool input/output schemas and nested header declarations before publishing generation 1. Registration is immutable. `replaceCatalog` prepares one replacement at a time and publishes it atomically; active requests retain their original schema, header plan, handler and output schema across awaits. Exact duplicate names fail; Unicode scalar-distinct names remain distinct. Active/leased plan weights are bounded; one unpublished preparation has its own finite allowance and ceilings.

The host verifies the principal, performs cheap transport admission, supplies keys/clock and owns the dispatch task. `dispatch(_:principal:origin:mirror:send:)` acquires one global permit and a finite buffered-wire reservation, then owns pipeline, deadline and cancellation children in a structured group. Scope rejection throws `CoreFailure.insufficientScopes` for the transport authorization layer. Redacted protocol errors use the frozen codes; tool application `isError` remains a result. Input validation precedes provider and header mapping; invalid or operationally failed output cannot become success. `handle` is a bounded in-process convenience. Caller cancellation and sink failure signal loss. Every callback must cooperate with cancellation; scope exit joins even a callback that ignores it, so there is no hard preemption guarantee.

`cancel(id:principal:origin:)` uses a separate one-active/one-queued control admission path. Host adapters should route already-admitted cancellation notifications there when the provider queue is saturated. Authority binds issuer/subject/resource, origin and exact ID. `stopAdmission` rejects queued/future work; the host must cancel/join active tasks. Complete transport drain and subscription lifetime are later work.

`ServerConfiguration` has finite checked bounds. Balanced request defaults: 32 active, 64 queued, eight active per principal, 64 million cumulative work units, 262144 prepaid terminal work, 1 MiB input, 4 MiB output, 16 MiB aggregate buffered-wire weights, 10000 catalog entries, 100 entries per page (maximum 1000), 120-second deadline. Library numeric/compile/evaluation/regex ceilings remain independent. JSON limits bound separate stage shape/live/logical space; physical RSS and real-time CPU are not measured guarantees. The terminal reserve debits the parent and is never supplied to callbacks or replenished. At most one encoding/write attempt occurs. A failed sink cannot be promised delivery. Escaped request accounts are closed after dispatch, and unsettled tickets prohibit success.

Cancellation records the first authoritative cause. The polling child prepays its finite observation allowance from the request and uses a decreasing local counter; it cannot spend from a closed main account or mask a deadline with budget exhaustion. Cleanup releases occur outside their operation catch regions, so a failed release cannot be retried.

Tool schemas use the existing private adapter and native public JSON reports. Raw arguments retain absent/null/value; typed tools use the bounded native coder. Binary data in declared image/audio/embedded/resource positions requires strict canonical base64. Application structured content and permitted metadata remain exact JSON. Schema invalidity is distinct from compiler/resource/accounting errors. All I/O and host work outside JSON require host-owned finite admission/accounting.

Four lists use authenticated encrypted cursor v1, purpose-separated from MRTR. It binds principal including scopes, method, salient parameters, generation, expiry, epoch and per-server instance. Omitted means first page; empty is invalid. Retaining an old key permits its unexpired tokens only while context/epoch/TTL remain valid; removing it rejects them. Restart changes instance even with identical keys. No replay or protected MRTR claim follows.

RFC 6570 Level 4 `URITemplate` supports simple, reserved, fragment, label, path, path-parameter, query and continuation operators; lists/maps, explode, Unicode scalar prefix, percent-encoded variable names and bounded UTF-8 output. Templates/values have explicit limits; composites with prefix are invalid. The unchanged 270-row public test corpus includes two apostrophe-literal rows that conflict with [RFC 6570 section 2.1](https://www.rfc-editor.org/rfc/rfc6570.html#section-2.1); they execute as expected rejections under that authority. Provenance is retained with the fixtures.

All six complete cacheable methods receive zero/private by default. Explicit host policy may declare a safe TTL/public scope; pages use one coherent generation/policy. Completion clips to 100 and preserves accurate total/hasMore. No result cache is implied.

`InProcessHarness` records bounded ordered exchanges through the real dispatcher; recording exhaustion throws, including after provider execution. `ManualClock` rejects backwards/overflowing advances. Helpers install no signals, credentials, logging or metrics backends. They do not qualify real I/O, MRTR state or the official referee.

Real transports may call Server.inspectIngress and dispatch the returned
AdmittedIngress through the event API. It is a single-use, server-bound token with
the original parsed value, cumulative RequestBudget, disjoint prepaid terminal
reserve, principal/origin and absolute deadline. Dropping an accepted queued token
requires discard; another server, a repeated dispatch or a discarded token cannot
execute it. Inspection has independent bounded control admission. Transport queues
must reserve the token's reported logical retainedBytes and own their own finite
I/O/admission bounds. MCPStdio implements this contract and does not reset work
between classification, validation and provider execution. Exact request-ID
correlation can cancel current queued/active work; it is not a canonical hash,
MRTR authorization or memoized cancellation of a future reused ID.
