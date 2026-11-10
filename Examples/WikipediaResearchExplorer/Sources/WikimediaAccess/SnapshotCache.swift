// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Actor-owned deterministic LRU. Content bytes are logical UTF8 charges from
/// normalization, not a measurement or proof of Swift heap allocation.
public actor SnapshotCache {
    private struct Entry: Sendable { let snapshot: Snapshot; let expires: Date; var used: UInt64 }
    private var entries: [SnapshotID: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    private var lastNow: Date?
    private let limits: ExplorerLimits
    public init(limits: ExplorerLimits) { self.limits = limits }
    private func advance(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw Self.absent() }
        if let previous = lastNow, now < previous { entries.removeAll(); bytes = 0 }
        lastNow = now
        let expired = entries.filter { $0.value.expires <= now }.map(\.key)
        for key in expired { if let old = entries.removeValue(forKey: key) { bytes -= old.snapshot.contentBytes } }
        guard tick < UInt64.max else { throw ExplorerProblem(.budgetExceeded, "Cache sequence exhausted.", recovery: "Create a fresh service instance.") }
        tick += 1
    }
    public func insert(_ snapshot: Snapshot, now: Date) throws {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw Self.absent() }
        guard snapshot.contentBytes >= 0, snapshot.contentBytes <= limits.cacheContentBytes else {
            throw ExplorerProblem(.budgetExceeded, "Snapshot exceeds cache content capacity.", recovery: "Use a smaller bounded snapshot.")
        }
        let key = snapshot.provenance.identity
        // Finish validation BEFORE expiry, removal, eviction, LRU or clock mutation.
        if let old = entries[key], !(try old.snapshot.hasSameResearchContent(as: snapshot)) {
            throw PublicProblems.project(.invalidFixture)
        }
        try advance(now: now)
        if let old = entries.removeValue(forKey: key) { bytes -= old.snapshot.contentBytes }
        while entries.count >= limits.cacheEntries || bytes > limits.cacheContentBytes - snapshot.contentBytes {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                  let old = entries.removeValue(forKey: oldest) else { throw Self.absent() }
            bytes -= old.snapshot.contentBytes
        }
        entries[key] = .init(snapshot: snapshot, expires: now.addingTimeInterval(limits.snapshotTTL), used: tick)
        bytes += snapshot.contentBytes
    }
    public func get(_ key: SnapshotID, now: Date) throws -> Snapshot {
        try Task.checkCancellation(); try advance(now: now)
        guard var entry = entries[key] else { throw Self.absent() }
        entry.used = tick; entries[key] = entry; return entry.snapshot
    }
    public var accounting: (entries: Int, contentBytes: Int) { (entries.count, bytes) }
    private static func absent() -> ExplorerProblem {
        .init(.absentSnapshot, "Exact snapshot is expired, evicted or absent.", recovery: "Fetch a new outline; never substitute the provider's latest revision for this locator.")
    }
}
