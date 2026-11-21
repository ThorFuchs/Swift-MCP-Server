// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation

public struct LocalEndpoint: Sendable, Equatable {
    public let port: Int
    public init(port: Int = 8765) throws {
        guard (0...65535).contains(port) else { throw HostFailure.invalidConfiguration }
        self.port = port
    }
}
public struct ServerEndpoint: Sendable, Equatable {
    public let host: String, port: Int
    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1", (1...65535).contains(port) else { throw HostFailure.invalidConfiguration }
        self.host = host; self.port = port
    }
    public var url: String { "http://\(host):\(port)/mcp" }
}
public enum HostFailure: String, Error, Sendable { case invalidConfiguration, startFailed, catalogUnavailable, stopFailed, unexpectedStop, cleanupDebt }
public enum ServerPhase: String, Sendable { case stopped = "Stopped", starting = "Starting", running = "Running", stopping = "Stopping", failed = "Failed" }
public protocol ExplorerHTTPHost: Sendable {
    func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws
    func stop() async throws
}
@MainActor @Observable public final class ServerController {
    public private(set) var phase = ServerPhase.stopped
    public private(set) var endpoint: ServerEndpoint?
    public private(set) var failure: HostFailure?
    public private(set) var cleanupDebt = false
    public private(set) var runID: UUID?
    public var canStart: Bool { runTask == nil && transition == nil && !cleanupDebt }
    public var canStop: Bool { runTask != nil && transition == nil }
    @ObservationIgnored private let factory: @Sendable (UUID) throws -> any ExplorerHTTPHost
    @ObservationIgnored private let activity: ActivityStore
    @ObservationIgnored private var host: (any ExplorerHTTPHost)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var requestedStop = false
    @ObservationIgnored private var shutdownWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var shutdownTimer: Task<Void, Never>?
    public init(activity: ActivityStore, factory: @escaping @Sendable (UUID) throws -> any ExplorerHTTPHost) {
        self.activity = activity; self.factory = factory
    }
    public func start() {
        guard canStart else { return }
        let id = UUID(); generation &+= 1; let token = generation
        runID = id; requestedStop = false; failure = nil; endpoint = nil; phase = .starting
        do {
            let host = try factory(id); self.host = host
            runTask = Task { [self] in
                var result: HostFailure?
                do {
                    try await activity.beginRun(id)
                    try await host.run { [weak self] address in await self?.ready(address, generation: token) }
                } catch { result = (error as? HostFailure) ?? .startFailed }
                await activity.lifecycle(result == nil ? .joined : .runFailed)
                finished(token, failure: result)
            }
        } catch { failure = .startFailed; phase = .failed }
    }
    private func ready(_ endpoint: ServerEndpoint, generation token: UInt64) {
        guard token == generation, phase == .starting, !requestedStop else { return }
        self.endpoint = endpoint; phase = .running
    }
    private func finished(_ token: UInt64, failure: HostFailure?) {
        guard token == generation else { return }
        self.failure = failure ?? (requestedStop ? nil : .unexpectedStop)
        phase = self.failure == nil ? .stopped : .failed
        endpoint = nil; runTask = nil; cleanupDebt = failure == .cleanupDebt
        if !cleanupDebt { host = nil }
    }
    public func stop() { stop(restart: false) }
    public func restart() { stop(restart: true) }
    private func stop(restart: Bool) {
        guard transition == nil else { return }
        guard let host, let runTask else { if restart { start() }; return }
        requestedStop = true; phase = .stopping
        transition = Task { [self] in
            do {
                try await host.stop()
                await runTask.value
                transition = nil
                completeShutdownWaiter(self.runTask == nil && !cleanupDebt)
                if restart, !cleanupDebt, failure == nil { start() }
            } catch {
                // A rejected stop is not an observed join. Retain both owners.
                failure = .stopFailed; phase = .failed; cleanupDebt = true; transition = nil
                completeShutdownWaiter(false)
                await activity.lifecycle(.cleanupUnresolved)
            }
        }
    }
    /// A bounded UI wait does not manufacture a join. Deadline retains the host,
    /// run and transition, poisons new Start, and lets the app decline Quit.
    public func stopAndJoin(waitMilliseconds: Int = 10_000) async -> Bool {
        guard (1...10_000).contains(waitMilliseconds), shutdownWaiter == nil else { return false }
        stop()
        if transition == nil { return runTask == nil && !cleanupDebt }
        let result = await withCheckedContinuation { continuation in
            shutdownWaiter = continuation
            shutdownTimer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(waitMilliseconds)) } catch { return }
                guard let self, self.shutdownWaiter != nil else { return }
                self.cleanupDebt = true; self.failure = .cleanupDebt; self.phase = .failed
                self.completeShutdownWaiter(false)
            }
        }
        shutdownTimer?.cancel(); await shutdownTimer?.value; shutdownTimer = nil
        return result
    }
    private func completeShutdownWaiter(_ result: Bool) {
        let waiter = shutdownWaiter; shutdownWaiter = nil; waiter?.resume(returning: result)
    }
    public func awaitTransition() async { await transition?.value }
    public func waitUntilRunJoined() async { await runTask?.value }
}
