// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerPresentation

private actor DelayedSearch: ResearchClient {
    private var release: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func waitForSlow() async {
        if didEnter { return }; await withCheckedContinuation { entered = $0 }
    }
    func resumeSlow() { release?.resume(); release = nil }
    func search(_ input: SearchInput) async throws -> SearchPage {
        if input.query == "slow" {
            await withCheckedContinuation { release = $0; didEnter = true; entered?.resume(); entered = nil }
        }
        return .init(candidates: [.init(id: input.query, project: "fixture-enwiki", pageID: "p", title: input.query, description: nil)], truncated: false, provider: "synthetic-fixture", query: input.query)
    }
    func outline(_ input: OutlineInput) async throws -> Outline { throw PublicProblems.project(.unknownCandidate) }
    func section(_ input: SectionInput) async throws -> SectionPassage { throw PublicProblems.project(.absentSection) }
    func references(_ input: ReferencesInput) async throws -> SectionReferences { throw PublicProblems.project(.missingReferences) }
}
struct ResearchTests {
    @Test @MainActor func T01_supersededSearchJoinsAndCannotOverwrite() async {
        let client = DelayedSearch()
        // Use one exact controlled owner for both release and the model.
        let current = ResearchController(client: client)
        current.query = "slow"; current.search(); await client.waitForSlow()
        current.query = "new"; current.search(); await client.resumeSlow(); await current.waitUntilIdle()
        #expect(current.page?.query == "new" && current.phase == .candidates)
        await current.shutdown()
    }
    @Test @MainActor func T03_fixtureJourneyRetainsFullRevisionAndRejectsMismatch() async throws {
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let model = ResearchController(client: service)
        model.query = "Riverglass"; model.search(); await model.waitUntilIdle()
        let candidate = try #require(model.page?.candidates.first)
        model.open(candidate); await model.waitUntilIdle()
        let outline = try #require(model.outline), part = try #require(outline.sections.first)
        model.read(part.location); await model.waitUntilIdle()
        #expect(model.passage?.snapshot == outline.snapshot)
        #expect(model.citations?.snapshot == outline.snapshot)
        #expect(model.source == .offlineDemo && outline.provenance.synthetic)
        let foreign = SnapshotID(provider: outline.snapshot.provider, project: outline.snapshot.project, pageID: outline.snapshot.pageID, revisionID: "foreign", normalizerVersion: outline.snapshot.normalizerVersion)
        model.read(.init(snapshot: foreign, partID: part.location.partID))
        #expect(model.problem?.code == .revisionMismatch && model.outline?.snapshot == outline.snapshot)
        await model.shutdown()
    }
    @Test @MainActor func T04_emptyFailureAndCancellationAreDifferent() async throws {
        let provider = try FixtureProvider.load()
        let model = ResearchController(client: ExplorerService(provider: provider, limits: try ExplorerLimits()))
        model.query = "no-match"; model.search(); await model.waitUntilIdle()
        #expect(model.phase == .empty && model.problem == nil)
        await provider.setFault(.unavailable)
        model.query = "Riverglass"; model.search(); await model.waitUntilIdle()
        #expect(model.phase == .problem && model.problem?.code == .upstreamUnavailable)
        let client = DelayedSearch()
        let held = ResearchController(client: client)
        held.query = "slow"; held.search(); await client.waitForSlow(); held.cancel()
        await client.resumeSlow(); await held.waitUntilIdle()
        #expect(held.phase == .cancelled && held.page == nil)
        await held.shutdown(); await model.shutdown()
    }
    @Test @MainActor func T15_fixtureLabelsAreNotLiveOrSampleTelemetry() async throws {
        let model = ResearchController(client: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        #expect(model.source.rawValue == "Offline demo" && model.page == nil && model.phase == .idle)
        await model.shutdown()
    }
}
