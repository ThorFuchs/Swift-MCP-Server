// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPClient

/// The state of a task as the server last reported it (`Task` / `DetailedTask`).
public struct TaskSnapshot: Sendable {
    public enum Status: String, Sendable {
        case working, inputRequired = "input_required", completed, cancelled, failed
        public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    }

    public let taskId: String
    public let status: Status
    public let statusMessage: String?
    public let createdAt: String
    public let lastUpdatedAt: String
    /// `nil` when the server keeps the task without a time limit.
    public let ttlMs: Int?
    /// The server's suggested polling interval.
    public let pollIntervalMs: Int?
    /// The final `CallToolResult` of a `completed` task.
    public let result: ToolResult?
    /// The JSON-RPC error of a `failed` task.
    public let error: (code: Int, message: String, data: JSON?)?
    /// Outstanding input requests of an `input_required` task, by key.
    public let inputRequests: JSONObject?
    public let raw: JSON

    public init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let taskId = object["taskId"]?.stringValue, !taskId.isEmpty,
              let status = object["status"]?.stringValue.flatMap(Status.init(rawValue:)),
              let createdAt = object["createdAt"]?.stringValue, let lastUpdatedAt = object["lastUpdatedAt"]?.stringValue
        else { throw ClientError.invalidResponse("task") }
        self.taskId = taskId; self.status = status; self.createdAt = createdAt; self.lastUpdatedAt = lastUpdatedAt
        statusMessage = object["statusMessage"]?.stringValue
        ttlMs = try? object["ttlMs"]?.numberValue?.integer(as: Int.self)
        pollIntervalMs = try? object["pollIntervalMs"]?.numberValue?.integer(as: Int.self)
        result = object["result"].map(ToolResult.init)
        if let error = object["error"]?.objectValue, let code = try? error["code"]?.numberValue?.integer(as: Int.self) {
            self.error = (code, error["message"]?.stringValue ?? "", error["data"])
        } else { error = nil }
        inputRequests = object["inputRequests"]?.objectValue
        self.raw = raw
    }
}

/// The outcome of a `tools/call` made through `TasksClient`.
public enum ToolCallOutcome: Sendable {
    /// The server answered inline.
    case completed(ToolResult)
    /// The server created a task.
    case task(TaskSnapshot)
}

public enum TasksClientError: Error, Sendable, Equatable {
    /// The client configuration does not declare `io.modelcontextprotocol/tasks`, so the
    /// server would never create tasks for it.
    case extensionNotDeclared
}

/// The client side of the Tasks extension (`io.modelcontextprotocol/tasks`, 2026-07-28).
///
/// Declare the extension in the client configuration (`TasksClient.declaration`). Tool
/// calls may then return a task; `wait` polls it at the server's `pollIntervalMs`,
/// answers input requests with the client's handlers through `tasks/update`, and returns
/// the terminal state. `follow` receives `notifications/tasks` over `subscriptions/listen`
/// instead of polling. Cancelling a waiting call stops waiting; it does not cancel the
/// task on the server, which `cancel` does.
public struct TasksClient: Sendable {
    public static let extensionIdentifier = "io.modelcontextprotocol/tasks"
    /// Add to `ClientConfiguration.extensions` to declare the extension.
    public static var declaration: (String, JSON) { (extensionIdentifier, .object(try! JSONObject())) }

    public let client: Client
    /// Bounds for the server's suggested polling interval.
    public var pollingBounds: ClosedRange<Duration>

    public init(client: Client, pollingBounds: ClosedRange<Duration> = .milliseconds(50)...(.seconds(30))) {
        self.client = client; self.pollingBounds = pollingBounds
    }

    /// Whether the server declares the extension (from `server/discover`).
    public static func isSupported(by server: ServerDescription) -> Bool {
        server.extensionSettings(extensionIdentifier) != nil
    }

    // MARK: Requests

    /// `tools/call` that may create a task.
    public func callTool(_ name: String, arguments: JSON? = nil) async throws -> ToolCallOutcome {
        try requireDeclaration()
        let result = try await client.callTool(name, arguments: arguments)
        return result.resultType == "task" ? .task(try TaskSnapshot(result.raw)) : .completed(result)
    }

    /// `tasks/get`.
    public func get(_ taskId: String) async throws -> TaskSnapshot {
        try requireDeclaration()
        return try TaskSnapshot(try await client.request("tasks/get", params: [JSONMember("taskId", value: .string(taskId))], name: taskId))
    }

