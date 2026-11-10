// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerPresentation

private actor DeferredSection: ResearchClient {
    let service: ExplorerService
    var started = false
    var signal: CheckedContinuation<Void, Never>?, resume: CheckedContinuation<Void, Never>?
    init(service: ExplorerService) { self.service = service }
    func waitStarted() async { if started { return }; await withCheckedContinuation { signal = $0 } }
    func release() { resume?.resume(); resume = nil }
    func search(_ i: SearchInput) async throws -> SearchPage { try await service.search(i) }
    func outline(_ i: OutlineInput) async throws -> Outline { try await service.outline(i) }
    func section(_ i: SectionInput) async throws -> SectionPassage {
        let result = try await service.section(i)
        await withCheckedContinuation { resume = $0; started = true; signal?.resume(); signal = nil }
        return result // deliberately late, even when cancelled
    }
    func references(_ i: ReferencesInput) async throws -> SectionReferences { try await service.references(i) }
}
struct ResearchIdentityTests {
    @Test @MainActor func T02_newRevisionCannotReceiveOldSection() async throws {
        let provider = try FixtureProvider.load()
        let client = DeferredSection(service: ExplorerService(provider: provider, limits: try ExplorerLimits()))
        let model = ResearchController(client: client)
        model.query = "Riverglass"; model.search(); await model.waitUntilIdle()
        let candidate = try #require(model.page?.candidates.first)
        model.open(candidate); await model.waitUntilIdle()
        let old = try #require(model.outline), part = try #require(old.sections.first)
        model.read(part.location); await client.waitStarted()
        await provider.select(.r2); model.open(candidate); await client.release(); await model.waitUntilIdle()
        #expect(model.outline?.snapshot.revisionID == "r2" && model.passage == nil && model.citations == nil)
        await model.shutdown()
    }
    @Test @MainActor func T03_expiredSnapshotRequiresExplicitNewOutline() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits(snapshotTTL: 1), clock: { clock.withLock { $0 } })
        let model = ResearchController(client: service)
        model.query = "Riverglass"; model.search(); await model.waitUntilIdle()
        model.open(try #require(model.page?.candidates.first)); await model.waitUntilIdle()
        let old = try #require(model.outline), part = try #require(old.sections.first)
        clock.withLock { $0 = Date(timeIntervalSince1970: 2) }
        model.read(part.location); await model.waitUntilIdle()
        #expect(model.problem?.code == .absentSnapshot && model.outline?.snapshot == old.snapshot)
        #expect(model.passage == nil)
        model.refreshOutline(); await model.waitUntilIdle()
        #expect(model.problem == nil && model.outline?.provenance.retrievedAt != old.provenance.retrievedAt)
        await model.shutdown()
    }
}
