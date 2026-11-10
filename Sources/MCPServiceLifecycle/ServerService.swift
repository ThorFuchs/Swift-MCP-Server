// SPDX-License-Identifier: Apache-2.0
import ServiceLifecycle
import MCPServer
import Logging
import Synchronization

/// One-shot, dependency-ordered embedded runtime. Run owns every child and returns
/// only after they join. Request shutdown separately and await the caller-owned run.
public actor ServerService: Service {
    private enum Event: Sendable { case ready(Int), ended(Int), stop, startupExpired }
    private final class Child: Sendable {
        let cancel = LifecycleLatch(), done = LifecycleLatch()
        let failure = Mutex<LifecycleFailure?>(nil)
    }
    public struct Report: Sendable {
        public let started: Int, joined: Int, escalated: Int
        public let failure: LifecycleFailure?
    }
    private let readinessOwner = Readiness()
    public nonisolated var readiness: RuntimeReadiness { .init(readinessOwner) }
    private let components: [TransportService], policy: DrainCoordinator
    private let stopAdmission: @Sendable () async -> Void
    private let events: AsyncStream<Event>, signal: AsyncStream<Event>.Continuation
    private let shutdownRequested = Mutex(false)
    private var used = false, ready: Set<Int> = [], started: Set<Int> = []
    private var children: [Int: Child] = [:]
    private var runFailure: LifecycleFailure?, forcedIndices: Set<Int> = []
    public private(set) var report = Report(started: 0, joined: 0, escalated: 0, failure: nil)
    public init(components: [TransportService], policy: DrainCoordinator? = nil,
                stopAdmission: @escaping @Sendable () async -> Void = {}) throws {
        guard (1...64).contains(components.count), Set(components.map(\.name)).count == components.count else { throw LifecycleFailure.invalidConfiguration }
        let names = Set(components.map(\.name))
        guard components.allSatisfy({ Set($0.dependencies).isSubset(of: names) }) else { throw LifecycleFailure.invalidConfiguration }
        var ordered: [TransportService] = [], pending = components
        while !pending.isEmpty {
            let available = Set(ordered.map(\.name))
            guard let index = pending.firstIndex(where: { Set($0.dependencies).isSubset(of: available) }) else { throw LifecycleFailure.invalidConfiguration }
            ordered.append(pending.remove(at: index))
        }
        self.components = ordered; self.policy = try policy ?? DrainCoordinator(); self.stopAdmission = stopAdmission
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(components.count * 2 + 3))
        events = pair.stream; signal = pair.continuation
    }
    /// Indicates ownership of this core's admission. Shared cores should use the
    /// closure initializer with a connection-specific stop seam instead.
    public init(server: Server, components: [TransportService], policy: DrainCoordinator? = nil) throws {
        try self.init(components: components, policy: policy, stopAdmission: {
            await server.stopAdmission(); await server.closeSubscriptions()
        })
    }
    public nonisolated func requestShutdown() {
        let first = shutdownRequested.withLock { s in if s { return false }; s = true; return true }
        if first { signal.yield(.stop) }
    }
    private func markReady(_ index: Int) throws {
        guard !shutdownRequested.withLock({ $0 }), started.contains(index), ready.insert(index).inserted else { throw LifecycleFailure.duplicateReadiness }
        signal.yield(.ready(index))
    }
    private func force(_ index: Int) {
        guard forcedIndices.insert(index).inserted, let child = children[index] else { return }
        if !Task.isCancelled { runFailure = runFailure ?? .drainDeadline }
        report = .init(started: started.count, joined: children.values.filter { $0.done.finished }.count,
                       escalated: forcedIndices.count, failure: runFailure)
        components[index].forceClose(); child.cancel.finish()
    }
    private func boundedStop(_ operation: @escaping @Sendable () async -> Void,
                             deadline: Int64?, onDeadline: () async -> Void) async {
        let done = LifecycleLatch()
        await withTaskGroup(of: Void.self) { callbacks in
            callbacks.addTask { await operation(); done.finish() }
            let finished: Bool
            if let deadline, !Task.isCancelled { finished = await policy.wait(done, until: deadline) }
            else { finished = false }
            if !finished { await onDeadline() }
            callbacks.cancelAll()
            // Even an uncooperative host callback remains an owned child. The
            // escalation is visible before joining it; cancellation is not preemption.
        }
    }
    public func run() async throws {
        guard !used else { throw LifecycleFailure.alreadyRun }; used = true
        guard !shutdownRequested.withLock({ $0 }) else { await readinessOwner.stop(); throw LifecycleFailure.stopped }
        let startup: Int64
        do { startup = try policy.deadline(after: policy.startupMilliseconds) }
        catch { await readinessOwner.fail(); throw error }
        let startupComplete = LifecycleLatch()
        await withGracefulShutdownHandler {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [policy, signal] in
                        if !(await policy.wait(startupComplete, until: startup)), !Task.isCancelled, !startupComplete.finished { signal.yield(.startupExpired) }
                    }
                    func launchAvailable() {
                        guard !shutdownRequested.withLock({ $0 }), !Task.isCancelled else { return }
                        let readyNames = Set(ready.map { components[$0].name })
                        for index in components.indices where !started.contains(index) && Set(components[index].dependencies).isSubset(of: readyNames) {
                            started.insert(index)
                            let child = Child(), component = components[index]; children[index] = child
                            group.addTask { [signal] in
                                await withTaskGroup(of: Void.self) { work in
                                    work.addTask {
                                        do { try await component.operation { try await self.markReady(index) } }
                                        catch is CancellationError { /* owning cancellation is recorded by run */ }
                                        catch { child.failure.withLock { $0 = .componentFailed(index) } }
                                    }
                                    work.addTask { _ = await child.cancel.wait() }
                                    _ = await work.next(); work.cancelAll()
                                }
                                child.done.finish(); signal.yield(.ended(index))
                            }
                        }
                    }
                    launchAvailable()
                    for await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .ready:
                            if ready.count == components.count {
                                startupComplete.finish()
                                do { try await readinessOwner.markReady() }
                                catch { runFailure = .invalidReadiness }
                            }
                            launchAvailable()
                        case .ended(let index):
                            runFailure = children[index]?.failure.withLock { $0 }
                            if runFailure == nil && (!ready.contains(index) || components[index].completion == .unexpected) { runFailure = .unexpectedCompletion(index) }
                        case .startupExpired: runFailure = .startupDeadline
                        case .stop: break
                        }
                        if case .ready = event, runFailure == nil { continue }; break
                    }
                    startupComplete.finish()
                    let deadline: Int64?
                    do { deadline = try policy.deadline(after: policy.drainMilliseconds) }
                    catch { deadline = nil; runFailure = runFailure ?? .invalidClock }
                    await readinessOwner.beginDrain()
                    await boundedStop(stopAdmission, deadline: deadline) {
                        for index in components.indices.reversed() where started.contains(index) { force(index) }
                    }
                    for index in components.indices.reversed() where started.contains(index) {
                        guard let child = children[index] else { continue }
                        if forcedIndices.contains(index) { _ = await child.done.wait(); continue }
                        await boundedStop(components[index].stop, deadline: deadline) { force(index) }
                        let drained: Bool
                        if let deadline, !Task.isCancelled { drained = await policy.wait(child.done, until: deadline) }
                        else { drained = false }
                        if !drained {
                            force(index)
                            _ = await child.done.wait()
                        }
                    }
                    group.cancelAll()
                }
            } onCancel: { self.requestShutdown() }
        } onGracefulShutdown: { self.requestShutdown() }
        signal.finish()
        report = .init(started: started.count, joined: children.values.filter { $0.done.finished }.count, escalated: forcedIndices.count, failure: runFailure)
        children.removeAll()
        if Task.isCancelled { await readinessOwner.stop(); throw CancellationError() }
        if let runFailure { await readinessOwner.fail(); throw runFailure }
        await readinessOwner.stop(); try Task.checkCancellation()
    }
}

/// The embedded configuration cannot reach the candidate's maximum-cancellation
/// fatalError: it sets that timer to nil and installs no Unix signals. The owned
/// ServerService supplies finite startup/drain escalation and cooperative joining.
public struct EmbeddedServerGroup: Service {
    private let group: ServiceGroup
    public init(service: ServerService, logger: Logger) {
        var clean = logger; clean.handler.metadata = [:]; if clean.handler.metadataProvider != nil { clean.handler.metadataProvider = nil }
        var configuration = ServiceGroupConfiguration(services: [.init(service: service,
            successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .cancelGroup, serviceName: "mcp-server")], logger: clean)
        configuration.gracefulShutdownSignals = []; configuration.cancellationSignals = []
        configuration.maximumGracefulShutdownDuration = nil; configuration.maximumCancellationDuration = nil
        group = ServiceGroup(configuration: configuration)
    }
    public func run() async throws { try await group.run() }
    public func requestShutdown() async { await group.triggerGracefulShutdown() }
}
