// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol
import MCPTasksClient

private func taskConsumerJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

private struct TaskConsumerStep: Sendable {
    let method: String
    let name: String?
    let params: String
    // Complete wire frames; @ID@ is replaced by the actual request ID.
    let frames: [String]
    init(_ method: String, name: String? = nil, params: String, frames: [String]) {
        self.method = method; self.name = name; self.params = params; self.frames = frames
    }
}

private final class TaskConsumerScript: ClientTransport, Sendable {
    let steps: [TaskConsumerStep]
    private let position = Mutex(0)
    init(_ steps: [TaskConsumerStep]) { self.steps = steps }
    var count: Int { position.withLock { $0 } }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let index = position.withLock { n in let i = n; n += 1; return i }
        let step = try #require(steps.indices.contains(index) ? steps[index] : nil)
        let body = try #require(try taskConsumerJSON(String(decoding: request.body, as: UTF8.self)).objectValue)
        let params = try #require(body["params"]?.objectValue)
        let expected = try #require(try taskConsumerJSON(step.params).objectValue)
        let meta = try #require(params["_meta"]?.objectValue)
        #expect(request.method == step.method && body["method"]?.stringValue == step.method && request.name == step.name)
        #expect(body["id"] == request.id.value && body["jsonrpc"]?.stringValue == "2.0")
        #expect(meta["io.modelcontextprotocol/protocolVersion"]?.stringValue == "2026-07-28")
        #expect(meta["io.modelcontextprotocol/clientCapabilities"]?.objectValue?["extensions"]?.objectValue?[TasksClient.extensionIdentifier] == (try taskConsumerJSON("{}")))
        #expect(params.count == expected.count + 1)
        for member in expected { #expect(params[member.key.string] == member.value) }
        let id = String(decoding: try WireCodec.write(request.id.value, limits: .balanced).result, as: UTF8.self)
        for frame in step.frames {
            try await receive(Data(frame.replacingOccurrences(of: "@ID@", with: id).utf8))
        }
    }
}

private func taskConsumerClient(_ transport: TaskConsumerScript) -> TasksClient {
    let (key, value) = TasksClient.declaration
    return TasksClient(client: Client(transport: transport, configuration: .init(extensions: [key:value])),
                       pollingBounds: .zero ... .zero)
}

private func taskReply(_ result: String) -> String {
    #"{"jsonrpc":"2.0","id":@ID@,"result":\#(result)}"#
}

private func snapshot(_ id: String, status: String, resultType: String = "complete", extra: String = "") -> String {
    #"{"resultType":"\#(resultType)","taskId":"\#(id)","status":"\#(status)","createdAt":"2026-07-28T00:00:00Z","lastUpdatedAt":"2026-07-28T00:00:01Z","ttlMs":null,"pollIntervalMs":50\#(extra)}"#
}

private let taskConsumerResult = #""result":{"resultType":"complete","content":[{"type":"text","text":"finished"}],"structuredContent":{"count":1}}"#
private func taskAck(_ ids: String) -> String {
    #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":@ID@},"notifications":{"taskIds":\#(ids)}}}"#
}
private func taskEvent(_ id: String, status: String, extra: String = "") -> String {
    #"{"jsonrpc":"2.0","method":"notifications/tasks","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":@ID@},"taskId":"\#(id)","status":"\#(status)","createdAt":"2026-07-28T00:00:00Z","lastUpdatedAt":"2026-07-28T00:00:01Z","ttlMs":null,"pollIntervalMs":50\#(extra)}}"#
}
private let taskClose = #"{"jsonrpc":"2.0","id":@ID@,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":@ID@}}}"#

