// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
import MCPServer

/// What task work can see and do. Passed to every `TaskWork` closure.
public struct TaskContext: Sendable {
    /// The task identifier, or `nil` when an optional task tool runs inline.
    public let taskID: String?
    /// The task's own finite budget (inline: the request's budget).
    public let budget: RequestBudget
    /// The request that created the task (principal, capabilities, extensions).
    public let request: RequestContext
    let runtime: TaskRuntime?

    init(id: String, runtime: TaskRuntime, budget: RequestBudget, request: RequestContext) {
        taskID = id; self.runtime = runtime; self.budget = budget; self.request = request
    }
    init(inline request: RequestContext) {
        taskID = nil; runtime = nil; budget = request.budget; self.request = request
    }

    /// Sets the task's `statusMessage` (ignored inline).
    public func setStatusMessage(_ message: String?) async {
        guard let taskID, let runtime else { return }
        await runtime.setMessage(taskID, message)
    }

    /// Asks the client for input (an MRTR `InputRequest`, for example an
    /// `elicitation/create` request) and suspends until `tasks/update` answers it.
    /// The task reports `input_required` meanwhile. Throws `CancellationError` when
    /// the task is cancelled, and `ExtensionCapabilityRequired` when running inline.
    public func requestInput(_ request: JSON) async throws -> JSON {
        guard let taskID, let runtime else { throw ExtensionCapabilityRequired(ScalarText("io.modelcontextprotocol/tasks")) }
        return try await runtime.requestInput(taskID, request)
    }
}
