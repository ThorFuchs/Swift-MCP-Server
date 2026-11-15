// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol
import MCPServer
import MCPServerTesting
import MCPTasks
import MCPTasksClient

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let user = VerifiedPrincipal(subject: ScalarText("user"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private func definition(_ name: String) throws -> JSON { try json("{\"name\":\"\(name)\",\"inputSchema\":{\"type\":\"object\"}}") }
private func text(_ value: String) throws -> JSON {
    try json("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"\(value)\"}]}")
}
private let confirm = #"{"method":"elicitation/create","params":{"mode":"form","message":"Go?","requestedSchema":{"type":"object","properties":{}}}}"#

private func makeServer(_ runtime: TaskRuntime, tools: [ToolRegistration]) async throws -> Server {
    try await Server.make(info: json(#"{"name":"tasks","version":"1"}"#),
        catalog: ServerCatalog(tools: tools, extensions: [runtime.registration()]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }),
        continuations: RequestStateProtector(keys: [.init(identifier: ScalarText("state"), material: Data(repeating: 3, count: 32))], active: ScalarText("state"),
            namespace: ScalarText("tasks-client-tests"), epoch: ScalarText("v1"), clock: { 1000 }))
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

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func tasksClient(_ server: Server, elicitations: Counter = Counter()) -> TasksClient {
    let (key, value) = TasksClient.declaration
    let client = Client(transport: LoopbackTransport(server: server, principal: user), configuration: .init(
        elicitation: .init { _ in elicitations.increment(); return .accept(content: try JSONObject()) },
        extensions: [key: value]))
    return TasksClient(client: client, pollingBounds: .milliseconds(5)...(.milliseconds(50)))
}

@Suite struct TasksClientCases {
    @Test func toolCallsBecomeTasksAndCompleteThroughPolling() async throws {
        let runtime = TaskRuntime(configuration: .init(pollInterval: .milliseconds(10)))
        let slow = runtime.tool(definition: try definition("slow")) { _, context in
            await context.setStatusMessage("halfway")
            try await Task.sleep(for: .milliseconds(30))
            return try text("done")
        }
        let server = try await makeServer(runtime, tools: [slow])
        try await withRuntime(runtime) {
            let tasks = tasksClient(server)
            #expect(TasksClient.isSupported(by: try await tasks.client.discover()))
            guard case .task(let created) = try await tasks.callTool("slow") else { Issue.record("expected a task"); return }
            #expect(created.taskId.count == 32 && created.pollIntervalMs == 10 && !created.status.isTerminal)
            let seen = Counter()
            let final = try await tasks.wait(for: created) { _ in seen.increment() }
            #expect(final.status == .completed && final.result?.text == "done" && final.statusMessage == "halfway")
            #expect(seen.count >= 2)
            #expect(try await tasks.callToolToCompletion("slow").text == "done")
        }
    }

    @Test func inputRequestsAreAnsweredOncePerKeyThroughUpdate() async throws {
        let runtime = TaskRuntime(configuration: .init(pollInterval: .milliseconds(10)))
        let asking = runtime.tool(definition: try definition("ask")) { _, context in
            let first = try await context.requestInput(try json(confirm))
            // Stay input_required for a while with the answered key gone, then ask again.
            try await Task.sleep(for: .milliseconds(30))
            let second = try await context.requestInput(try json(confirm))
            return try text([first, second].compactMap { $0.objectValue?["action"]?.stringValue }.joined(separator: ","))
        }
        let server = try await makeServer(runtime, tools: [asking])
        try await withRuntime(runtime) {
            let elicitations = Counter()
            let tasks = tasksClient(server, elicitations: elicitations)
            let result = try await tasks.callToolToCompletion("ask")
            #expect(result.text == "accept,accept")
            #expect(elicitations.count == 2)
        }
    }

    @Test func failedAndCancelledTasksSurfaceAsErrors() async throws {
        let runtime = TaskRuntime(configuration: .init(pollInterval: .milliseconds(10)))
        let failing = runtime.tool(definition: try definition("fail")) { _, _ in throw TaskFailure(code: -32001, message: "nope") }
        let forever = runtime.tool(definition: try definition("forever")) { _, _ in try await Task.sleep(for: .seconds(3600)); return try text("never") }
        let server = try await makeServer(runtime, tools: [failing, forever])
        try await withRuntime(runtime) {
            let tasks = tasksClient(server)
            await #expect(throws: ClientError.self) { _ = try await tasks.callToolToCompletion("fail") }
            do { _ = try await tasks.callToolToCompletion("fail") }
            catch ClientError.server(let code, let message, _) { #expect(code == -32001 && message == "nope") }

            guard case .task(let created) = try await tasks.callTool("forever") else { Issue.record("expected a task"); return }
            try await tasks.cancel(created.taskId)
            #expect(try await tasks.wait(for: created).status == .cancelled)
            await #expect(throws: ClientError.self) { _ = try await tasks.get("unknown-task") }
        }
    }

    @Test func followReceivesStatusNotificationsUntilEveryTaskIsTerminal() async throws {
        let runtime = TaskRuntime()
        let release = Mutex(false)
        let gated = runtime.tool(definition: try definition("gated")) { _, _ in
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            return try text("released")
        }
        let server = try await makeServer(runtime, tools: [gated])
        try await withRuntime(runtime) {
            let tasks = tasksClient(server)
            guard case .task(let first) = try await tasks.callTool("gated"),
                  case .task(let second) = try await tasks.callTool("gated") else { Issue.record("expected tasks"); return }
            let updates = Counter()
            async let finals = tasks.follow([first.taskId, second.taskId, "foreign"]) { _ in updates.increment() }
            try await Task.sleep(for: .milliseconds(50))
            release.withLock { $0 = true }
            let result = try await finals
            #expect(Set(result.keys) == [first.taskId, second.taskId])
            #expect(result.values.allSatisfy { $0.status == .completed && $0.result?.text == "released" })
            #expect(updates.count >= 2)
        }
    }

    @Test func requestsRequireTheExtensionDeclaration() async throws {
        let runtime = TaskRuntime()
        let server = try await makeServer(runtime, tools: [])
        let tasks = TasksClient(client: Client(transport: LoopbackTransport(server: server, principal: user)))
        await #expect(throws: TasksClientError.extensionNotDeclared) { _ = try await tasks.get("x") }
        await #expect(throws: TasksClientError.extensionNotDeclared) { _ = try await tasks.callTool("x") }
    }
}
