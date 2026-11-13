# Tasks (`MCPTasks`)

`MCPTasks` implements the server side of the official Tasks extension
(`io.modelcontextprotocol/tasks`, revision 2026-07-28; see ADR-0003). A tool call can
return a durable task handle instead of blocking; clients poll `tasks/get`, answer input
requests with `tasks/update` and cancel with `tasks/cancel`.

## Setup

```swift
let tasks = TaskRuntime()                                   // finite in-memory defaults
let report = tasks.tool(definition: reportDefinition) { arguments, task in
    await task.setStatusMessage("Collecting sources")
    let answer = try await task.requestInput(confirmationRequest)   // input_required until tasks/update
    return try buildCallToolResult(arguments, answer)               // CallToolResult, resultType "complete"
}
let server = try await Server.make(info: info,
    catalog: ServerCatalog(tools: [report], extensions: [tasks.registration()]), cursors: cursors)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await tasks.run() }                 // owns all task work
    // … run the transport …
    await tasks.shutdown()                                  // cancels and joins remaining tasks
}
```

## Behavior

- **Negotiation.** A task is created only when the request's client capabilities declare
  the extension. Otherwise a `.required` tool returns `-32021` naming the extension and an
  `.optional` tool runs inline. `tasks/*` from non-declaring clients also return `-32021`.
- **Durability.** The record exists before `CreateTaskResult` is sent, so the next
  `tasks/get` always resolves.
- **Status.** `working` → (`input_required` ↔ `working`)* → `completed` | `failed` |
  `cancelled`. Throw `TaskFailure(code:message:)` for a JSON-RPC error (`failed`); a tool
  result with `isError: true` is `completed`.
- **Input.** `TaskContext.requestInput(_:)` takes an MRTR `InputRequest` and suspends until
  `tasks/update` answers its key. Keys are unique for a task's lifetime; unknown, answered
  or superseded keys are ignored.
- **Cancellation.** `tasks/cancel` reports `cancelled` and cooperatively cancels the work,
  including work waiting for input. `notifications/cancelled` is not used for tasks.
- **Security.** Task IDs are 128-bit CSPRNG values bound to the creating principal
  (issuer, subject, resource). Unknown, expired and other principals' tasks all return
  `-32602`.
- **Bounds.** `TaskRuntimeConfiguration` limits total and per-principal tasks, TTL
  (`ttlMs`), the advertised `pollIntervalMs` and each task's own work budget.
- **Lifetime.** Task work runs as child tasks of `run()`; nothing is detached. `shutdown()`
  or cancelling `run()` cancels remaining work and returns after it joined.

- **Status notifications.** A `subscriptions/listen` request with
  `notifications.taskIds` receives `notifications/tasks`. Only the caller's own live tasks
  are agreed (the acknowledgement lists them); unknown and foreign IDs are dropped
  silently. After the acknowledgement each agreed task's current state is sent, then every
  change. Each notification is the complete `DetailedTask` (result, error or input
  requests inline, no `resultType`); a queued older state of the same task is replaced by
  the newer one. Requesting `taskIds` without declaring the extension returns `-32021`.
  No progress or log notifications are sent for tasks.

## Stores and restarts

The runtime executes work; a `TaskStore` keeps task state (ADR-0004). Every change is a
compare-and-set on the record's `version`, terminal records never change again, and
expired, unknown and foreign records look the same (`nil`, `-32602`).

- `InMemoryTaskStore` (default): process memory, lost on restart.
- `SQLiteTaskStore` (product `MCPTasksSQLite`, on Swift-SQLite 0.1.0): one `STRICT` table
  in a WAL database. `create` and `update` return after a synced `COMMIT`, so a task the
  client has seen survives a crash. Payloads are bounded (`maximumPayloadBytes`, default
  4 MiB); larger writes throw `TaskStoreError.payloadTooLarge`.

```swift
let store = try await SQLiteTaskStore.open(path: tasksDatabasePath)
let tasks = TaskRuntime(store: store)                       // restartPolicy: .failUnfinished
// … after tasks.run() returned:
await store.close()
```

When `run()` starts it applies `TaskRuntimeConfiguration.restartPolicy` to unfinished
stored tasks. `.failUnfinished` (default) marks them `failed` with `-32603` and
`statusMessage: "server restarted"`, because their work did not survive. `.keep` leaves
them alone, for a store shared with instances that still run them.

New backends prove themselves with `TaskStoreConformanceKit` (product `MCPTasksTesting`):
create/duplicate, payload round-trip, owner isolation, compare-and-set races, terminal
immutability, bounded expiry, ordered paging of unfinished tasks and, for durable
stores, reopening.

## Not yet implemented

- Resuming unfinished work from a checkpoint after a restart.
- Shared multi-instance stores with lease-based ownership (Phase D).

## Conformance

Swift-MCP-Server-HTTP validates `Mcp-Name` for `tasks/*` (it must equal `params.taskId`)
and its conformance fixture registers the tools of the official Tasks scenarios. Against
`@modelcontextprotocol/conformance` 0.2.0-alpha.12 all 10 Tasks scenarios pass in
addition to the 37 required ones.
