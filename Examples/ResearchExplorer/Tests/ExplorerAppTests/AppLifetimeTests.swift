// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import ExplorerDomain
import WikimediaAccess
import ExplorerPresentation
@testable import ResearchExplorerApp

private actor Hold {
    private var entered = false, done = false
    private var entry: CheckedContinuation<Void, Never>?, release: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; entry?.resume(); entry = nil
        if done { return }; await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async { if entered { return }; await withCheckedContinuation { entry = $0 } }
    func finish() { done = true; release?.resume(); release = nil }
}
private actor AppHeldProvider: ExplorerProvider {
    let base: FixtureProvider, hold: Hold
    init(base: FixtureProvider, hold: Hold) { self.base = base; self.hold = hold }
    func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        if query == "held" { await hold.wait() }
        return try await base.search(query: query, project: project, limit: limit)
    }
    func resolve(candidateID: String, project: String) async throws -> CandidateResolution { try await base.resolve(candidateID: candidateID, project: project) }
}
private actor FailingAppHost: ExplorerHTTPHost {
    let hold: Hold
    init(_ hold: Hold) { self.hold = hold }
    func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws {
        await ready(try ServerEndpoint(host: "127.0.0.1", port: 12345)); await hold.wait()
    }
    func stop() throws { throw HostFailure.stopFailed }
}

@MainActor private func withApp(_ app: AppLifetime,
                              release: @escaping @MainActor () async -> Void = {},
                              body: @MainActor () async throws -> Void) async throws {
    var primary: (any Error)?
    do { try await body() } catch { primary = error }
    // Failure paths release only this fixture's known hold, then observe joins.
    // Cleanup is not a successful body/framework outcome.
    await release(); await app.server?.waitUntilRunJoined()
    _ = await app.quit(waitMilliseconds: 2000)
    await app.waitForTerminationSettlement(); await app.waitUntilPrepared()
    _ = await app.quit(waitMilliseconds: 2000)
    await app.waitForTerminationSettlement()
    if let primary { throw primary }
}

