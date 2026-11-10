// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import Synchronization

/// A JSON-RPC error that ends a task in the `failed` status. Tool-level errors
/// (`isError: true` results) are ordinary `completed` results instead.
public struct TaskFailure: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public init(code: Int = -32603, message: String) { self.code = code; self.message = message }
}

public enum TaskRuntimeError: Error, Sendable, Equatable {
    /// `create` was called while `run()` is not active.
    case notRunning
    /// `run()` was called twice.
    case alreadyRunning
    /// The total or per-principal task capacity is exhausted.
    case capacity
}

/// How a task-backed tool behaves for clients that do not declare the Tasks extension.
public enum TaskMode: Sendable {
    /// Only as a task; non-declaring clients receive `-32021`.
    case required
    /// Inline for non-declaring clients (the work runs within the request; no input support).
    case optional
}

/// Finite defaults for the in-memory runtime.
public struct TaskRuntimeConfiguration: Sendable {
    public var maximumTasks: Int
    public var maximumTasksPerPrincipal: Int
    /// Reported as `ttlMs`; expired tasks are discarded and unknown afterwards.
    public var timeToLive: Duration
    /// Reported as `pollIntervalMs`.
    public var pollInterval: Duration
    /// Work units of each task's own `RequestBudget`.
    public var taskWork: UInt64
    public init(maximumTasks: Int = 1024, maximumTasksPerPrincipal: Int = 64, timeToLive: Duration = .seconds(3600),
                pollInterval: Duration = .milliseconds(500), taskWork: UInt64 = 64_000_000) {
        self.maximumTasks = maximumTasks; self.maximumTasksPerPrincipal = maximumTasksPerPrincipal
        self.timeToLive = timeToLive; self.pollInterval = pollInterval; self.taskWork = taskWork
    }
}

public typealias TaskWork = @Sendable (JSONPresence<JSON>, TaskContext) async throws -> JSON

