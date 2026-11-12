// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import JSONSchema
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
    /// The store kept reporting concurrent changes to one task.
    case storeContention
}

/// How a task-backed tool behaves for clients that do not declare the Tasks extension.
public enum TaskMode: Sendable {
    /// Only as a task; non-declaring clients receive `-32021`.
    case required
    /// Inline for non-declaring clients (the work runs within the request; no input support).
    case optional
}

/// What `run()` does with unfinished tasks it finds in the store when it starts.
public enum TaskRestartPolicy: Sendable {
    /// Their work did not survive the restart: they become `failed` (`-32603`,
    /// "Task interrupted by a server restart"). The default for single-instance stores.
    case failUnfinished
    /// Leave them alone, for stores shared by several running instances.
    case keep
}

/// Finite defaults for the runtime.
public struct TaskRuntimeConfiguration: Sendable {
    public var maximumTasks: Int
    public var maximumTasksPerPrincipal: Int
    /// Reported as `ttlMs`; expired tasks are discarded and unknown afterwards.
    public var timeToLive: Duration
    /// Reported as `pollIntervalMs`.
    public var pollInterval: Duration
    /// Work units of each task's own `RequestBudget`.
    public var taskWork: UInt64
    public var restartPolicy: TaskRestartPolicy
    public init(maximumTasks: Int = 1024, maximumTasksPerPrincipal: Int = 64, timeToLive: Duration = .seconds(3600),
                pollInterval: Duration = .milliseconds(500), taskWork: UInt64 = 64_000_000, restartPolicy: TaskRestartPolicy = .failUnfinished) {
        self.maximumTasks = maximumTasks; self.maximumTasksPerPrincipal = maximumTasksPerPrincipal
        self.timeToLive = timeToLive; self.pollInterval = pollInterval; self.taskWork = taskWork; self.restartPolicy = restartPolicy
    }
}

public typealias TaskWork = @Sendable (JSONPresence<JSON>, TaskContext) async throws -> JSON

