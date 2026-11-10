// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPTasks

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let alice = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private let bob = VerifiedPrincipal(subject: ScalarText("bob"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private let extensionID = "io.modelcontextprotocol/tasks"

private func request(_ method: String, id: Int, fields: String, tasks: Bool = true) -> Data {
    let capabilities = tasks ? #"{"extensions":{"io.modelcontextprotocol/tasks":{}}}"# : "{}"
    return Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(capabilities)}\(fields)}}".utf8)
}
private func call(_ tool: String, id: Int, arguments: String = "{}", tasks: Bool = true) -> Data {
    request("tools/call", id: id, fields: ", \"name\":\"\(tool)\", \"arguments\":\(arguments)", tasks: tasks)
}
private func taskRequest(_ method: String, id: Int, taskID: String, extra: String = "", tasks: Bool = true) -> Data {
    request(method, id: id, fields: ", \"taskId\":\"\(taskID)\"\(extra)", tasks: tasks)
}
private func respond(_ server: Server, _ data: Data, as principal: VerifiedPrincipal = alice) async throws -> JSON {
    try json(String(decoding: #require(await server.handle(data, principal: principal, origin: ScalarText("host"))), as: UTF8.self))
}
private func code(_ value: JSON) -> Int? { try? value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) }
private func result(_ value: JSON) -> JSONObject? { value.objectValue?["result"]?.objectValue }
private func status(_ value: JSON) -> String? { result(value)?["status"]?.stringValue }
private func toolDefinition(_ name: String) throws -> JSON { try json("{\"name\":\"\(name)\",\"inputSchema\":{\"type\":\"object\"}}") }
private func text(_ value: String) throws -> JSON {
    try json("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"\(value)\"}]}")
}

private func makeServer(_ runtime: TaskRuntime, tools: [ToolRegistration]) async throws -> Server {
    try await Server.make(info: json(#"{"name":"tasks","version":"1"}"#),
        catalog: ServerCatalog(tools: tools, extensions: [runtime.registration()]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
}

/// Runs the runtime as a child task for the body's duration, then shuts it down and joins it.
private func withRuntime(_ runtime: TaskRuntime, _ body: () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await runtime.run() }
        while !(await runtime.isRunning) { await Task.yield() }
        do { try await body() } catch { await runtime.shutdown(); throw error }
        await runtime.shutdown()
        try await group.waitForAll()
    }
}

private func waitForStatus(_ server: Server, _ taskID: String, _ expected: String, as principal: VerifiedPrincipal = alice) async throws -> JSON {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    var id = 1000
    while true {
        id += 1
        let response = try await respond(server, taskRequest("tasks/get", id: id, taskID: taskID), as: principal)
        if status(response) == expected { return response }
        guard ContinuousClock.now < end else { Issue.record("task did not reach \(expected): \(String(describing: status(response)))"); return response }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func createdTaskID(_ response: JSON) throws -> String {
    let created = try #require(result(response))
    #expect(created["resultType"]?.stringValue == "task")
    return try #require(created["task"]?.objectValue?["taskId"]?.stringValue)
}

@Suite(.serialized) struct TaskRuntimeCases {
    @Test func createdTaskIsImmediatelyPollableAndCompletesWithTheToolResult() async throws {
        let runtime = TaskRuntime()
        let release = Mutex(false)
        let tool = runtime.tool(definition: try toolDefinition("slow")) { _, context in
            await context.setStatusMessage("working on it")
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            return try text("done")
        }
        let server = try await makeServer(runtime, tools: [tool])
        try await withRuntime(runtime) {
            let created = try await respond(server, call("slow", id: 1))
            let taskID = try createdTaskID(created)
            #expect(taskID.count == 32)
            let task = try #require(result(created)?["task"]?.objectValue)
            #expect(task["status"]?.stringValue == "working" && task["ttlMs"] != nil && task["pollIntervalMs"] != nil)
            // Durable before reply: the very next tasks/get resolves.
            let working = try await respond(server, taskRequest("tasks/get", id: 2, taskID: taskID))
            #expect(status(working) == "working" && result(working)?["resultType"]?.stringValue == "complete")
            release.withLock { $0 = true }
            let completed = try await waitForStatus(server, taskID, "completed")
            let content = result(completed)?["result"]?.objectValue?["content"]?.arrayValue
            #expect(content?.first?.objectValue?["text"]?.stringValue == "done")
            #expect(result(completed)?["statusMessage"]?.stringValue == "working on it")
        }
    }

    @Test func nonDeclaringClientsGetMissingCapabilityForTaskToolsAndTaskMethods() async throws {
        let runtime = TaskRuntime()
        let server = try await makeServer(runtime, tools: [runtime.tool(definition: try toolDefinition("job")) { _, _ in try text("x") }])
        try await withRuntime(runtime) {
            for response in [try await respond(server, call("job", id: 1, tasks: false)),
                             try await respond(server, taskRequest("tasks/get", id: 2, taskID: "any", tasks: false)),
                             try await respond(server, taskRequest("tasks/cancel", id: 3, taskID: "any", tasks: false))] {
                #expect(code(response) == -32021)
                let required = response.objectValue?["error"]?.objectValue?["data"]?.objectValue?["requiredCapabilities"]?.objectValue
                #expect(required?["extensions"]?.objectValue?[extensionID] != nil)
            }
            // A removed 2025-11-25 method stays method-not-found.
            #expect(code(try await respond(server, taskRequest("tasks/result", id: 4, taskID: "any"))) == -32601)
        }
    }

    @Test func optionalToolsRunInlineForNonDeclaringClientsAndAsTasksOtherwise() async throws {
        let runtime = TaskRuntime()
        let tool = runtime.tool(definition: try toolDefinition("either"), mode: .optional) { _, context in
            try text(context.taskID == nil ? "inline" : "task")
        }
        let server = try await makeServer(runtime, tools: [tool])
        try await withRuntime(runtime) {
            let inline = try await respond(server, call("either", id: 1, tasks: false))
            #expect(result(inline)?["resultType"]?.stringValue == "complete")
            #expect(result(inline)?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "inline")
            let taskID = try createdTaskID(try await respond(server, call("either", id: 2)))
            let completed = try await waitForStatus(server, taskID, "completed")
            #expect(result(completed)?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "task")
        }
    }

    @Test func unknownAndForeignTaskIdentifiersAreIndistinguishableInvalidParams() async throws {
        let runtime = TaskRuntime()
        let server = try await makeServer(runtime, tools: [runtime.tool(definition: try toolDefinition("job")) { _, _ in try text("x") }])
        try await withRuntime(runtime) {
            let taskID = try createdTaskID(try await respond(server, call("job", id: 1)))
            _ = try await waitForStatus(server, taskID, "completed")
            for method in ["tasks/get", "tasks/cancel"] {
                #expect(code(try await respond(server, taskRequest(method, id: 2, taskID: "nonexistent-12345"))) == -32602)
                #expect(code(try await respond(server, taskRequest(method, id: 3, taskID: taskID), as: bob)) == -32602)
            }
            #expect(code(try await respond(server, taskRequest("tasks/update", id: 4, taskID: taskID, extra: #", "inputResponses":{}"#), as: bob)) == -32602)
        }
    }

    @Test func inputRequestsSuspendUntilUpdateAndKeysAreNeverReused() async throws {
        let runtime = TaskRuntime()
        let tool = runtime.tool(definition: try toolDefinition("confirm")) { _, context in
            let request = try json(#"{"method":"elicitation/create","params":{"mode":"form","message":"Delete?","requestedSchema":{"type":"object","properties":{}}}}"#)
            let first = try await context.requestInput(request)
            let second = try await context.requestInput(request)
            let answers = [first, second].compactMap { $0.objectValue?["action"]?.stringValue }.joined(separator: ",")
            return try text(answers)
        }
        let server = try await makeServer(runtime, tools: [tool])
        try await withRuntime(runtime) {
            let taskID = try createdTaskID(try await respond(server, call("confirm", id: 1)))
            let waiting = try await waitForStatus(server, taskID, "input_required")
            let firstKey = try #require(result(waiting)?["inputRequests"]?.objectValue?.first?.key.string)
            // Unknown keys are ignored; the acknowledgement is still an empty complete result.
            let ignored = try await respond(server, taskRequest("tasks/update", id: 2, taskID: taskID, extra: #", "inputResponses":{"bogus":{"action":"accept"}}"#))
            #expect(result(ignored)?["resultType"]?.stringValue == "complete")
            #expect(status(try await respond(server, taskRequest("tasks/get", id: 3, taskID: taskID))) == "input_required")
            _ = try await respond(server, taskRequest("tasks/update", id: 4, taskID: taskID, extra: ", \"inputResponses\":{\"\(firstKey)\":{\"action\":\"accept\"}}"))
            // The second request gets a fresh key once the first answer was delivered.
            var secondKey = firstKey
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while secondKey == firstKey, ContinuousClock.now < end {
                let response = try await respond(server, taskRequest("tasks/get", id: 5, taskID: taskID))
                if let key = result(response)?["inputRequests"]?.objectValue?.first?.key.string { secondKey = key }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(secondKey != firstKey)
            // Re-answering the first key has no effect.
            _ = try await respond(server, taskRequest("tasks/update", id: 6, taskID: taskID, extra: ", \"inputResponses\":{\"\(firstKey)\":{\"action\":\"decline\"}}"))
            _ = try await respond(server, taskRequest("tasks/update", id: 7, taskID: taskID, extra: ", \"inputResponses\":{\"\(secondKey)\":{\"action\":\"decline\"}}"))
            let completed = try await waitForStatus(server, taskID, "completed")
            #expect(result(completed)?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "accept,decline")
        }
    }

    @Test func cancellationStopsWorkIncludingWorkWaitingForInput() async throws {
        let runtime = TaskRuntime()
        let observed = Mutex<[String]>([])
        let running = runtime.tool(definition: try toolDefinition("forever")) { _, _ in
            do { while true { try await Task.sleep(for: .milliseconds(2)) } }
            catch { observed.withLock { $0.append("forever") }; throw error }
        }
        let waiting = runtime.tool(definition: try toolDefinition("asks")) { _, context in
            do { return try await context.requestInput(try json(#"{"method":"roots/list","params":{}}"#)) }
            catch { observed.withLock { $0.append("asks") }; throw error }
        }
        let server = try await makeServer(runtime, tools: [running, waiting])
        try await withRuntime(runtime) {
            let first = try createdTaskID(try await respond(server, call("forever", id: 1)))
            let second = try createdTaskID(try await respond(server, call("asks", id: 2)))
            _ = try await waitForStatus(server, second, "input_required")
            for (index, taskID) in [first, second].enumerated() {
                let ack = try await respond(server, taskRequest("tasks/cancel", id: 10 + index, taskID: taskID))
                #expect(result(ack)?["resultType"]?.stringValue == "complete")
                _ = try await waitForStatus(server, taskID, "cancelled")
            }
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while observed.withLock({ $0.count }) < 2, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            #expect(Set(observed.withLock { $0 }) == ["forever", "asks"])
            // Cancelling a terminal task is acknowledged and changes nothing.
            #expect(result(try await respond(server, taskRequest("tasks/cancel", id: 20, taskID: first)))?["resultType"]?.stringValue == "complete")
        }
    }

    @Test func jsonRPCErrorsFailWhileToolErrorsComplete() async throws {
        let runtime = TaskRuntime()
        let failing = runtime.tool(definition: try toolDefinition("protocol_error")) { _, _ in
            throw TaskFailure(code: -32602, message: "bad input for the job")
        }
        let toolError = runtime.tool(definition: try toolDefinition("tool_error")) { _, _ in
            try json(#"{"resultType":"complete","isError":true,"content":[{"type":"text","text":"job failed"}]}"#)
        }
        let server = try await makeServer(runtime, tools: [failing, toolError])
        try await withRuntime(runtime) {
            let failed = try await waitForStatus(server, try createdTaskID(try await respond(server, call("protocol_error", id: 1))), "failed")
            let error = result(failed)?["error"]?.objectValue
            #expect(try error?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
            #expect(result(failed)?["statusMessage"]?.stringValue == "bad input for the job")
            let completed = try await waitForStatus(server, try createdTaskID(try await respond(server, call("tool_error", id: 2))), "completed")
            #expect(result(completed)?["result"]?.objectValue?["isError"]?.booleanValue == true)
        }
    }

    @Test func expiredTasksBecomeUnknownAndCapacityIsBounded() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let runtime = TaskRuntime(configuration: .init(maximumTasksPerPrincipal: 2, timeToLive: .seconds(60)), now: { clock.withLock { $0 } })
        let server = try await makeServer(runtime, tools: [runtime.tool(definition: try toolDefinition("job")) { _, _ in try text("x") }])
        try await withRuntime(runtime) {
            let first = try createdTaskID(try await respond(server, call("job", id: 1)))
            _ = try createdTaskID(try await respond(server, call("job", id: 2)))
            // A third task for the same principal exceeds the per-principal capacity.
            #expect(code(try await respond(server, call("job", id: 3))) == -32603)
            _ = try createdTaskID(try await respond(server, call("job", id: 4), as: bob))
            clock.withLock { $0 = $0.addingTimeInterval(61) }
            #expect(code(try await respond(server, taskRequest("tasks/get", id: 5, taskID: first))) == -32602)
            _ = try createdTaskID(try await respond(server, call("job", id: 6)))
        }
    }

    @Test func discoveryAdvertisesTheTasksExtension() async throws {
        let runtime = TaskRuntime()
        let server = try await makeServer(runtime, tools: [])
        let discovered = try await respond(server, request("server/discover", id: 1, fields: ""))
        #expect(result(discovered)?["capabilities"]?.objectValue?["extensions"]?.objectValue?[extensionID] != nil)
    }

    @Test func shutdownCancelsAndJoinsRunningTasks() async throws {
        let runtime = TaskRuntime()
        let finished = Mutex(false)
        let tool = runtime.tool(definition: try toolDefinition("long")) { _, _ in
            defer { finished.withLock { $0 = true } }
            while true { try await Task.sleep(for: .milliseconds(2)) }
        }
        let server = try await makeServer(runtime, tools: [tool])
        try await withRuntime(runtime) {
            _ = try createdTaskID(try await respond(server, call("long", id: 1)))
        }
        // withRuntime returned only after run() joined: the work has finished.
        #expect(finished.withLock { $0 })
        #expect(await !runtime.isRunning)
        // Creating a task while the runtime is stopped fails instead of losing work.
        #expect(code(try await respond(server, call("long", id: 2))) == -32603)
    }
}
