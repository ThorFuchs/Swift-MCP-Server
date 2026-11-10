# Tasks roadmap: full conformance and durable stores

Status: plan (2026-11-10). Builds on ADR-0003 and stage 1 (`MCPTasks`, PR #6).
Store protocol and backends: ADR-0004.

## 1. Where we are

Stage 1 implements negotiation, task-backed tools, `tasks/get|update|cancel`, input
requests, cancellation, TTL, capacity and principal binding, with 10 unit tests. Nothing
has been run against the official referee yet, and tasks live in memory only.

## 2. The 10 official Tasks scenarios (referee `0.2.0-alpha.12`, server leg over HTTP)

| # | Scenario | What it requires | Status | Work |
|---|---|---|---|---|
| 1 | `tasks-lifecycle` | `greet` (sync), `slow_compute`, `failing_job` (tool error → `completed`), `protocol_error_job` (→ `failed`); `resultType: "task"`; working/completed/failed; cancel ack | Runtime ✅ | Fixture tools |
| 2 | `tasks-capability-negotiation` | Extension advertised in `server/discover`; task surface gated per request (SEP-2575 per-request opt-in) | ✅ (unit-tested) | Fixture |
| 3 | `tasks-wire-fields` | `ttlMs`, `pollIntervalMs`; no expiry before TTL; no v1 `related-task` `_meta` on the inlined result | ✅ likely | Verify |
| 4 | `tasks-request-state-removal` | No `requestState` on `CreateTaskResult` or `DetailedTask` | ✅ | Verify |
| 5 | `tasks-mrtr-input` | `confirm_delete` (one elicitation), `multi_input` (two **parallel** requests, partial answers keep `input_required`) | Runtime ✅ (parallel keys untested) | Fixture + test |
| 6 | `tasks-request-headers` | HTTP: `Mcp-Name` must equal `params.taskId` on `tasks/*`; mismatch → 400 / `-32020` | ❌ | Core header declaration for reserved requests + HTTP validation |
| 7 | `tasks-dispatch-and-envelope` | `tasks/result`, `tasks/list` → `-32601`; legacy v1 `task` param ignored; durable create; unknown ID → `-32602`; `resultType: "complete"` everywhere | ✅ mostly (`task` param: schema allows extra fields; verify) | Verify |
| 8 | `tasks-status-notifications` | **Skipped by the referee** (pending `subscriptions/listen` rewrite) | n/a (reported 0/0) | Phase B for the spec |
| 9 | `tasks-required-task-error` | `-32021` with `data.requiredCapabilities.extensions["io.modelcontextprotocol/tasks"]` | ✅ (unit-tested) | Fixture |
| 10 | `tasks-mrtr-composition` | `test_tool_with_task`: MRTR rounds on `tools/call`, final round returns `CreateTaskResult`; task result reflects the gathered answer | ❌ | MRTR → task bridge |

Spec items beyond the referee (from `ext-tasks` 2026-07-28):

- Work results must be valid `CallToolResult`s and match the tool's `outputSchema`
  (stage 1 only checks `resultType`).
- `notifications/tasks` over `subscriptions/listen` with `taskIds`; `-32021` for
  non-declaring listeners; no `notifications/progress` or `notifications/message` on a
  task stream.
- `tasks/update` and `tasks/cancel` SHOULD reject unknown IDs (done); `tasks/get` MUST (done).

## 3. Phases

### Phase A: 10/10 official scenarios (about 4–5 days)

1. **Conformance fixture** (Swift-MCP-Server-HTTP `Tools/Conformance/SwiftFixture`): register
   `TaskRuntime`, run it as a service, and add `slow_compute(seconds,label)`,
   `failing_job`, `protocol_error_job`, `confirm_delete`, `multi_input`,
   `test_tool_with_task`. Baseline referee run. *1 day*
2. **MRTR → task composition:** let an MRTR provider's final round hand off to the
   runtime (`TaskRuntime.multiRoundTool`), carrying the gathered answers into the task.
   *1 day*
3. **Routing header:** reserved requests declare `Mcp-Name ← taskId`; Swift-MCP-Server-HTTP
   validates it like `tools/call`. *½–1 day*
4. **Result validation:** validate work results against `CallToolResult` and the tool's
   `outputSchema` before `completed`; invalid output → `failed` (`-32603`). Verify the
   legacy `task` param and the absence of `related-task` / `requestState`. *½–1 day*
5. **Fix-ups from the referee run; make the Tasks scenarios part of the HTTP CI gate.**
   *½–1 day*

Exit: referee 37/37 required **and** 10/10 Tasks scenarios green in CI.

### Phase B: full specification (about 2 days)

- `notifications/tasks` via `subscriptions/listen` (`taskIds` filter, full `DetailedTask`
  per notification, `-32021` for non-declaring listeners, no progress or log frames).
- Typed completion: a `~Copyable` completion token so "complete exactly once" is enforced
  by the compiler; typed throws for `TaskFailure`.
- DocC article and an Explorer example (a long "research report" task).

### Phase C: durable stores (about 5–7 days), see ADR-0004

1. `TaskStore` protocol plus `InMemoryTaskStore`, and a reusable **store conformance test
   kit** that every backend must pass. *1½ days*
2. `MCPTasksSQLite`: WAL, `STRICT` tables, versioned migrations, optimistic versioning,
   crash recovery policy; macOS, iOS and Linux CI. *2–3 days*
3. Restart semantics: non-terminal tasks after a restart become `failed` ("server
   restarted"), unless the tool registered a resumer with a checkpoint. *1 day*

### Phase D: shared and remote stores (experimental, about 5–8 days)

- **libSQL / Turso** remote adapter over HTTP (no native Swift binding exists): one task
  space for several server instances, with lease-based ownership and cross-instance
  cancellation through the store.
- PostgreSQL adapter (PostgresNIO) as a separate package for conventional deployments.

### Phase E: process-backed tasks (optional, 1–2 days)

`MCPTasksProcess` on `swift-subprocess`: run an external program as a task; `tasks/cancel`
→ SIGTERM → SIGKILL; bounded output; exit code → `completed` / `failed`. Not on iOS.

## 4. Order and estimate

| Phase | Days | Depends on |
|---|---|---|
| A: 10/10 scenarios | 4–5 | PR #6 merged |
| B: full spec | ~2 | A |
| C: durable stores (SQLite) | 5–7 | A (protocol can start in parallel) |
| D: shared/remote stores | 5–8 | C |
| E: process tasks | 1–2 | A |

A + B + C, the "complete and durable" milestone, is about **2–2½ weeks**.
