// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation

/// The independent waiter is bounded even if an owner ignores cancellation.
/// A timed-out operation remains strongly owned and cannot overlap a new one.
@MainActor @Observable public final class AppTerminationController {
    public enum State: Sendable, Equatable { case active, quiescing, declined, committed }
    public private(set) var state = State.active
    public private(set) var unsettled = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var waiter: CheckedContinuation<Bool, Never>?
    public init() {}
    public func request(waitMilliseconds: Int = 10_000,
                        settle: @escaping @MainActor () async -> Bool,
                        recover: @escaping @MainActor () -> Void) async -> Bool {
        guard (1...10_000).contains(waitMilliseconds), operation == nil, waiter == nil, state != .committed else { return false }
        state = .quiescing; unsettled = true
        let result = await withCheckedContinuation { continuation in
            waiter = continuation
            operation = Task { [self] in
                let clean = await settle()
                unsettled = false; operation = nil
                if state == .quiescing {
                    state = clean ? .committed : .declined
                    finish(clean)
                    if !clean { recover() }
                } else {
                    // The user already received a decline; late joins permit
                    // recovery, never retroactive successful termination.
                    state = .active; recover()
                }
            }
            timer = Task { [self] in
                do { try await Task.sleep(for: .milliseconds(waitMilliseconds)) } catch { return }
                guard waiter != nil else { return }
                state = .declined; finish(false)
            }
        }
        timer?.cancel(); await timer?.value; timer = nil
        return result
    }
    /// Explicit owner join for controlled callers; never substitutes for the
    /// independent bounded UI termination waiter.
    public func waitUntilSettled() async { await operation?.value }
    private func finish(_ result: Bool) { let pending = waiter; waiter = nil; pending?.resume(returning: result) }
}