@Suite @MainActor struct AppLifetimeTests {
    /// RE-01 (#33) / J1: first launch prepares only the offline collection, makes no live request,
    /// constructs no listener, and offers the one-click tour plus the prepared offline edit.
    @Test func firstLaunchPreparesOfflineCollectionWithoutListenerOrLiveSource() async throws {
        let requested = Mutex<[SourceProfile]>([]), hosts = Mutex(0)
        let provider = try FixtureProvider.load()
        let app = AppLifetime(loadSource: { profile in
            requested.withLock { $0.append(profile) }
            guard profile == .offlineDemo else { throw ExplorerProblem(.upstreamUnavailable, "live source must not load", recovery: "") }
            return PreparedSource(service: ExplorerService(provider: provider, limits: try ExplorerLimits()), offlineEdit: .prepared(provider))
        }, makeHost: { _, _, _ in hosts.withLock { $0 += 1 }; throw HostFailure.stopFailed })
        try await withApp(app) {
            #expect(app.profile == .offlineDemo, "the default source is the fictional offline demo")
            app.prepare(); await app.waitUntilPrepared()
            let research = try #require(app.research)
            #expect(requested.withLock { $0 } == [.offlineDemo] && app.startupProblem == nil)
            #expect(app.server?.phase == .stopped && hosts.withLock { $0 } == 0, "no listener is constructed at launch")
            #expect(research.source == .offlineDemo && research.offlineEdit != nil && research.phase == .idle)
            research.exploreOfflineCollection(); await research.waitUntilIdle()
            #expect(research.outline?.provenance.synthetic == true && research.citations != nil)
            #expect(requested.withLock { $0 } == [.offlineDemo] && hosts.withLock { $0 } == 0)
        }
    }
    @Test func actualAppQuitRetainsHeldResearchThenRecoversAndRetries() async throws {
        let hold = Hold(), base = try FixtureProvider.load()
        let service = ExplorerService(provider: AppHeldProvider(base: base, hold: hold), limits: try ExplorerLimits())
        let app = AppLifetime(profile: .offlineDemo, loadService: { _ in service })
        try await withApp(app, release: { await hold.finish() }) {
            app.prepare(); await app.waitUntilPrepared()
            let old = try #require(app.research)
            old.query = "held"; old.search(); await hold.waitForEntry()
            let early = await app.quit(waitMilliseconds: 20)
            let retained = app.termination.unsettled
            let repeated = await app.quit(waitMilliseconds: 20)
            await hold.finish(); await app.waitForTerminationSettlement()
            let current = try #require(app.research)
            current.query = "Riverglass"; current.search(); await current.waitUntilIdle()
            let usable = current.page?.candidates.isEmpty == false
            let clean = await app.quit(waitMilliseconds: 2000)
            #expect(!early && retained && !repeated && old !== current && usable && clean)
        }
    }
    @Test func actualAppFailedServerStopDoesNotPermanentlyCloseResearch() async throws {
        let hold = Hold(), host = FailingAppHost(hold)
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let app = AppLifetime(profile: .offlineDemo, loadService: { _ in service }, makeHost: { _, _, _ in host })
        try await withApp(app, release: { await hold.finish() }) {
            app.prepare(); await app.waitUntilPrepared(); app.startServer(); await hold.waitForEntry()
            let result = await app.quit(waitMilliseconds: 2000)
            let debt = app.server?.cleanupDebt == true
            let research = try #require(app.research)
            research.query = "Riverglass"; research.search(); await research.waitUntilIdle()
            let usable = research.page?.candidates.isEmpty == false
            await hold.finish(); await app.server?.waitUntilRunJoined()
            let clean = await app.quit(waitMilliseconds: 2000)
            #expect(!result && debt && usable && clean)
        }
    }
    @Test func actualAppBootstrapWaitIsBoundedAndLateRecoveryPreparesFreshGraph() async throws {
        let hold = Hold(), service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let app = AppLifetime(profile: .offlineDemo, loadService: { _ in await hold.wait(); return service })
        try await withApp(app, release: { await hold.finish() }) {
            app.prepare(); await hold.waitForEntry()
            let start = ContinuousClock.now, early = await app.quit(waitMilliseconds: 20)
            let elapsed = start.duration(to: .now)
            await hold.finish(); await app.waitForTerminationSettlement(); await app.waitUntilPrepared()
            let research = try #require(app.research)
            research.query = "Riverglass"; research.search(); await research.waitUntilIdle()
            let usable = research.page?.candidates.isEmpty == false
            let clean = await app.quit(waitMilliseconds: 2000)
            #expect(!early && elapsed < .seconds(1) && usable && clean)
        }
    }
    @Test func actualExportFailureIsReportedAndJoinedBeforeQuit() async throws {
        enum ControlledFailure: Error { case denied }
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let writer = ActivityExportWriter(beforeCommit: { throw ControlledFailure.denied })
        let app = AppLifetime(profile: .offlineDemo, loadService: { _ in service }, exportWriter: writer)
        try await withApp(app) {
            app.prepare(); await app.waitUntilPrepared()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent("activity.json")
            app.beginExport(filter: ActivityFilter(), destination: output)
            await app.waitUntilExportSettled()
            let reported = app.exportProblem != nil && !app.exporting
            let exists = FileManager.default.fileExists(atPath: output.path)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let clean = await app.quit(waitMilliseconds: 2000)
            #expect(reported && !exists && leftovers.isEmpty && clean)
        }
    }
    @Test func sourceSwitchUsesActualJoinedGraphAndKeepsSharedService() async throws {
        let offline = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let app = AppLifetime(profile: .offlineDemo, loadService: { profile in
            if profile == .offlineDemo { return offline }
            return ExplorerService(provider: WikipediaProvider(), limits: try ExplorerLimits())
        })
        try await withApp(app) {
            app.prepare(); await app.waitUntilPrepared()
            let old = try #require(app.research)
            app.selectSource(.wikipediaEnglish); await app.waitUntilPrepared()
            #expect(app.profile == .wikipediaEnglish && app.service?.profile == .wikipediaEnglish)
            #expect(app.research?.source == .wikipediaEnglish && app.research !== old)
            #expect(app.server?.phase == .stopped)
            #expect(await app.quit(waitMilliseconds: 2000))
        }
    }
}
