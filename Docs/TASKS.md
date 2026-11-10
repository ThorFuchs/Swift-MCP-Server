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

## Not yet implemented

- `notifications/tasks` over `subscriptions/listen` (optional in the specification).
- `Mcp-Name` validation for `tasks/*` in Swift-MCP-Server-HTTP.
- Pluggable durable stores; the runtime keeps tasks in memory.
- Official conformance fixture tools for the 10 Tasks scenarios.