/// Server-side runtime for the Tasks extension (`io.modelcontextprotocol/tasks`).
///
/// The host owns the runtime's lifetime: call `run()` in its own child task (for
/// example as a service) and `shutdown()` to stop. All task work runs as child tasks
/// of `run()`; nothing is detached, and `run()` returns only after every task joined.
/// Task state lives in a `TaskStore` (in memory by default, durable with
/// `MCPTasksSQLite`); the runtime keeps only what belongs to this process: running
/// work, its cancellation and suspended input requests.
public actor TaskRuntime {
    enum Outcome: Sendable { case completed(JSON), failed(TaskFailure), cancelled }

    struct Job: Sendable {
        let id: String
        let input: JSONPresence<JSON>
        let output: JSON?
        let work: TaskWork
        let context: TaskContext
        let cancellation: AsyncStream<Void>
    }

    /// A suspended `requestInput` call, or an answer that arrived before it suspended.
    enum Mailbox: Sendable { case waiting(CheckedContinuation<JSON, any Error>), answered(JSON) }

    public let configuration: TaskRuntimeConfiguration
    public let store: any TaskStore
    private let now: @Sendable () -> Date
    private var jobs: AsyncStream<Job>.Continuation?
    /// Owners and cancellation of the tasks whose work runs in this process.
    private var local: [String: (owner: TaskOwner, cancel: AsyncStream<Void>.Continuation)] = [:]
    /// Input requests by `"id/key"`. Kept outside actor isolation so a cancellation
    /// handler can resume them synchronously.
    private let mailboxes = Mutex<[String: Mailbox]>([:])
    /// Delivers `notifications/tasks` to `subscriptions/listen` streams (see `registration()`).
    private let relay = ExtensionEventRelay()
    /// Tasks whose current state has not been delivered yet, in change order. Bounded by
    /// the number of tasks; repeated changes coalesce into one delivery of the latest state.
    private var pending: [(id: String, owner: TaskOwner)] = []
    private var notifier: AsyncStream<Void>.Continuation?

    public init(configuration: TaskRuntimeConfiguration = .init(), store: any TaskStore = InMemoryTaskStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration; self.store = store; self.now = now
    }

    // MARK: Lifecycle

    /// Owns every task. Applies the restart policy to unfinished stored tasks, then runs
    /// until `shutdown()` or cancellation, once all task work has been cancelled and joined.
    public func run() async throws {
        guard jobs == nil else { throw TaskRuntimeError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        let (signal, poke) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        jobs = continuation; notifier = poke
        do { try await recover() } catch { jobs = nil; notifier = nil; continuation.finish(); poke.finish(); throw error }
        await withDiscardingTaskGroup { group in
            // One serial publisher: notifications for a task never overtake each other.
            group.addTask { await self.deliver(signal) }
            for await job in stream {
                group.addTask { await Self.execute(job) }
            }
            group.cancelAll()
        }
        jobs = nil; notifier = nil; poke.finish(); pending = []
        for id in local.keys { await settle(id, .cancelled) }
    }

    /// Stops accepting tasks; `run()` cancels the remaining work and returns.
    public func shutdown() { jobs?.finish() }

    /// Whether `run()` is active and accepting tasks.
    public var isRunning: Bool { jobs != nil }

    /// Applies the restart policy to every unfinished stored task, in bounded pages.
    private func recover() async throws {
        guard configuration.restartPolicy == .failUnfinished else { return }
        var cursor: String?
        while true {
            let page = try await store.unfinished(after: cursor, limit: 64, now: now())
            for record in page {
                _ = try await mutate(record.id, record.owner) { task in
                    guard !task.status.isTerminal else { return false }
                    task.status = .failed; task.inputRequests = []
                    task.failure = TaskFailure(message: "Task interrupted by a server restart"); task.statusMessage = "server restarted"
                    return true
                }
            }
            guard page.count == 64, let last = page.last else { return }
            cursor = last.id
        }
    }

    // MARK: Registration

    /// The extension registration to pass to `Server.make` (`extensions:`).
    public nonisolated func registration() throws -> ExtensionRegistration {
        let id = ScalarText(TaskSchemas.identifier)
        let notification = ScalarText("notifications/tasks")
        return ExtensionRegistration(official: id, settingsSchema: try TaskSchemas.parse(TaskSchemas.settings),
            reservedNames: [ScalarText("tasks/get"), ScalarText("tasks/update"), ScalarText("tasks/cancel"), ScalarText("task"), notification],
            requests: [
                ExtensionRequest(method: ScalarText("tasks/get"), parametersSchema: try TaskSchemas.parse(TaskSchemas.taskIdParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.getResult)) { input, context in try await self.get(input, context) },
                ExtensionRequest(method: ScalarText("tasks/update"), parametersSchema: try TaskSchemas.parse(TaskSchemas.updateParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.acknowledgement)) { input, context in try await self.update(input, context) },
                ExtensionRequest(method: ScalarText("tasks/cancel"), parametersSchema: try TaskSchemas.parse(TaskSchemas.taskIdParameters),
                    completeResultSchema: try TaskSchemas.parse(TaskSchemas.acknowledgement)) { input, context in try await self.cancel(input, context) },
            ],
            results: [ExtensionResult(type: ScalarText("task"), schema: try TaskSchemas.parse(TaskSchemas.createResult), coreMethods: [.callTool])],
            notifications: [ExtensionNotification(method: notification, parametersSchema: try TaskSchemas.parse(TaskSchemas.notification))],
            // subscriptions/listen with notifications.taskIds: only the caller's own live tasks are
            // agreed; once acknowledged, each agreed task's current state is sent first.
            subscriptions: [ExtensionSubscription(filter: ScalarText("taskIds"), notification: notification,
                agree: { ids, context in try await self.subscribable(ids, context) },
                activated: { ids, context in await self.changed(ids.map { ($0, TaskOwner(context.principal)) }) })],
            relay: relay)
    }

    /// A tool whose calls become tasks for clients that declare the extension.
    public nonisolated func tool(definition: JSON, requiredScopes: Set<ScalarText> = [], mode: TaskMode = .required,
                                 work: @escaping TaskWork) -> ToolRegistration {
        let output = definition.objectValue?["outputSchema"]
        return ToolRegistration(definition: definition, requiredScopes: requiredScopes) { input, context in
            if context.extensions[TaskSchemas.identifier] != nil {
                return try await self.create(input: input, request: context, output: output, work: work)
            }
            guard mode == .optional else { throw ExtensionCapabilityRequired(ScalarText(TaskSchemas.identifier)) }
            return try await work(input, TaskContext(inline: context))
        }
    }

    // MARK: Creation and execution

    /// Starts a task from inside any `tools/call` provider, for example on the final round
    /// of a multi-round (MRTR) tool: return `.supplemental(result)` from that round. Answers
    /// gathered in earlier rounds can be captured by `work`. Throws
    /// `ExtensionCapabilityRequired` when the request did not negotiate the extension.
    /// - Parameter outputSchema: the tool's `outputSchema`, if any, to validate the result.
    public func start(_ input: JSONPresence<JSON>, context: RequestContext, outputSchema: JSON? = nil,
                      work: @escaping TaskWork) async throws -> JSON {
        guard context.extensions[TaskSchemas.identifier] != nil else { throw ExtensionCapabilityRequired(ScalarText(TaskSchemas.identifier)) }
        return try await create(input: input, request: context, output: outputSchema, work: work)
    }

    func create(input: JSONPresence<JSON>, request: RequestContext, output: JSON? = nil, work: @escaping TaskWork) async throws -> JSON {
        guard jobs != nil else { throw TaskRuntimeError.notRunning }
        await expireBatch()
        let owner = TaskOwner(request.principal)
        let current = now()
        guard try await store.count(owner: nil, now: current) < configuration.maximumTasks,
              try await store.count(owner: owner, now: current) < configuration.maximumTasksPerPrincipal else { throw TaskRuntimeError.capacity }
        let id = Self.makeIdentifier()
        let record = TaskRecord(id: id, owner: owner, created: current, expires: current.addingTimeInterval(Self.seconds(configuration.timeToLive)),
                                updated: current)
        // The record is durable before the reply, so tasks/get resolves as soon as the client sees the ID.
        do { try await store.create(record) }
        catch TaskStoreError.outcomeUnknown {
            guard try await store.load(id: id, owner: owner, now: now()) != nil else { throw TaskStoreError.outcomeUnknown }
        }
        let (cancellation, cancel) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let context = TaskContext(id: id, runtime: self, budget: try RequestBudget(workUnits: configuration.taskWork), request: request)
        guard let jobs else {
            await failUnstarted(id, owner)
            throw TaskRuntimeError.notRunning
        }
        local[id] = (owner, cancel)
        if case .terminated = jobs.yield(Job(id: id, input: input, output: output, work: work, context: context, cancellation: cancellation)) {
            local[id] = nil
            await failUnstarted(id, owner)
            throw TaskRuntimeError.notRunning
        }
        let task = try await taskObject(record, detailed: false, budget: request.budget)
        // CreateTaskResult = Result & Task: flat task fields, never requestState or inputRequests.
        return try await RuntimeJSON.overlay(task, members: [.init("resultType", value: .string("task"))], budget: request.budget)
    }

    /// A stored task whose work never started (the runtime stopped meanwhile).
    private func failUnstarted(_ id: String, _ owner: TaskOwner) async {
        _ = try? await mutate(id, owner) { task in
            task.status = .failed; task.failure = TaskFailure(message: "Task runtime stopped"); return true
        }
    }

    private static func execute(_ job: Job) async {
        let outcome = await withTaskGroup(of: Outcome?.self) { group -> Outcome in
            group.addTask {
                do {
                    let result = try await job.work(job.input, job.context)
                    guard let runtime = job.context.runtime else { return .completed(result) }
                    return await runtime.checked(result, outputSchema: job.output, budget: job.context.budget)
                }
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

    // MARK: Result validation

    private var callToolResultPlan: WireDefinitionPlan?

    /// Task results get the same checks as synchronous tool results: a frozen
    /// `CallToolResult` and, when the tool declares one, an `outputSchema`-valid
    /// `structuredContent`. Anything else ends the task as `failed` (`-32603`).
    func checked(_ result: JSON, outputSchema: JSON?, budget: RequestBudget) async -> Outcome {
        let invalid = Outcome.failed(TaskFailure(message: "Task produced an invalid result"))
        do {
            guard result.objectValue?["resultType"]?.stringValue == "complete" else { return invalid }
            let plan: WireDefinitionPlan
            if let cached = callToolResultPlan { plan = cached }
            else {
                let data = try FrozenWireSchema.read(maximumBytes: FrozenWireSchema.byteCount)
                let document = try await budget.performJSON { try FrozenWireSchema.parse(data, limits: $0) }
                let root = try await budget.performJSON { try document.root(at: .CallToolResult, limits: $0) }
                plan = try await budget.performJSON { try WireDefinitionPlan.compile(root, limits: $0) }
                callToolResultPlan = plan
            }
            guard try await budget.performJSON({ try plan.validate(result, limits: $0) }) else { return invalid }
            if let outputSchema {
                guard let structured = result.objectValue?["structuredContent"] else { return invalid }
                let compiled = try await budget.performJSON { try JSONSchemaCompiler(options: .init(limits: $0)).compileWithReport(outputSchema, registry: .empty) }
                let outcome = try await budget.performJSON { try JSONSchemaValidator(options: .init(limits: $0, output: .flag)).validateWithReport(structured, against: compiled) }
                guard outcome.isValid else { return invalid }
            }
            return .completed(result)
        } catch { return invalid }
    }

    func settle(_ id: String, _ outcome: Outcome) async {
        guard let entry = local.removeValue(forKey: id) else { return }
        entry.cancel.finish()
        // A requested cancellation already stored `cancelled`, which is terminal: it stays that way.
        _ = try? await mutate(id, entry.owner) { task in
            guard !task.status.isTerminal else { return false }
            switch outcome {
            case .completed(let result):
                if result.objectValue?["resultType"]?.stringValue == "complete" { task.status = .completed; task.result = result }
                else { task.status = .failed; task.failure = TaskFailure(message: "Task produced an invalid result") }
            case .failed(let failure): task.status = .failed; task.failure = failure; task.statusMessage = failure.message
            case .cancelled: task.status = .cancelled
            }
            task.inputRequests = []
            return true
        }
        let suspended = mailboxes.withLock { table -> [CheckedContinuation<JSON, any Error>] in
            let keys = table.keys.filter { $0.hasPrefix(id + "/") }
            return keys.compactMap { key in
                if case .waiting(let continuation) = table.removeValue(forKey: key) { return continuation }
                return nil
            }
        }
        for waiter in suspended { waiter.resume(throwing: CancellationError()) }
    }

    // MARK: Context operations

    func setMessage(_ id: String, _ message: String?) async {
        guard let owner = local[id]?.owner else { return }
        _ = try? await mutate(id, owner) { task in
            guard !task.status.isTerminal else { return false }
            task.statusMessage = message; return true
        }
    }

    func requestInput(_ id: String, _ request: JSON) async throws -> JSON {
        guard let owner = local[id]?.owner else { throw CancellationError() }
        var key = ""
        // Keys are never reused within a task: the counter is part of the stored record.
        let stored = try await mutate(id, owner) { task in
            guard !task.status.isTerminal else { return false }
            key = "input-\(task.nextInput)"
            task.nextInput += 1
            task.inputRequests.append(TaskInputRequest(key: key, request: request)); task.status = .inputRequired
            return true
        }
        guard let stored, !stored.status.isTerminal, !key.isEmpty else { throw CancellationError() }
        let slot = id + "/" + key
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, any Error>) in
                // The answer may already have arrived while the request was being stored.
                let early: JSON? = mailboxes.withLock { table in
                    if case .answered(let answer) = table[slot] { table[slot] = nil; return answer }
                    table[slot] = .waiting(continuation); return nil
                }
                if let early { continuation.resume(returning: early) }
                else if Task.isCancelled, case .waiting(let waiter)? = mailboxes.withLock({ $0.removeValue(forKey: slot) }) {
                    waiter.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            if case .waiting(let waiter)? = mailboxes.withLock({ $0.removeValue(forKey: slot) }) { waiter.resume(throwing: CancellationError()) }
        }
    }

    // MARK: Protocol methods

    func get(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        let record = try await lookup(input, context)
        let task = try await taskObject(record, detailed: true, budget: context.budget)
        return try await RuntimeJSON.overlay(task, members: [.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    func update(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        let record = try await lookup(input, context)
        if let responses = input.json?.objectValue?["inputResponses"]?.objectValue, !record.status.isTerminal {
            var accepted: [(key: String, answer: JSON)] = []
            // Unknown, answered or superseded keys are ignored. Removing a key is a
            // compare-and-set on the record, so each key is answered exactly once.
            _ = try await mutate(record.id, record.owner) { task in
                accepted = []
                guard !task.status.isTerminal else { return false }
                for response in responses {
                    guard let index = task.inputRequests.firstIndex(where: { $0.key == response.key.string }) else { continue }
                    task.inputRequests.remove(at: index)
                    accepted.append((response.key.string, response.value))
                }
                guard !accepted.isEmpty else { return false }
                if task.inputRequests.isEmpty, task.status == .inputRequired { task.status = .working }
                return true
            }
            let running = local[record.id] != nil
            for (key, answer) in accepted {
                let slot = record.id + "/" + key
                let waiter: CheckedContinuation<JSON, any Error>? = mailboxes.withLock { table in
                    if case .waiting(let continuation) = table.removeValue(forKey: slot) { return continuation }
                    // Only work running in this process can consume an early answer.
                    if running { table[slot] = .answered(answer) }
                    return nil
                }
                waiter?.resume(returning: answer)
            }
        }
        return try await RuntimeJSON.object([.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    func cancel(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        let record = try await lookup(input, context)
        _ = try await mutate(record.id, record.owner) { task in
            guard !task.status.isTerminal else { return false }
            task.status = .cancelled; task.cancellationRequested = true; task.inputRequests = []
            return true
        }
        local[record.id]?.cancel.yield()
        return try await RuntimeJSON.object([.init("resultType", value: .string("complete"))], budget: context.budget)
    }

    /// Unknown, expired and other principals' tasks are indistinguishable: `-32602`.
    private func lookup(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> TaskRecord {
        await expireBatch()
        guard let id = input.json?.objectValue?["taskId"]?.stringValue,
              let record = try await store.load(id: id, owner: TaskOwner(context.principal), now: now()) else { throw CoreFailure.invalidInput }
        return record
    }

    /// Removes a bounded batch of expired tasks and cancels their local work.
    private func expireBatch() async {
        guard let expired = try? await store.expire(now: now(), limit: 64) else { return }
        for id in expired { local[id]?.cancel.yield() }
    }

    // MARK: Store access

    /// Loads, changes and stores one task with compare-and-set, retrying on concurrent
    /// changes. `change` returns false to leave the task as it is. Returns the stored
    /// record, or nil when the task is unknown.
    @discardableResult
    func mutate(_ id: String, _ owner: TaskOwner, _ change: (inout TaskRecord) -> Bool) async throws -> TaskRecord? {
        for _ in 0..<8 {
            guard var record = try await store.load(id: id, owner: owner, now: now()) else { return nil }
            let expected = record.version
            guard change(&record) else { return record }
            record.updated = now()
            switch try await store.update(record, expectedVersion: expected, now: now()) {
            case .updated(let version):
                record.version = version
                changed([(id, owner)])
                return record
            case .conflict: continue
            case .terminal, .notFound: return try await store.load(id: id, owner: owner, now: now())
            }
        }
        throw TaskRuntimeError.storeContention
    }

    // MARK: Status notifications

    /// The requested task IDs that `context`'s principal owns; others are silently not agreed.
    func subscribable(_ ids: [String], _ context: RequestContext) async throws -> [String] {
        await expireBatch()
        let owner = TaskOwner(context.principal)
        var agreed: [String] = []
        for id in ids where try await store.load(id: id, owner: owner, now: now()) != nil { agreed.append(id) }
        return agreed
    }

    /// Queues the current state of these tasks for delivery.
    func changed(_ tasks: [(String, TaskOwner)]) {
        guard let notifier else { return }
        for (id, owner) in tasks where !pending.contains(where: { $0.id == id }) { pending.append((id, owner)) }
        notifier.yield()
    }

    /// Takes the next task to deliver with its current `DetailedTask` (without `resultType`).
    func nextNotification() async -> (id: String, owner: TaskOwner, task: JSON)? {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            guard let record = try? await store.load(id: next.id, owner: next.owner, now: now()),
                  let budget = try? RequestBudget(workUnits: configuration.taskWork),
                  let task = try? await taskObject(record, detailed: true, budget: budget) else { continue }
            return (next.id, next.owner, task)
        }
        return nil
    }

    private nonisolated func deliver(_ signal: AsyncStream<Void>) async {
        for await _ in signal {
            while let next = await nextNotification() {
                // A failing stream is closed by the server; other streams and the task are unaffected.
                try? await relay.publish(ScalarText("notifications/tasks"), filter: ScalarText("taskIds"), member: next.id,
                                         principal: next.owner.principal, parameters: next.task)
            }
        }
    }

    // MARK: Encoding

    private func taskObject(_ record: TaskRecord, detailed: Bool, budget: RequestBudget) async throws -> JSON {
        var members: [JSONMember] = [
            .init("taskId", value: .string(record.id)),
            .init("status", value: .string(record.status.rawValue)),
            .init("createdAt", value: .string(record.created.ISO8601Format())),
            .init("lastUpdatedAt", value: .string(record.updated.ISO8601Format())),
            .init("ttlMs", value: .number(JSONNumber(integer: Self.milliseconds(configuration.timeToLive)))),
            .init("pollIntervalMs", value: .number(JSONNumber(integer: Self.milliseconds(configuration.pollInterval)))),
        ]
        if let message = record.statusMessage { members.append(.init("statusMessage", value: .string(message))) }
        if detailed {
            if let result = record.result, record.status == .completed { members.append(.init("result", value: result)) }
            if let failure = record.failure, record.status == .failed {
                let error = try await RuntimeJSON.object([.init("code", value: .number(JSONNumber(integer: failure.code))),
                    .init("message", value: .string(failure.message))], budget: budget)
                members.append(.init("error", value: error))
            }
            if record.status == .inputRequired {
                let requests = try await RuntimeJSON.object(record.inputRequests.map { .init($0.key, value: $0.request) }, budget: budget)
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
    static func seconds(_ duration: Duration) -> TimeInterval {
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