    /// `tasks/update` with responses by input key.
    public func update(_ taskId: String, inputResponses: JSON) async throws {
        try requireDeclaration()
        _ = try await client.request("tasks/update", params: [JSONMember("taskId", value: .string(taskId)),
                                                              JSONMember("inputResponses", value: inputResponses)], name: taskId)
    }

    /// `tasks/cancel`.
    public func cancel(_ taskId: String) async throws {
        try requireDeclaration()
        _ = try await client.request("tasks/cancel", params: [JSONMember("taskId", value: .string(taskId))], name: taskId)
    }

    // MARK: Waiting

    /// Polls until the task is terminal and returns that state. Input requests are answered
    /// once per key with the client's handlers; `onUpdate` sees every polled state.
    public func wait(for task: TaskSnapshot, onUpdate: (@Sendable (TaskSnapshot) async -> Void)? = nil) async throws -> TaskSnapshot {
        var current = task
        var answered: Set<String> = []
        while true {
            await onUpdate?(current)
            if current.status.isTerminal { return current }
            if current.status == .inputRequired, let requests = current.inputRequests {
                let fresh = try JSONObject(members: requests.members.filter { !answered.contains($0.key.string) })
                if !fresh.isEmpty {
                    let responses = try await client.answerInputRequests(fresh)
                    try await update(current.taskId, inputResponses: responses)
                    answered.formUnion(fresh.members.map(\.key.string))
                }
            }
            try await Task.sleep(for: interval(current))
            current = try await get(current.taskId)
        }
    }

    /// Calls a tool and, if the server created a task, waits for its terminal state.
    /// A `failed` task throws `ClientError.server`; a `cancelled` one throws `CancellationError`.
    public func callToolToCompletion(_ name: String, arguments: JSON? = nil) async throws -> ToolResult {
        switch try await callTool(name, arguments: arguments) {
        case .completed(let result): return result
        case .task(let task):
            let final = try await wait(for: task)
            switch final.status {
            case .completed:
                guard let result = final.result else { throw ClientError.invalidResponse("completed task without result") }
                return result
            case .failed:
                let error = final.error
                throw ClientError.server(code: error?.code ?? -32603, message: error?.message ?? "task failed", data: error?.data)
            default: throw CancellationError()
            }
        }
    }

    /// Follows tasks through `notifications/tasks` until every task the server agreed to
    /// report is terminal, and returns their final states. Unknown and foreign IDs are not
    /// agreed and are missing from the result.
    public func follow(_ taskIds: [String], onUpdate: (@Sendable (TaskSnapshot) async -> Void)? = nil) async throws -> [String: TaskSnapshot] {
        try requireDeclaration()
        let filter = JSON.object(try JSONObject(members: [JSONMember("taskIds", value: .array(taskIds.map(JSON.string)))]))
        let state = FollowState()
        let (done, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // The listen call runs as a child task; once every agreed task is terminal the
        // parent cancels it, which ends the subscription on the transport.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [client] in
                defer { signal.finish() }
                try await client.listen(filter) { event in
                    switch event {
                    case .acknowledged(let agreed):
                        let ids = agreed.objectValue?["taskIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if await state.agree(ids) { signal.finish() }
                    case .notification(let method, let params) where method == "notifications/tasks":
                        let snapshot = try TaskSnapshot(params)
                        await onUpdate?(snapshot)
                        if await state.record(snapshot) { signal.finish() }
                    default: break
                    }
                }
            }
            for await _ in done {}
            if await state.isDone {
                // Every final state is in hand; how the cancelled subscription ends does not matter.
                group.cancelAll()
                try? await group.waitForAll()
            } else {
                try await group.waitForAll()
            }
        }
        return await state.finals
    }

    // MARK: Helpers

    private func requireDeclaration() throws {
        guard client.configuration.extensions[Self.extensionIdentifier] != nil else { throw TasksClientError.extensionNotDeclared }
    }

    private func interval(_ task: TaskSnapshot) -> Duration {
        let suggested = Duration.milliseconds(task.pollIntervalMs ?? 1000)
        return min(max(suggested, pollingBounds.lowerBound), pollingBounds.upperBound)
    }
}

private actor FollowState {
    private var agreed: Set<String>?
    private(set) var finals: [String: TaskSnapshot] = [:]

    /// Returns true when there is nothing (left) to follow.
    func agree(_ ids: [String]) -> Bool {
        agreed = Set(ids)
        return isDone
    }
    func record(_ snapshot: TaskSnapshot) -> Bool {
        if snapshot.status.isTerminal { finals[snapshot.taskId] = snapshot }
        return isDone
    }
    var isDone: Bool {
        guard let agreed else { return false }
        return agreed.isSubset(of: finals.keys)
    }
}
