// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
import WikimediaAccess
import ExplorerPresentation
@testable import ResearchExplorerApp

/// RE-04 (#36): server stop, restart and source switching never leave a client journey or
/// inspector records behind.
@Suite(.serialized) @MainActor struct JourneyLifecycleTests {
    private func app() throws -> AppLifetime {
        let provider = try FixtureProvider.load()
        let offline = ExplorerService(provider: provider, limits: try ExplorerLimits())
        let live = ExplorerService(provider: WikipediaProvider(), limits: try ExplorerLimits()) // constructed only; never called here
        return AppLifetime(profile: .offlineDemo, loadSource: { profile in
            PreparedSource(service: profile == .offlineDemo ? offline : live, offlineEdit: profile == .offlineDemo ? .prepared(provider) : nil)
        }, makeHost: { service, activity, id in
            SDKHTTPHost(service: service, activity: activity, runID: id, configuration: try LocalEndpoint(port: 0))
        })
    }
    private func waitPhase(_ app: AppLifetime, _ phase: ServerPhase) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while app.server?.phase != phase {
            guard ContinuousClock.now < deadline, app.server?.phase != .failed else { throw LifecycleFailure.phase("\(String(describing: app.server?.phase))") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum LifecycleFailure: Error { case phase(String) }

    @Test func stopRestartAndSourceSwitchLeaveNoJourneyOrRecords() async throws {
        let app = try app()
        app.prepare(); await app.waitUntilPrepared()
        app.startServer(); try await waitPhase(app, .running)
        // A full inspected run against the real host.
        app.journey.setInspectExchanges(true)
        app.exploreMCP(); await app.journey.waitUntilFinished()
        #expect(app.journey.phase == .completed && app.journey.exchanges.count == 6)
        // Source switching is refused while the server runs, and while a journey runs.
        #expect(!app.canSwitchSource)
        // Stop during a run: the journey is cancelled first and ends; nothing keeps running.
        app.exploreMCP(); #expect(app.journey.isRunning)
        app.stopServer()
        await app.journey.waitUntilFinished()
        #expect(!app.journey.isRunning && [.cancelled, .failed, .completed].contains(app.journey.phase))
        await app.server?.waitUntilRunJoined(); await app.server?.awaitTransition(); try await waitPhase(app, .stopped)
        // A new server run starts without the previous run's results or records.
        #expect(app.server?.canStart == true)
        app.startServer()
        #expect(app.journey.steps.isEmpty && app.journey.exchanges.isEmpty && app.journey.phase == .idle)
        try await waitPhase(app, .running)
        app.exploreMCP(); await app.journey.waitUntilFinished()
        #expect(!app.journey.exchanges.isEmpty)
        app.stopServer(); await app.server?.waitUntilRunJoined(); await app.server?.awaitTransition(); try await waitPhase(app, .stopped)
        // Switching source joins and discards everything of the old source's journey.
        #expect(app.canSwitchSource)
        app.selectSource(.wikipediaEnglish); await app.waitUntilPrepared()
        #expect(app.profile == .wikipediaEnglish && app.server?.phase == .stopped)
        #expect(!app.journey.isRunning && app.journey.exchanges.isEmpty && app.journey.steps.isEmpty && app.journey.outline == nil)
        #expect(await app.quit(waitMilliseconds: 10_000))
    }
}
