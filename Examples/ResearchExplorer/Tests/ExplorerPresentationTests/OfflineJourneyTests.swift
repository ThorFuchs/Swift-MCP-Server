// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerPresentation

/// Records calls and can park the next `outline` call until released, to force races.
private actor GatedClient: ResearchClient {
    let service: ExplorerService
    private(set) var calls: [String] = []
    private var parkOutline = false, parked: CheckedContinuation<Void, Never>?, entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    init(_ service: ExplorerService) { self.service = service }
    func parkNextOutline() { parkOutline = true; didEnter = false }
    func waitParked() async { if didEnter { return }; await withCheckedContinuation { entered = $0 } }
    func release() { parked?.resume(); parked = nil }
    func search(_ i: SearchInput) async throws -> SearchPage { calls.append("search"); return try await service.search(i) }
    func outline(_ i: OutlineInput) async throws -> Outline {
        calls.append("outline")
        let result = try await service.outline(i)
        if parkOutline {
            parkOutline = false
            await withCheckedContinuation { parked = $0; didEnter = true; entered?.resume(); entered = nil }
        }
        return result // deliberately late, even when superseded
    }
    func section(_ i: SectionInput) async throws -> SectionPassage { calls.append("section"); return try await service.section(i) }
    func references(_ i: ReferencesInput) async throws -> SectionReferences { calls.append("references"); return try await service.references(i) }
}
private final class Recorded: Sendable {
    let events = Mutex<[String]>([])
    func add(_ op: String, _ ok: Bool) { events.withLock { $0.append("\(op):\(ok)") } }
    var all: [String] { events.withLock { $0 } }
}
@MainActor private func offline(ttl: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date() }) throws
    -> (ResearchController, FixtureProvider, GatedClient, Recorded) {
    let provider = try FixtureProvider.load()
    let client = GatedClient(ExplorerService(provider: provider, limits: try ExplorerLimits(snapshotTTL: ttl), clock: clock))
    let recorded = Recorded()
    let model = ResearchController(client: client, source: .offlineDemo, record: { recorded.add($0, $1) }, offlineEdit: .prepared(provider))
    return (model, provider, client, recorded)
}

/// RE-01 (#33): one-click offline tour and explicit, never silent, revision comparison.
struct OfflineJourneyTests {
    @Test @MainActor func oneClickTourReachesASectionWithReferences() async throws {
        let (model, _, _, recorded) = try offline()
        model.exploreOfflineCollection(); await model.waitUntilIdle()
        #expect(model.query == OfflineTour.query && model.page?.candidates.count == 5)
        #expect(model.candidate?.id == OfflineTour.candidateID && model.outline?.snapshot.revisionID == "r1")
        #expect(model.selectedPart?.partID == OfflineTour.partID && model.phase == .section && model.problem == nil)
        let passage = try #require(model.passage)
        #expect(passage.snapshot == model.outline?.snapshot && passage.text.contains("2-metre") && passage.text.contains("α — π"))
        #expect(model.citations?.references.map(\.id) == ["ref-instrument-notes"] && model.citations?.unresolvedIDs == ["ref-lost-ledger"])
        #expect(recorded.all == ["search_articles:true", "get_article_outline:true", "read_article_section:true"])
        await model.shutdown()
    }

    @Test @MainActor func tourAndSimulatedEditNeverReachALiveSource() async throws {
        let provider = try FixtureProvider.load()
        let client = GatedClient(ExplorerService(provider: provider, limits: try ExplorerLimits()))
        let model = ResearchController(client: client, source: .wikipediaEnglish, offlineEdit: .prepared(provider))
        #expect(model.offlineEdit == nil)
        model.exploreOfflineCollection(); model.publishOfflineEdit(); await model.waitUntilIdle()
        #expect(await client.calls.isEmpty && model.phase == .idle && model.page == nil)
        #expect(await provider.edition() == .r1 && !model.offlineEditPublished)
        await model.shutdown()
    }

