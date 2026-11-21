// SPDX-License-Identifier: Apache-2.0
// WRE2 SOURCE ONLY; all functions NOT_RUN.
import Foundation
import Testing
@testable import ExplorerDomain
import WikimediaAccess

private func article(_ text: String = "original", revision: String = "r1", page: String = "observatory") -> ArticleSeed {
    .init(fixtureKind: "synthetic_normalized_example_not_upstream_payload", formatVersion: "wre-fixture-1",
        project: "fixture-enwiki", pageID: page, revisionID: revision, title: "Synthetic",
        sourceURL: "fixture://riverglass/\(page)/\(revision)", normalizerVersion: "fixture-1", license: "Apache-2.0 synthetic",
        parts: [.init(id: "p", heading: nil, text: text, kind: nil, citations: [], parts: nil)], references: [], tables: nil, modifiedAt: nil)
}
private func normalized(_ text: String = "original", revision: String = "r1", time: Double = 0) throws -> Snapshot {
    try Normalizer.normalize(article(text, revision: revision), retrievedAt: Date(timeIntervalSince1970: time), limits: ExplorerLimits())
}
private func denied(_ code: ExplorerProblem.Code, _ op: () async throws -> Void) async {
    do { try await op(); Issue.record("Expected \(code)") }
    catch let p as ExplorerProblem { #expect(p.code == code) }
    catch { Issue.record("Unexpected error \(error)") }
}
private actor ReceiptProvider: ExplorerProvider {
    var receipt: CandidateResolution
    init(_ receipt: CandidateResolution) { self.receipt = receipt }
    func set(_ receipt: CandidateResolution) { self.receipt = receipt }
    func resolve(candidateID: String, project: String) async throws -> CandidateResolution { receipt }
    func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        .init(candidates: [receipt.candidate], truncated: false, provider: Normalizer.provider, query: query)
    }
}
private func receipt(_ seed: ArticleSeed, provider: String = "synthetic-fixture", candidate: String = "selected", project: String = "fixture-enwiki", page: String = "observatory", revision: String = "r1", normalizer: String = "fixture-1") -> CandidateResolution {
    .init(provider: provider, candidate: .init(id: candidate, project: project, pageID: page, title: "Synthetic", description: nil), revisionID: revision, normalizerVersion: normalizer, article: seed)
}
struct CacheContractTests {
    @Test func receiptAxesAreRejectedBeforeCacheMutation_T04() async throws {
        let good = article(), p = ReceiptProvider(receipt(article()))
        let service = ExplorerService(provider: p, limits: try ExplorerLimits(), clock: { Date(timeIntervalSince1970: 0) })
        let outline = try await service.outline(.init(project: "fixture-enwiki", candidateID: "selected"))
        let loc = try #require(outline.sections.first?.location)
        let invalid = [receipt(good, page: "foreign"), receipt(good, provider: "foreign"),
            receipt(good, project: "foreign"), receipt(good, candidate: "foreign"),
            receipt(good, revision: "r2"), receipt(good, normalizer: "foreign")]
        for bad in invalid {
            await p.set(bad)
            await denied(.invalidFixture) { _ = try await service.outline(.init(project: "fixture-enwiki", candidateID: "selected")) }
            #expect(try await service.section(.init(snapshot: outline.snapshot, part: loc, maxTextBytes: nil)).text == "original")
        }
    }
    @Test func conflictingSameIdentityPreservesOldContent_T05() async throws {
        let cache = SnapshotCache(limits: try ExplorerLimits())
        let original = try normalized(), changed = try normalized("changed")
        try await cache.insert(original, now: Date(timeIntervalSince1970: 0))
        await denied(.invalidFixture) { try await cache.insert(changed, now: Date(timeIntervalSince1970: 1)) }
        #expect(try await cache.get(original.provenance.identity, now: Date(timeIntervalSince1970: 2)).parts.first?.text == "original")
        #expect(await cache.accounting.entries == 1)
    }
    @Test func compatibleRefreshUpdatesRetrievalAndTTL_T06() async throws {
        let cache = SnapshotCache(limits: try ExplorerLimits(snapshotTTL: 5))
        let original = try normalized(), refresh = try normalized(time: 4)
        try await cache.insert(original, now: Date(timeIntervalSince1970: 0))
        try await cache.insert(refresh, now: Date(timeIntervalSince1970: 4))
        let actual = try await cache.get(original.provenance.identity, now: Date(timeIntervalSince1970: 6))
        #expect(actual.provenance.retrievedAt == "1970-01-01T00:00:04Z")
        #expect(actual.parts.first?.text == "original")
        await denied(.absentSnapshot) { _ = try await cache.get(original.provenance.identity, now: Date(timeIntervalSince1970: 9)) }
    }
    @Test func countLRUEvictionIsIndependentOfByteCeiling_T07() async throws {
        let cache = SnapshotCache(limits: try ExplorerLimits(cacheEntries: 2))
        let a = try normalized(revision: "r1"), b = try normalized(revision: "r2"), c = try normalized(revision: "r3")
        for s in [a,b] { try await cache.insert(s, now: Date(timeIntervalSince1970: 0)) }
        _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: 0))
        try await cache.insert(c, now: Date(timeIntervalSince1970: 0))
        await denied(.absentSnapshot) { _ = try await cache.get(b.provenance.identity, now: Date(timeIntervalSince1970: 0)) }
        #expect(await cache.accounting.entries == 2)
        _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: 0))
    }
    @Test func logicalByteEvictionAndOversizeValidationPrecedeMutation_T08() async throws {
        let cache = SnapshotCache(limits: try ExplorerLimits(cacheEntries: 3, cacheContentBytes: 2048))
        let a = try normalized(String(repeating: "a", count: 1200)), b = try normalized(String(repeating: "b", count: 1200), revision: "r2")
        #expect(a.contentBytes < 2048 && a.contentBytes + b.contentBytes > 2048)
        try await cache.insert(a, now: Date(timeIntervalSince1970: 0)); try await cache.insert(b, now: Date(timeIntervalSince1970: 0))
        await denied(.absentSnapshot) { _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: 0)) }
        let big = try normalized(String(repeating: "x", count: 3000), revision: "r3")
        await denied(.budgetExceeded) { try await cache.insert(big, now: Date(timeIntervalSince1970: 0)) }
        _ = try await cache.get(b.provenance.identity, now: Date(timeIntervalSince1970: 0))
        let accounting = await cache.accounting
        #expect(accounting.entries == 1 && accounting.contentBytes <= 2048)
    }
    @Test func backwardAndNonfiniteClockAreDistinct_T09() async throws {
        let cache = SnapshotCache(limits: try ExplorerLimits())
        let a = try normalized()
        try await cache.insert(a, now: Date(timeIntervalSince1970: 10))
        await denied(.absentSnapshot) { _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: .nan)) }
        _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: 11))
        await denied(.absentSnapshot) { _ = try await cache.get(a.provenance.identity, now: Date(timeIntervalSince1970: 9)) }
        #expect(await cache.accounting.entries == 0)
    }
}