@Suite(.serialized) struct PublicTasksConsumerContractCases {
    @Test func tasksConsumerInlineAndDeferredOutcomesPreserveResult() async throws {
        let inline = #"{"resultType":"complete","content":[{"type":"text","text":"inline"}],"isError":false,"structuredContent":{"count":0}}"#
        let created = snapshot("t1", status: "working", resultType: "task")
        let final = snapshot("t1", status: "completed", extra: "," + taskConsumerResult)
        let script = TaskConsumerScript([
            .init("tools/call", name: "inline", params: #"{"name":"inline"}"#, frames: [taskReply(inline)]),
            .init("tools/call", name: "deferred", params: #"{"name":"deferred","arguments":{"x":1}}"#, frames: [taskReply(created)]),
            .init("tasks/get", name: "t1", params: #"{"taskId":"t1"}"#, frames: [taskReply(final)])
        ])
        let tasks = taskConsumerClient(script)
        guard case .completed(let result) = try await tasks.callTool("inline") else { Issue.record("expected inline completion"); return }
        #expect(result.raw == (try taskConsumerJSON(inline)) && result.text == "inline" && !result.isError)
        guard case .task(let task) = try await tasks.callTool("deferred", arguments: taskConsumerJSON(#"{"x":1}"#)) else {
            Issue.record("expected task"); return
        }
        #expect(task.taskId == "t1" && task.status == .working && task.ttlMs == nil && task.pollIntervalMs == 50)
        #expect(task.raw == (try taskConsumerJSON(created)))
        let updates = Mutex<[TaskSnapshot.Status]>([])
        let terminal = try await tasks.wait(for: task) { update in updates.withLock { $0.append(update.status) } }
        #expect(updates.withLock { $0 } == [.working,.completed])
        #expect(terminal.raw == (try taskConsumerJSON(final)))
        #expect(terminal.result?.text == "finished" && terminal.result?.structuredContent == (try taskConsumerJSON(#"{"count":1}"#)))
        #expect(script.count == 3)
    }

    @Test func tasksConsumerExplicitCancelAndTypedServerFailure() async throws {
        let failed = snapshot("t1", status: "failed", resultType: "task", extra: #","error":{"code":-32001,"message":"job failed","data":{"reason":"fixture"}}"#)
        let script = TaskConsumerScript([
            .init("tasks/cancel", name: "t0", params: #"{"taskId":"t0"}"#, frames: [taskReply(#"{"resultType":"complete"}"#)]),
            .init("tools/call", name: "fail", params: #"{"name":"fail"}"#, frames: [taskReply(failed)])
        ])
        let tasks = taskConsumerClient(script)
        try await tasks.cancel("t0")
        let expected = ClientError.server(code: -32001, message: "job failed", data: try taskConsumerJSON(#"{"reason":"fixture"}"#))
        await #expect(throws: expected) { _ = try await tasks.callToolToCompletion("fail") }
        #expect(script.count == 2)
    }

    @Test func tasksConsumerAllRequestEntrypointsRequireDeclarationBeforeWire() async throws {
        let script = TaskConsumerScript([])
        let tasks = TasksClient(client: Client(transport: script))
        await #expect(throws: TasksClientError.extensionNotDeclared) { _ = try await tasks.callTool("x") }
        await #expect(throws: TasksClientError.extensionNotDeclared) { _ = try await tasks.get("t") }
        await #expect(throws: TasksClientError.extensionNotDeclared) { try await tasks.update("t", inputResponses: taskConsumerJSON("{}")) }
        await #expect(throws: TasksClientError.extensionNotDeclared) { try await tasks.cancel("t") }
        await #expect(throws: TasksClientError.extensionNotDeclared) { _ = try await tasks.follow(["t"]) }
        #expect(script.count == 0)
    }

    @Test func tasksConsumerGetCannotReturnDifferentTaskIdentity() async throws {
        let script = TaskConsumerScript([.init("tasks/get", name: "requested", params: #"{"taskId":"requested"}"#,
            frames: [taskReply(snapshot("foreign", status: "working"))])])
        do {
            _ = try await taskConsumerClient(script).get("requested")
            Issue.record("tasks/get returned another task")
        } catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(script.count == 1)
    }

    @Test func tasksConsumerFollowAgreedSubsetCompletesWithoutPolling() async throws {
        let script = TaskConsumerScript([.init("subscriptions/listen", params: #"{"notifications":{"taskIds":["t1","unknown"]}}"#,
            frames: [taskAck(#"["t1"]"#), taskEvent("t1", status: "working"),
                     taskEvent("t1", status: "completed", extra: "," + taskConsumerResult), taskClose])])
        let updates = Mutex<[String]>([])
        let finals = try await taskConsumerClient(script).follow(["t1","unknown"]) { task in updates.withLock { $0.append(task.taskId + ":" + task.status.rawValue) } }
        #expect(updates.withLock { $0 } == ["t1:working","t1:completed"])
        #expect(Set(finals.keys) == ["t1"] && finals["t1"]?.result?.text == "finished")
        #expect(script.count == 1)
    }

    @Test func tasksConsumerFollowDoesNotExposeUnacknowledgedTask() async throws {
        let script = TaskConsumerScript([.init("subscriptions/listen", params: #"{"notifications":{"taskIds":["t1","t2"]}}"#,
            frames: [taskAck(#"["t1"]"#), taskEvent("t2", status: "completed", extra: "," + taskConsumerResult),
                     taskEvent("t1", status: "completed", extra: "," + taskConsumerResult), taskClose])])
        let updates = Mutex<[String]>([])
        do {
            let finals = try await taskConsumerClient(script).follow(["t1","t2"]) { task in updates.withLock { $0.append(task.taskId) } }
            // Ignore an unsolicited extension member or reject it before callback;
            // either policy must never expose or retain the unagreed task.
            #expect(Set(finals.keys) == ["t1"])
            #expect(finals["t1"]?.status == .completed)
        } catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(!updates.withLock { $0 }.contains("t2"))
        #expect(script.count == 1)
    }

    @Test func tasksConsumerFollowCannotReturnSuccessWithMissingAgreedFinal() async throws {
        let script = TaskConsumerScript([.init("subscriptions/listen", params: #"{"notifications":{"taskIds":["t1","t2"]}}"#,
            frames: [taskAck(#"["t1","t2"]"#), taskEvent("t1", status: "completed", extra: "," + taskConsumerResult), taskClose])])
        do {
            _ = try await taskConsumerClient(script).follow(["t1","t2"])
            Issue.record("follow returned success without every agreed terminal state")
        } catch ClientError.invalidResponse(_) {}
        catch { Issue.record("unexpected error category: \(error)") }
        #expect(script.count == 1)
    }
}