    @Test @MainActor func comparisonIsExplicitAndNeverSwapsThePinnedRevision() async throws {
        let (model, provider, _, _) = try offline()
        model.exploreOfflineCollection(); await model.waitUntilIdle()
        let pinned = try #require(model.outline), passage = try #require(model.passage), citations = try #require(model.citations)
        // No newer revision yet: the check says so and changes nothing.
        model.compareWithLatestRevision(); await model.waitUntilIdle()
        #expect(model.comparison?.latestIsPinned == true && model.comparison?.passage == .notCompared)
        // Publishing the upstream edit leaves the reader on r1.
        model.publishOfflineEdit(); await model.waitUntilIdle()
        #expect(await provider.edition() == .r2 && model.offlineEditPublished && model.phase == .section)
        #expect(model.outline?.snapshot == pinned.snapshot && model.passage?.text == passage.text)
        // Explicit comparison shows the concrete changed passage without replacing anything.
        model.compareWithLatestRevision(); await model.waitUntilIdle()
        let comparison = try #require(model.comparison)
        #expect(!comparison.latestIsPinned && comparison.pinned == pinned.snapshot && comparison.latest.snapshot.revisionID == "r2")
        guard case .changed(let old, let new) = comparison.passage else { Issue.record("expected a changed passage"); return }
        #expect(old.contains("2-metre") && new.contains("2.1-metre"))
        #expect(model.outline?.snapshot == pinned.snapshot && model.passage?.snapshot == pinned.snapshot)
        #expect(model.citations?.references.map(\.id) == citations.references.map(\.id) && model.phase == .section)
        // Only an explicit switch moves the reader, and it re-reads the same section from r2.
        model.adoptLatestRevision(); await model.waitUntilIdle()
        #expect(model.outline?.snapshot.revisionID == "r2" && model.comparison == nil)
        #expect(model.passage?.snapshot.revisionID == "r2" && model.passage?.text.contains("2.1-metre") == true)
        #expect(model.citations?.references.map(\.id) == ["ref-instrument-notes", "ref-remeasurement-1931"])
        await model.shutdown()
    }

    @Test @MainActor func supersededComparisonCannotLandOnANewerSelection() async throws {
        let (model, _, client, _) = try offline()
        model.exploreOfflineCollection(); await model.waitUntilIdle()
        model.publishOfflineEdit(); await model.waitUntilIdle()
        let other = try #require(model.outline?.sections.first { $0.location.partID == "p3" }?.location)
        await client.parkNextOutline()
        model.compareWithLatestRevision(); await client.waitParked()
        model.read(other)                // the user moves on while the comparison is in flight
        await client.release(); await model.waitUntilIdle()
        #expect(model.comparison == nil && model.selectedPart == other && model.outline?.snapshot.revisionID == "r1")
        #expect(model.passage?.selectedPartID == "p3" && model.phase == .section)
        await model.shutdown()
    }

    @Test @MainActor func expiredPinFailsComparisonVisiblyInsteadOfFetchingLatest() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 0))
        let (model, _, _, recorded) = try offline(ttl: 5, clock: { now.withLock { $0 } })
        model.exploreOfflineCollection(); await model.waitUntilIdle()
        model.publishOfflineEdit(); await model.waitUntilIdle()
        let pinned = try #require(model.outline)
        now.withLock { $0 = Date(timeIntervalSince1970: 6) }
        model.compareWithLatestRevision(); await model.waitUntilIdle()
        #expect(model.problem?.code == .absentSnapshot && model.phase == .problem && model.comparison == nil)
        #expect(model.outline?.snapshot == pinned.snapshot, "an expired pin is reported, never swapped for r2")
        #expect(recorded.all.suffix(2) == ["get_article_outline:true", "read_article_section:false"])
        await model.shutdown()
    }

    @Test @MainActor func missingReferenceMetadataDiffersFromAnUncitedSection() async throws {
        let (model, _, _, _) = try offline()
        model.query = "lantern"; model.search(); await model.waitUntilIdle()
        model.open(try #require(model.page?.candidates.first)); await model.waitUntilIdle()
        model.read(try #require(model.outline?.sections.first?.location)); await model.waitUntilIdle()
        #expect(model.passage != nil && model.citations == nil && model.referenceProblem?.code == .missingReferences)
        model.query = "meridian"; model.search(); await model.waitUntilIdle()
        model.open(try #require(model.page?.candidates.first { $0.id == "fixture-instrument" })); await model.waitUntilIdle()
        model.read(try #require(model.outline?.sections.first { $0.location.partID == "p4" }?.location)); await model.waitUntilIdle()
        #expect(model.referenceProblem == nil && model.citations?.references.isEmpty == true && model.citations?.unresolvedIDs.isEmpty == true)
        await model.shutdown()
    }

    @Test @MainActor func shutdownDuringTourJoinsWithoutLateWrites() async throws {
        let (model, _, client, _) = try offline()
        await client.parkNextOutline()
        model.exploreOfflineCollection(); await client.waitParked()
        let closing = Task { await model.shutdown() }
        await client.release(); await closing.value
        #expect(model.outline == nil && model.passage == nil && model.phase == .cancelled)
    }
}
