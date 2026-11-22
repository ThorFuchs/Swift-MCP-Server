// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerPresentation

/// A live-shaped client with a crafted, truncated passage, to exercise states fixtures cannot reach.
private actor CraftedLive: ResearchClient {
    let id = SnapshotID(provider: "mediawiki-rest", project: "enwiki", pageID: "11", revisionID: "22", normalizerVersion: "mediawiki-html-1")
    let sourceURL: String
    init(sourceURL: String) { self.sourceURL = sourceURL }
    var provenance: Provenance { .init(identity: id, title: "Crafted", sourceURL: sourceURL, retrievedAt: "2026-11-22T00:00:00Z", modifiedAt: nil, language: "en", license: "CC BY-SA 4.0", synthetic: false) }
    func search(_ input: SearchInput) async throws -> SearchPage {
        .init(candidates: [.init(id: "c", project: "enwiki", pageID: "11", title: "Crafted", description: nil)], truncated: true, provider: "mediawiki-rest", query: input.query)
    }
    func outline(_ input: OutlineInput) async throws -> Outline {
        .init(snapshot: id, provenance: provenance, introduction: "Intro", sections: [.init(location: .init(snapshot: id, partID: "p0"), parentPartID: nil, depth: 1, heading: nil)],
              totalSections: 3, introductionTruncated: false, referenceCount: 0, tableCount: 0, truncated: true)
    }
    func section(_ input: SectionInput) async throws -> SectionPassage {
        .init(snapshot: id, provenance: provenance, selectedPartID: input.part.partID, includedPartIDs: [input.part.partID], text: "cut", textAvailable: true, truncated: true, continuationSupported: false)
    }
    func references(_ input: ReferencesInput) async throws -> SectionReferences {
        .init(snapshot: id, provenance: provenance, references: [], associations: [], unresolvedIDs: [], truncated: false, independentlyVerified: false)
    }
}
@MainActor private func offline(ttl: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date() }) throws -> (ResearchController, FixtureProvider) {
    let provider = try FixtureProvider.load()
    return (ResearchController(client: ExplorerService(provider: provider, limits: try ExplorerLimits(snapshotTTL: ttl), clock: clock)), provider)
}

/// RE-03 (#35): every reader state is distinguishable and derived deterministically.
struct ReaderPresentationTests {
    @Test @MainActor func idleAndSearchStatesAreDistinct() async throws {
        let (model, provider) = try offline()
        #expect(model.presentation.status == .idle && model.presentation.evidence == .noSection && model.presentation.outline.isEmpty)
        #expect(!model.presentation.canReadNext && !model.presentation.canReadPrevious)
        model.query = "nothing-here"; model.search(); await model.waitUntilIdle()
        #expect(model.presentation.status == .noResults)
        model.query = "telescope"; model.search(); await model.waitUntilIdle()
        #expect(model.presentation.status == .candidates(count: 2, truncated: false))
        await provider.setFault(.rateLimited)
        model.search(); await model.waitUntilIdle()
        #expect(model.presentation.status == .problem(.upstreamRateLimited))
        await model.shutdown()
    }

    @Test @MainActor func tourSectionShowsHierarchyEvidenceAndProvenance() async throws {
        let (model, _) = try offline()
        model.exploreOfflineCollection(); await model.waitUntilIdle()
        let p = model.presentation
        #expect(p.status == .section(truncated: false))
        #expect(p.evidence == .cited(resolved: 1, unresolved: ["ref-lost-ledger"], truncated: false))
        #expect(p.outline.map(\.id) == ["p1", "p2", "p2-1", "p3", "p3-1", "p3-2", "p4", "p5", "p6"])
        #expect(p.outline.map(\.indent) == [0, 0, 1, 0, 1, 1, 0, 0, 0])
        #expect(p.outline.filter(\.isSelected).map(\.id) == ["p2"])
        #expect(p.outline[1].accessibilityLabel == "Telescope, section level 1, selected")
        #expect(p.outline[2].accessibilityLabel == "Calibration, section level 2")
        let lines = Dictionary(uniqueKeysWithValues: p.provenance.map { ($0.label, $0.value) })
        #expect(lines["Revision"] == "r1 (pinned)" && lines["Edited"] == "2026-03-14T09:00:00Z")
        #expect(lines["Source"]?.contains("fictional") == true && lines["Normalizer"] == "fixture-1")
        #expect(lines["Citations"] == "Metadata only; not independently verified" && lines["Omitted"] == "1 table; plain-text projection")
        #expect(p.permalink == nil, "fictional data never offers an outbound link")
        await model.shutdown()
    }

