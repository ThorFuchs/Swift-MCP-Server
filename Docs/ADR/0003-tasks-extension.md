# ADR-0003: Server-side Tasks extension (`MCPTasks`)

- Status: **Proposed** (2026-11-10)
- Spec: [`io.modelcontextprotocol/tasks`](https://github.com/modelcontextprotocol/ext-tasks)
  (SEP-2663), revision 2026-07-28. A `draft` revision exists, so details may still change.

## Context

Tasks let a server answer a `tools/call` with a durable task handle instead of blocking,
so clients poll (`tasks/get`), answer input requests (`tasks/update`) and cancel
(`tasks/cancel`). Long-running work, human approval and unreliable connections are the
target cases.

State of the official SDKs (checked 2026-11-10):

- **TypeScript**: the server routes `tasks/get` / `tasks/cancel` to handlers the
  application registers itself and validates `Mcp-Name`; `@modelcontextprotocol/ext-tasks`
  0.2.3 is almost entirely client-side. No server task runtime.
- **Python** v2: states that it does not implement the extension yet; the v1 experimental
  runtime was removed.
- The conformance reference server implements no Tasks; the 10 Tasks scenarios
  (about 30 server-side SEP-2663 checks) are unscored for 2026-07-28.

Our extension framework (`ExtensionRegistration`) only admits namespaced forms
(`<namespace>/...`). Tasks instead uses **reserved core names** (`tasks/get|update|cancel`,
`notifications/tasks`, `resultType: "task"`) and makes `tools/call` **polymorphic**, so it
cannot be expressed as an ordinary supplemental extension.

## Decision

Build an opt-in **`MCPTasks`** product (0.x, released after core 1.0) on a few explicit
core hooks.

### Core hooks (MCPServer)

1. **Polymorphic tool results.** A tool may return a task handle. The dispatcher emits
   `CreateTaskResult` (`resultType: "task"`) only when the request's per-request client
   capabilities include the extension; otherwise a task-only tool fails with `-32021` and
   `data.requiredCapabilities.extensions["io.modelcontextprotocol/tasks"]`.
2. **Reserved routing.** `tasks/get`, `tasks/update` and `tasks/cancel` route to a
   registered task service when negotiated; otherwise `-32021`. `tasks/result` and other
   removed methods stay method-not-found.
3. **Frozen schema.** The Tasks definitions from `ext-tasks` (2026-07-28) become an
   additional immutable reference with provenance, prepared like the core schema.
4. **Discovery and subscriptions.** `server/discover` advertises the extension;
   `subscriptions/listen` accepts `taskIds` and carries `notifications/tasks` with a full
   `DetailedTask`; no progress or log messages on a task stream.
5. **HTTP** (Swift-MCP-Server-HTTP): `Mcp-Name` must equal `params.taskId` for `tasks/*`.

### `MCPTasks` runtime

- **`TaskStore` protocol** with a bounded in-memory default (actor; TTL, per-principal and
  total capacity, result-size cap, expiry). Durable stores (SQLite, SwiftData, …) are
  host-provided. `CreateTaskResult` is sent only after `create()` returns, which satisfies
  "durably created before reply" by construction.
- **`TaskRuntime`** is a lifecycle service owning one task group: every task is a child
  task (no detached tasks); `tasks/cancel` cancels cooperatively; shutdown joins all work.
- **`TaskContext`** (via `@TaskLocal`) gives tool code `statusMessage`, `requestInput`
  (MRTR `InputRequest` types; suspends until `tasks/update` delivers the answer) and
  cancellation. Input keys come from a per-task monotonic counter, so they are unique for
  the task's lifetime; unknown or answered keys are ignored as the spec requires.
- **Outcome mapping** with typed throws: JSON-RPC errors → `failed` (with `error` and a
  `statusMessage`); tool results including `isError: true` → `completed`.
- **Security**: task IDs are 128-bit CSPRNG values; every task is bound to its
  `VerifiedPrincipal`, and any other principal gets `-32602` (indistinguishable from an
  unknown ID). Input requests keep the elicitation/sampling trust model.
- **Swift 6.4**: a `~Copyable` completion token makes "complete exactly once" a compile-time
  guarantee; `sending` and actor isolation for result hand-off; `AsyncStream.makeStream`
  for status notifications; injectable `Clock` for TTL and `pollIntervalMs` in tests.

### Acceptance

- All 10 Tasks scenarios of the official referee pass with conformance fixture tools
  (`slow_compute`, `confirm_delete`, `failing_job`, `protocol_error_job`, `multi_input`, …).
- Swift Testing coverage for create/poll/update/cancel races, cancellation during input,
  TTL expiry, key uniqueness, principal isolation and shutdown joins.

## Estimate

| Work | Days |
|---|---|
| Core hooks (result, routing, schema, discover, subscriptions) | 3–4 |
| `MCPTasks` store, state machine, runtime, input, cancel, TTL, notifications | 4–6 |
| Race, cancellation, expiry and isolation tests | ~3 |
| HTTP `Mcp-Name` for `tasks/*` | ½ |
| Conformance fixture tools and run | 1–2 |
| Docs, DocC, Explorer example task | 1 |
| **Total** | **~2.5–3.5 weeks** |

## Consequences

- First server-side Tasks runtime among the official-language SDKs; differentiates the
  package for long-running and approval workflows.
- The core gains a small, explicit special case for reserved Tasks names instead of
  widening the generic extension framework.
- Spec churn risk is contained by shipping `MCPTasks` separately as 0.x and pinning the
  referee version used for acceptance.
