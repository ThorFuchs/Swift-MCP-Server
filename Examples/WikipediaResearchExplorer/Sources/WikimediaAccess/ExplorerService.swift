// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

public actor ExplorerService {
    public nonisolated let profile: SourceProfile
    private let provider: any ExplorerProvider
    private let cache: SnapshotCache
    private let limits: ExplorerLimits
    private let clock: @Sendable () -> Date
    private var inFlight = 0
    public init(provider: any ExplorerProvider, limits: ExplorerLimits,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = provider.profile; self.provider = provider; self.limits = limits; self.clock = clock; self.cache = .init(limits: limits)
    }
    public func search(_ input: SearchInput) async throws -> SearchPage {
        try allowed(input.project); try Task.checkCancellation()
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = input.limit ?? 10
        guard !query.isEmpty, query.utf8.count <= 256, (1...20).contains(limit) else { throw Self.arguments() }
        try admit(); defer { inFlight -= 1 }
        let result = try await provider.search(query: query, project: input.project, limit: limit)
        try Task.checkCancellation()
        guard result.candidates.count <= limit, result.query == query, result.provider == profile.provider,
              result.candidates.allSatisfy({ $0.project == input.project && Normalizer.component($0.id) && Normalizer.component($0.pageID)
                  && $0.title.utf8.count <= 512 && ($0.description?.utf8.count ?? 0) <= 1024 }),
              Set(result.candidates.map(\.id)).count == result.candidates.count else { throw Self.providerContract() }
        return result
    }
    public func outline(_ input: OutlineInput) async throws -> Outline {
        try allowed(input.project); try Task.checkCancellation()
        guard Normalizer.component(input.candidateID) else { throw Self.arguments() }
        try admit(); defer { inFlight -= 1 }
        let receipt = try await provider.resolve(candidateID: input.candidateID, project: input.project)
        try Task.checkCancellation()
        guard receipt.provider == profile.provider, receipt.candidate.id == input.candidateID,
              receipt.candidate.project == input.project, Normalizer.component(receipt.candidate.pageID),
              receipt.candidate.title.utf8.count <= 512, (receipt.candidate.description?.utf8.count ?? 0) <= 1024,
              receipt.normalizerVersion == profile.normalizer else { throw Self.providerContract() }
        let now = clock(), snapshot: Snapshot
        switch receipt.payload {
        case .fixture(let seed):
            guard profile == .offlineDemo, receipt.candidate.pageID == seed.pageID,
                  receipt.revisionID == seed.revisionID, receipt.normalizerVersion == seed.normalizerVersion,
                  seed.project == input.project else { throw Self.providerContract() }
            snapshot = try Normalizer.normalize(seed, retrievedAt: now, limits: limits)
        case .live(let value):
            guard profile == .wikipediaEnglish, value.provenance.identity.pageID == receipt.candidate.pageID,
                  value.provenance.identity.revisionID == receipt.revisionID else { throw Self.providerContract() }
            snapshot = try LiveSnapshotAdmission.validate(value, limits: limits)
        }
        try Task.checkCancellation()
        try await cache.insert(snapshot, now: now)
        return try SnapshotProjection.outline(snapshot)
    }
    public func section(_ input: SectionInput) async throws -> SectionPassage {
        try identity(input.snapshot, part: input.part)
        let maximum = input.maxTextBytes ?? limits.sectionTextBytes
        guard (1...limits.sectionTextBytes).contains(maximum) else { throw Self.arguments() }
        let snapshot = try await cache.get(input.snapshot, now: clock())
        return try SnapshotProjection.section(snapshot, part: input.part, maximumBytes: maximum)
    }
    public func references(_ input: ReferencesInput) async throws -> SectionReferences {
        try identity(input.snapshot, part: input.part)
        return try SnapshotProjection.references(await cache.get(input.snapshot, now: clock()), part: input.part)
    }
    private func identity(_ id: SnapshotID, part: PartLocation) throws {
        try allowed(id.project); try Task.checkCancellation()
        guard id == part.snapshot else {
            throw ExplorerProblem(.revisionMismatch, "Snapshot and part identities differ.", recovery: "Reuse both identities from the same outline.")
        }
        guard profile.admits(id),
              Normalizer.component(id.pageID), Normalizer.component(id.revisionID), Normalizer.component(part.partID) else { throw Self.arguments() }
    }
    private func allowed(_ project: String) throws {
        guard project == profile.project else { throw profile.problem(.projectNotAllowed) }
    }

    private func admit() throws {
        guard inFlight < 2 else { throw ExplorerProblem(.budgetExceeded, "Two provider operations are already active.", recovery: "Wait for an active operation to finish; no unbounded queue is retained.") }
        inFlight += 1
    }
    private static func arguments() -> ExplorerProblem {
        .init(.invalidArguments, "Arguments exceed the owned operation contract.", recovery: "Use returned IDs, query 1–256 UTF8 bytes, limit 1–20 and text budget 1–32768.")
    }
    private static func providerContract() -> ExplorerProblem {
        .init(.invalidFixture, "Provider violated the normalized output contract.", recovery: "Repair the provider adapter rather than accepting inconsistent identities.")
    }
}