/// Server-side runtime for the Tasks extension (`io.modelcontextprotocol/tasks`).
///
/// The host owns the runtime's lifetime: call `run()` in its own child task (for
/// example as a service) and `shutdown()` to stop. All task work runs as child tasks
/// of `run()`; nothing is detached, and `run()` returns only after every task joined.
public actor TaskRuntime {
    enum Status: String, Sendable { case working, inputRequired = "input_required", completed, cancelled, failed }

    struct Owner: Hashable, Sendable {
        let issuer: String, subject: String, resource: String
        init(_ principal: VerifiedPrincipal) {
            issuer = principal.issuer.description; subject = principal.subject.description; resource = principal.resource.description
        }
    }

    struct Record: Sendable {
        let id: String
        let owner: Owner
        let created: Date
        let expires: Date
        var updated: Date
        var status: Status = .working
        var message: String?
        var result: JSON?
        var failure: TaskFailure?
        var inputs: [(key: String, request: JSON)] = []
        var nextInput = 0
        var cancel: AsyncStream<Void>.Continuation
        var terminal: Bool { status == .completed || status == .failed || status == .cancelled }
    }

    enum Outcome: Sendable { case completed(JSON), failed(TaskFailure), cancelled }

    struct Job: Sendable {
        let id: String
        let input: JSONPresence<JSON>
        let work: TaskWork
        let context: TaskContext
        let cancellation: AsyncStream<Void>
    }

    public let configuration: TaskRuntimeConfiguration
    private let now: @Sendable () -> Date
    private var records: [String: Record] = [:]
    private var jobs: AsyncStream<Job>.Continuation?
    /// Suspended `requestInput` calls, keyed by task ID and input key. Kept outside
    /// actor isolation so a cancellation handler can resume them synchronously.
    private let waiters = Mutex<[String: CheckedContinuation<JSON, any Error>]>([:])

    public init(configuration: TaskRuntimeConfiguration = .init(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.now = now
    }

    // MARK: Lifecycle

    /// Owns every task. Returns after `shutdown()` or cancellation, once all task work
    /// has been cancelled and joined.
    public func run() async throws {
        guard jobs == nil else { throw TaskRuntimeError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        await withDiscardingTaskGroup { group in
            for await job in stream {
                group.addTask { await Self.execute(job) }
            }
            group.cancelAll()
        }
        jobs = nil
        for id in records.keys where !records[id]!.terminal { settle(id, .cancelled) }
    }

    /// Stops accepting tasks; `run()` cancels the remaining work and returns.
    public func shutdown() { jobs?.finish() }

    /// Whether `run()` is active and accepting tasks.
    public var isRunning: Bool { jobs != nil }

    // MARK: Registration

    /// The extension registration to pass to `Server.make` (`extensions:`).
    public nonisolated func registration() throws -> ExtensionRegistration {
        let id = ScalarText(TaskSchemas.identifier)
        return ExtensionRegistration(official: id, settingsSchema: try TaskSchemas.parse(TaskSchemas.settings),
            reservedNames: [ScalarText("tasks/get"), ScalarText("tasks/update"), ScalarText("tasks/cancel"), ScalarText("task")],
            requests: [
                ExtensionRequest(method: ScalarText("tasks/get"), parametersSchema: try TaskSchemas.parse(TaskSchemas.taskIdParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.getResult)) { input, context in try await self.get(input, context) },
                ExtensionRequest(method: ScalarText("tasks/update"), parametersSchema: try TaskSchemas.parse(TaskSchemas.updateParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.acknowledgement)) { input, context in try await self.update(input, context) },
                ExtensionRequest(method: ScalarText("tasks/cancel"), parametersSchema: try TaskSchemas.parse(TaskSchemas.taskIdParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.acknowledgement)) { input, context in try await self.cancel(input, context) },
            ],
            results: [ExtensionResult(type: ScalarText("task"), schema: try TaskSchemas.parse(TaskSchemas.createResult), coreMethods: [.callTool])])
    }

    /// A tool whose calls become tasks for clients that declare the extension.
    public nonisolated func tool(definition: JSON, requiredScopes: Set<ScalarText> = [], mode: TaskMode = .required,
                                 work: @escaping TaskWork) -> ToolRegistration {
        ToolRegistration(definition: definition, requiredScopes: requiredScopes) { input, context in
            if context.extensions[TaskSchemas.identifier] != nil {
                return try await self.create(input: input, request: context, work: work)
            }
            guard mode == .optional else { throw ExtensionCapabilityRequired(ScalarText(TaskSchemas.identifier)) }
            return try await work(input, TaskContext(inline: context))
        }
    }

    // MARK: Creation and execution

    func create(input: JSONPresence<JSON>, request: RequestContext, work: @escaping TaskWork) async throws -> JSON {
        guard let jobs else { throw TaskRuntimeError.notRunning }
        expire()
        let owner = Owner(request.principal)
        guard records.count < configuration.maximumTasks,
              records.values.filter({ $0.owner == owner }).count < configuration.maximumTasksPerPrincipal else { throw TaskRuntimeError.capacity }
        let id = Self.makeIdentifier()
        let created = now()
        let (cancellation, cancel) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // The record exists before the reply, so tasks/get resolves as soon as the client sees the ID.
        records[id] = Record(id: id, owner: owner, created: created, expires: created.addingTimeInterval(Self.seconds(configuration.timeToLive)),
                             updated: created, cancel: cancel)
        let context = TaskContext(id: id, runtime: self, budget: try RequestBudget(workUnits: configuration.taskWork), request: request)
        if case .terminated = jobs.yield(Job(id: id, input: input, work: work, context: context, cancellation: cancellation)) {
            records[id] = nil
            throw TaskRuntimeError.notRunning
        }
        let task = try await taskObject(records[id]!, detailed: false, budget: request.budget)
        return try await RuntimeJSON.object([.init("resultType", value: .string("task")), .init("task", value: task)], budget: request.budget)
    }

    private static func execute(_ job: Job) async {
        let outcome = await withTaskGroup(of: Outcome?.self) { group -> Outcome in
            group.addTask {
                do { return .completed(try await job.work(job.input, job.context)) }
                catch let failure as TaskFailure { return .failed(failure) }
                catch is CancellationError { return .cancelled }
                catch { return .failed(TaskFailure(message: "Task execution failed")) }
            }
            group.addTask {
                for await _ in job.cancellation { return .cancelled }
                return nil
            }
            var outcome = Outcome.cancelled
            while let next = await group.next() {
                if let next { outcome = next; break }
            }
            group.cancelAll()
            return outcome
        }
        await job.context.runtime?.settle(job.id, outcome)
    }

    func settle(_ id: String, _ outcome: Outcome) {
        guard var record = records[id], !record.terminal || record.status == .cancelled else { return }
        // A requested cancellation already reported `cancelled`; it stays that way.
        if record.status != .cancelled {
            switch outcome {
            case .completed(let result):
                if result.objectValue?["resultType"]?.stringValue == "complete" { record.status = .completed; record.result = result }
                else { record.status = .failed; record.failure = TaskFailure(message: "Task produced an invalid result") }
            case .failed(let failure): record.status = .failed; record.failure = failure; record.message = failure.message
            case .cancelled: record.status = .cancelled
            }
        }
        record.inputs = []
        record.updated = now()
        record.cancel.finish()
        records[id] = record
        let pending = waiters.withLock { table in
            let keys = table.keys.filter { $0.hasPrefix(id + "/") }
            return keys.compactMap { table.removeValue(forKey: $0) }
        }
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }

    // MARK: Context operations

    func setMessage(_ id: String, _ message: String?) {
        guard var record = records[id], !record.terminal else { return }
        record.message = message; record.updated = now(); records[id] = record
    }

    func requestInput(_ id: String, _ request: JSON) async throws -> JSON {
        guard var record = records[id], !record.terminal else { throw CancellationError() }
        // Keys are never reused within a task.
        let key = "input-\(record.nextInput)"
        record.nextInput += 1
        record.inputs.append((key, request)); record.status = .inputRequired; record.updated = now()
        records[id] = record
        let slot = id + "/" + key
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, any Error>) in
                waiters.withLock { $0[slot] = continuation }
                if Task.isCancelled, let waiter = waiters.withLock({ $0.removeValue(forKey: slot) }) {
                    waiter.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            waiters.withLock { $0.removeValue(forKey: slot) }?.resume(throwing: CancellationError())
        }
    }

    // MARK: Protocol methods

    func get(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        let record = try lookup(input, context)
        let task = try await taskObject(record, detailed: true, budget: context.budget)
        return try await RuntimeJSON.overlay(task, members: [.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    func update(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        var record = try lookup(input, context)
        if let responses = input.json?.objectValue?["inputResponses"]?.objectValue, !record.terminal {
            for response in responses {
                let key = response.key.string
                // Unknown, answered or superseded keys are ignored.
                guard let index = record.inputs.firstIndex(where: { $0.key == key }),
                      let waiter = waiters.withLock({ $0.removeValue(forKey: record.id + "/" + key) }) else { continue }
                record.inputs.remove(at: index)
                waiter.resume(returning: response.value)
            }
            if record.inputs.isEmpty, record.status == .inputRequired { record.status = .working }
            record.updated = now()
            records[record.id] = record
        }
        return try await RuntimeJSON.object([.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    func cancel(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        var record = try lookup(input, context)
        if !record.terminal {
            record.status = .cancelled; record.updated = now(); records[record.id] = record
            record.cancel.yield()
        }
        return try await RuntimeJSON.object([.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    /// Unknown, expired and other principals' tasks are indistinguishable: `-32602`.
    private func lookup(_ input: JSONPresence<JSON>, _ context: RequestContext) throws -> Record {
        expire()
        guard let id = input.json?.objectValue?["taskId"]?.stringValue, let record = records[id],
              record.owner == Owner(context.principal) else { throw CoreFailure.invalidInput }
        return record
    }

    private func expire() {
        let current = now()
        for (id, record) in records where record.expires <= current {
            if !record.terminal { record.cancel.yield() }
            records[id] = nil
        }
    }

    // MARK: Encoding

    private func taskObject(_ record: Record, detailed: Bool, budget: RequestBudget) async throws -> JSON {
        var members: [JSONMember] = [
            .init("taskId", value: .string(record.id)),
            .init("status", value: .string(record.status.rawValue)),
            .init("createdAt", value: .string(record.created.ISO8601Format())),
            .init("lastUpdatedAt", value: .string(record.updated.ISO8601Format())),
            .init("ttlMs", value: .number(JSONNumber(integer: Self.milliseconds(configuration.timeToLive)))),
            .init("pollIntervalMs", value: .number(JSONNumber(integer: Self.milliseconds(configuration.pollInterval)))),
        ]
        if let message = record.message { members.append(.init("statusMessage", value: .string(message))) }
        if detailed {
            if let result = record.result, record.status == .completed { members.append(.init("result", value: result)) }
            if let failure = record.failure, record.status == .failed {
                let error = try await RuntimeJSON.object([.init("code", value: .number(JSONNumber(integer: failure.code))),
                    .init("message", value: .string(failure.message))], budget: budget)
                members.append(.init("error", value: error))
            }
            if record.status == .inputRequired {
                let requests = try await RuntimeJSON.object(record.inputs.map { .init($0.key, value: $0.request) }, budget: budget)
                members.append(.init("inputRequests", value: requests))
            }
        }
        return try await RuntimeJSON.object(members, budget: budget)
    }

    private static func makeIdentifier() -> String {
        var generator = SystemRandomNumberGenerator()
        // 128 bits from the system CSPRNG; unguessable and not enumerable.
        return (0..<2).map { _ in String(generator.next() as UInt64, radix: 16).leftPadded(to: 16) }.joined()
    }
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

extension JSONPresence where Value == JSON {
    var json: JSON? { if case .value(let value) = self { value } else { nil } }
}
