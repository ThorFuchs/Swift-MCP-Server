// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol

public struct ConsumptionClaim: Sendable {
    public let handle: ScalarText
    public init(handle: ScalarText) { self.handle = handle }
}
/// Host durability/transactions define the scope of single consumption. All
/// methods must cooperate with cancellation and account their own I/O/work.
public protocol ContinuationConsumption: Sendable {
    var maximumSettlementWork: UInt64 { get }
    func claim(key: [UInt8], expiresAt: Int64, budget: RequestBudget) async throws -> ConsumptionClaim
    func commit(_ claim: ConsumptionClaim, budget: RequestBudget) async throws
    func release(_ claim: ConsumptionClaim, budget: RequestBudget) async throws
}
public actor ContinuationEffect {
    private let store: any ContinuationConsumption
    private let claim: ConsumptionClaim
    private let cleanup: RequestBudget
    private var settled = false, released = false, settlementFailed = false
    init(store: any ContinuationConsumption, claim: ConsumptionClaim, cleanup: RequestBudget) {
        self.store = store; self.claim = claim; self.cleanup = cleanup
    }
    /// An explicit host assertion that no effect occurred and retry is safe.
    /// A released invocation cannot subsequently return a successful outcome.
    public func releaseForSafeRetry() async throws {
        guard !settled else { throw CoreFailure.invalidState }; settled = true
        settlementFailed = true
        try await store.release(claim, budget: cleanup)
        released = true; settlementFailed = false
    }
    func finish(allowReleased: Bool = false) async throws {
        if settled {
            guard !settlementFailed else { throw CoreFailure.invalidOutput }
            guard !released || allowReleased else { throw CoreFailure.invalidOutput }; return
        }
        settled = true; settlementFailed = true
        try await store.commit(claim, budget: cleanup); settlementFailed = false
    }
    func abandonBeforeProvider() async throws {
        if !settled { settled = true; try await store.release(claim, budget: cleanup); released = true }
    }
}
extension StateConsumptionStore: ContinuationConsumption {
    public nonisolated var maximumSettlementWork: UInt64 { operationAllowance }
    public func claim(key: [UInt8], expiresAt: Int64, budget: RequestBudget) async throws -> ConsumptionClaim {
        try await budget.consume(operationAllowance + UInt64(key.count))
        let owned = try claim(key: key, expiresAt: expiresAt, receiptWeight: key.count + 256)
        let handle = ScalarText(owned.owner.uuidString)
        receipts[handle] = owned
        return .init(handle: handle)
    }
    public func commit(_ claim: ConsumptionClaim, budget: RequestBudget) async throws {
        try await budget.consume(operationAllowance)
        guard let owned = receipts[claim.handle] else { throw Failure.invalidClaim }
        try commit(owned); receipts.removeValue(forKey: claim.handle)
    }
    public func release(_ claim: ConsumptionClaim, budget: RequestBudget) async throws {
        try await budget.consume(operationAllowance)
        guard let owned = receipts[claim.handle] else { throw Failure.invalidClaim }
        try release(owned); receipts.removeValue(forKey: claim.handle)
    }
}
