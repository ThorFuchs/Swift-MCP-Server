// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Finite FIFO admission. The caller owns the provider child task and releases
/// its permit on every completion path. Stop rejects queued and future work.
public actor AdmissionController {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, saturated, stopped, invalidPermit
    }
    public struct Permit: Sendable { fileprivate let id: UUID }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Permit, any Error>
    }
    private let capacity: Int
    private let queueCapacity: Int
    private var active: Set<UUID> = []
    private var queue: [Waiter] = []
    private var stopped = false

    public init(activeLimit: Int, queueLimit: Int) throws {
        guard activeLimit > 0, queueLimit > 0 else { throw Failure.invalidLimit }
        capacity = activeLimit
        queueCapacity = queueLimit
    }
    public var activeCount: Int { active.count }
    public var queuedCount: Int { queue.count }

    public func acquire() async throws -> Permit {
        try Task.checkCancellation()
        guard !stopped else { throw Failure.stopped }
        let id = UUID()
        if active.count < capacity {
            active.insert(id)
            return Permit(id: id)
        }
        guard queue.count < queueCapacity else { throw Failure.saturated }
        // The short cancellation bridge transfers the queued continuation to
        // this actor; it starts no provider/I/O and captures no host resources.
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do {
            try Task.checkCancellation()
            return permit
        } catch {
            try release(permit)
            throw error
        }
    }
    public func release(_ permit: Permit) throws {
        guard active.remove(permit.id) != nil else { throw Failure.invalidPermit }
        if !stopped, !queue.isEmpty {
            let waiter = queue.removeFirst()
            active.insert(waiter.id)
            waiter.continuation.resume(returning: Permit(id: waiter.id))
        }
    }
    public func stop() {
        guard !stopped else { return }
        stopped = true
        let pending = queue
        queue.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.continuation.resume(throwing: Failure.stopped) }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
