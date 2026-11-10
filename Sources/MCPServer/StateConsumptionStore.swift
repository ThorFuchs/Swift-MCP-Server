// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol

/// Replay consumption is separate from state integrity. The host commits only
/// after its side-effect boundary, preferably in its own transaction. Releasing
/// a claim after an effect cannot guarantee exactly-once execution.
public actor StateConsumptionStore {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, invalidKey, expired, alreadyClaimed, full, invalidClaim
    }
    public struct Claim: Sendable {
        fileprivate let key: [UInt8]
        let owner: UUID
    }
    private struct Entry {
        let owner: UUID
        let expiry: Int64
        let weight: Int
        var committed: Bool
    }
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let maximumKeyBytes: Int
    private let now: @Sendable () -> Int64
    private var entries: [[UInt8]: Entry] = [:]
    private var retained = 0
    var receipts: [ScalarText: Claim] = [:]
    nonisolated let operationAllowance: UInt64

    public init(maximumEntries: Int = 4096, maximumBytes: Int = 8_388_608,
                maximumKeyBytes: Int = 1024, now: @escaping @Sendable () -> Int64) throws {
        guard maximumEntries > 0, maximumBytes > 0, maximumKeyBytes > 0,
              maximumKeyBytes <= maximumBytes - min(maximumBytes, 96) else { throw Failure.invalidLimit }
        guard maximumEntries <= 65536, maximumKeyBytes <= 16384 else { throw Failure.invalidLimit }
        operationAllowance = UInt64(maximumEntries) * UInt64(maximumKeyBytes + 384) * 2 + 1024
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.maximumKeyBytes = maximumKeyBytes
        self.now = now
    }
    public var count: Int { entries.count }
    public var retainedBytes: Int { retained }

    public func claim(key: [UInt8], expiresAt: Int64) throws -> Claim {
        try claim(key: key, expiresAt: expiresAt, receiptWeight: 0)
    }
    func claim(key: [UInt8], expiresAt: Int64, receiptWeight: Int) throws -> Claim {
        guard !key.isEmpty, key.count <= maximumKeyBytes else { throw Failure.invalidKey }
        let instant = now()
        purgeExpired(at: instant)
        guard instant >= 0, expiresAt > instant else { throw Failure.expired }
        guard entries[key] == nil else { throw Failure.alreadyClaimed }
        let weight = key.count + 96 + receiptWeight
        guard entries.count < maximumEntries, weight <= maximumBytes - retained else { throw Failure.full }
        let owner = UUID()
        entries[key] = Entry(owner: owner, expiry: expiresAt, weight: weight, committed: false)
        retained += weight
        return Claim(key: key, owner: owner)
    }
    public func commit(_ claim: Claim) throws {
        purgeExpired(at: now())
        guard var entry = entries[claim.key], entry.owner == claim.owner, !entry.committed else {
            throw Failure.invalidClaim
        }
        entry.committed = true
        entries[claim.key] = entry
    }
    public func release(_ claim: Claim) throws {
        purgeExpired(at: now())
        guard let entry = entries[claim.key], entry.owner == claim.owner, !entry.committed else {
            throw Failure.invalidClaim
        }
        entries.removeValue(forKey: claim.key)
        retained -= entry.weight
    }
    private func purgeExpired(at instant: Int64) {
        let expired = entries.filter { $0.value.expiry <= instant }
        for (key, entry) in expired {
            entries.removeValue(forKey: key)
            receipts.removeValue(forKey: ScalarText(entry.owner.uuidString))
            retained -= entry.weight
        }
    }
}
