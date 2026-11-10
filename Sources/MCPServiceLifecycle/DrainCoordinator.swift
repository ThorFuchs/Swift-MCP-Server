// SPDX-License-Identifier: Apache-2.0
import Synchronization

public enum LifecycleFailure: Error, Sendable, Equatable {
    case invalidConfiguration, alreadyRun, stopped, startupDeadline, drainDeadline
    case componentFailed(Int), unexpectedCompletion(Int), duplicateReadiness, invalidClock, invalidReadiness
}
/// Monotonic host seam. Implementations and callbacks must cooperate with task
/// cancellation. Wall time, signal handling and process termination are not owned.
public protocol LifecycleClock: Sendable {
    func nowMilliseconds() -> Int64
    func sleep(untilMilliseconds: Int64) async throws
}
public struct ContinuousLifecycleClock: LifecycleClock {
    private let start = ContinuousClock.now
    public init() {}
    public func nowMilliseconds() -> Int64 {
        let c = start.duration(to: .now).components
        let s = c.seconds.multipliedReportingOverflow(by: 1000)
        let n = s.partialValue.addingReportingOverflow(c.attoseconds / 1_000_000_000_000_000)
        return s.overflow || n.overflow ? Int64.max : max(0, n.partialValue)
    }
    public func sleep(untilMilliseconds end: Int64) async throws {
        try Task.checkCancellation()
        let now = nowMilliseconds()
        if end > now { try await Task.sleep(for: .milliseconds(end - now)) }
    }
}

// Private cancellation-aware broadcast completion. A cancelled waiter never
// consumes another waiter's completion and leaves no retained cancellation ID.
final class LifecycleLatch: Sendable {
    private final class Waiter: Sendable {
        enum State { case empty, waiting(CheckedContinuation<Void, Never>), finished }
        let state = Mutex(State.empty)
        func install(_ c: CheckedContinuation<Void, Never>) {
            let resume = state.withLock { s in
                if case .finished = s { return true }; s = .waiting(c); return false
            }
            if resume { c.resume() }
        }
        func finish() {
            let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
                defer { s = .finished }; if case .waiting(let c) = s { return c }; return nil
            }
            c?.resume()
        }
    }
    private struct State { var finished = false; var waiters: [Int: Waiter] = [:]; var next = 0 }
    private let state = Mutex(State())
    var finished: Bool { state.withLock { $0.finished } }
    func finish() {
        let waiters = state.withLock { s -> [Waiter] in
            s.finished = true; let w = Array(s.waiters.values); s.waiters.removeAll(); return w
        }
        for waiter in waiters { waiter.finish() }
    }
    func wait() async -> Bool {
        let waiter = Waiter()
        let token = state.withLock { s -> Int? in
            if s.finished { return nil }
            let key = s.next; s.next += 1; s.waiters[key] = waiter; return key
        }
        guard let token else { return true }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.install($0) }
        } onCancel: { waiter.finish() }
        _ = state.withLock { $0.waiters.removeValue(forKey: token) }
        return finished
    }
}

/// Finite policies govern escalation, not preemption of arbitrary host code.
public struct DrainCoordinator: Sendable {
    public let startupMilliseconds: Int64, drainMilliseconds: Int64
    public let clock: any LifecycleClock
    public init(startupMilliseconds: Int64 = 30_000, drainMilliseconds: Int64 = 10_000,
                clock: any LifecycleClock = ContinuousLifecycleClock()) throws {
        guard (1...120_000).contains(startupMilliseconds), (1...30_000).contains(drainMilliseconds) else { throw LifecycleFailure.invalidConfiguration }
        self.startupMilliseconds = startupMilliseconds; self.drainMilliseconds = drainMilliseconds; self.clock = clock
    }
    func deadline(after milliseconds: Int64) throws -> Int64 {
        let now = clock.nowMilliseconds(), sum = now.addingReportingOverflow(milliseconds)
        guard now >= 0, !sum.overflow else { throw LifecycleFailure.invalidClock }; return sum.partialValue
    }
    func wait(_ completion: LifecycleLatch, until deadline: Int64) async -> Bool {
        if completion.finished { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await completion.wait() }
            group.addTask { [clock] in
                do { try await clock.sleep(untilMilliseconds: deadline) } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll(); return result && completion.finished
        }
    }
}