    @Test @MainActor func adjacentNavigationWalksTheOutlineAndStopsAtItsEnds() async throws {
        let (model, _) = try offline()
        model.query = "meridian"; model.search(); await model.waitUntilIdle()
        model.open(try #require(model.page?.candidates.first)); await model.waitUntilIdle()
        #expect(model.presentation.status == .outline && model.presentation.canReadNext && !model.presentation.canReadPrevious)
        model.readAdjacent(-1); await model.waitUntilIdle()
        #expect(model.selectedPart == nil, "nothing before the first section")
        var visited: [String] = []
        for _ in 0..<10 {
            guard model.presentation.canReadNext else { break }
            model.readAdjacent(1); await model.waitUntilIdle()
            visited.append(try #require(model.selectedPart?.partID))
        }
        #expect(visited == ["p1", "p2", "p2-1", "p2-2", "p3", "p4", "p5"])
        #expect(!model.presentation.canReadNext && model.presentation.canReadPrevious)
        model.readAdjacent(1); await model.waitUntilIdle()
        #expect(model.selectedPart?.partID == "p5")
        model.readAdjacent(-1); await model.waitUntilIdle()
        #expect(model.selectedPart?.partID == "p4" && model.presentation.evidence == .uncited)
        await model.shutdown()
    }

    @Test @MainActor func missingMetadataExpiryAndCancellationAreDistinct() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 0))
        let (model, _) = try offline(ttl: 5, clock: { now.withLock { $0 } })
        model.query = "lantern"; model.search(); await model.waitUntilIdle()
        model.open(try #require(model.page?.candidates.first)); await model.waitUntilIdle()
        model.readAdjacent(1); await model.waitUntilIdle()
        #expect(model.presentation.status == .section(truncated: false) && model.presentation.evidence == .metadataMissing)
        now.withLock { $0 = Date(timeIntervalSince1970: 10) }
        model.readAdjacent(1); await model.waitUntilIdle()
        #expect(model.presentation.status == .expired && model.presentation.evidence == .unavailable(.absentSnapshot))
        model.query = "Riverglass"; model.search(); model.cancel(); await model.waitUntilIdle()
        #expect(model.presentation.status == .cancelled || model.presentation.status == .candidates(count: 5, truncated: false))
        await model.shutdown()
    }

    @Test @MainActor func truncationOmissionsAndLivePermalinkAreExplicit() async throws {
        let live = ResearchController(client: CraftedLive(sourceURL: "https://en.wikipedia.org/w/index.php?curid=11&oldid=22"), source: .wikipediaEnglish)
        live.query = "x"; live.search(); await live.waitUntilIdle()
        #expect(live.presentation.status == .candidates(count: 1, truncated: true))
        live.open(try #require(live.page?.candidates.first)); await live.waitUntilIdle()
        #expect(live.presentation.outline.map(\.title) == ["Introduction"])
        live.readAdjacent(1); await live.waitUntilIdle()
        let p = live.presentation
        #expect(p.status == .section(truncated: true) && p.evidence == .uncited)
        #expect(p.permalink?.absoluteString == "https://en.wikipedia.org/w/index.php?curid=11&oldid=22")
        #expect(p.provenance.contains(.init(label: "Outline", value: "2 sections omitted")))
        await live.shutdown()
        for bad in ["http://en.wikipedia.org/w/index.php?curid=11&oldid=22", "https://en.wikipedia.org/w/index.php?curid=11&oldid=23",
                    "https://example.org/w/index.php?curid=11&oldid=22", "https://en.wikipedia.org/wiki/Crafted"] {
            let model = ResearchController(client: CraftedLive(sourceURL: bad), source: .wikipediaEnglish)
            model.query = "x"; model.search(); await model.waitUntilIdle()
            model.open(try #require(model.page?.candidates.first)); await model.waitUntilIdle()
            #expect(model.presentation.permalink == nil, "no link for \(bad)")
            await model.shutdown()
        }
    }
}
