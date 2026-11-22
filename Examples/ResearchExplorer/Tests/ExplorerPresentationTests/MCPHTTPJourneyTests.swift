// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import MCPClient
import MCPHTTPClient
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP
@testable import ExplorerPresentation

/// Wraps the real HTTP transport. Counts exchanges and can rewrite the bytes of one tool's
/// response, to prove validation happens on what actually crossed the wire.
private final class ProxyTransport: ClientTransport, Sendable {
    let base: any ClientTransport
    let rewrite: Mutex<(tool: String, from: String, to: String, applied: Int)?>
    let exchanges = Mutex(0)
    init(_ base: any ClientTransport, rewrite: (tool: String, from: String, to: String)? = nil) {
        self.base = base; self.rewrite = Mutex(rewrite.map { ($0.tool, $0.from, $0.to, 0) })
    }
    var mirrorsToolParameters: Bool { base.mirrorsToolParameters }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        exchanges.withLock { $0 += 1 }
        try await base.exchange(request) { data in
            let replaced: Data? = self.rewrite.withLock { state in
                guard var s = state, request.method == "tools/call", request.name == s.tool,
                      let text = String(data: data, encoding: .utf8), text.contains(s.from) else { return nil }
                s.applied += 1; state = s
                return Data(text.replacingOccurrences(of: s.from, with: s.to).utf8)
            }
            try await receive(replaced ?? data)
        }
    }
    var applied: Int { rewrite.withLock { $0?.applied ?? 0 } }
}
/// Never answers; ends only when cancelled. Proves cancellation leaves no exchange behind.
private final class ParkedTransport: ClientTransport, Sendable {
    let state = Mutex((entered: 0, ended: 0))
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        state.withLock { $0.entered += 1 }
        defer { state.withLock { $0.ended += 1 } }
        while true { try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor private final class LiveServer {
    let service: ExplorerService, activity = ActivityStore(), controller: ServerController
    init(service: ExplorerService) {
        let activity = self.activity
        self.service = service
        controller = ServerController(activity: activity, factory: { id in
            SDKHTTPHost(service: service, activity: activity, runID: id, configuration: try LocalEndpoint(port: 0))
        })
    }
    func start() async throws -> ServerEndpoint {
        controller.start()
        for _ in 0..<1000 {
            if controller.phase == .running, let endpoint = controller.endpoint { return endpoint }
            if controller.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await controller.stopAndJoin(); throw MCPResearchFailure.transport
    }
    func stop() async -> Bool { await controller.stopAndJoin() }
}
private func connect(_ endpoint: ServerEndpoint, rewrite: (tool: String, from: String, to: String)? = nil) throws -> (MCPResearchClient, ProxyTransport) {
    let proxy = ProxyTransport(try MCPJourneyController.httpTransport(endpoint), rewrite: rewrite)
    return (MCPResearchClient(client: Client(transport: proxy), profile: .offlineDemo), proxy)
}
@MainActor private func failure(_ body: @MainActor () async throws -> Void) async -> (any Error)? {
    do { try await body(); return nil } catch { return error }
}
private final class Clock: Sendable {
    let now = Mutex(Date(timeIntervalSince1970: 1_000))
    func advance(_ s: TimeInterval) { now.withLock { $0 += s } }
}

/// RE-02 (#34): a real public-SDK client over real loopback HTTP against this app's host.
@Suite(.serialized) struct MCPHTTPJourneyTests {
    @Test @MainActor func mcpAndDirectPathsReturnTheSameRevisionBoundResults() async throws {
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let server = LiveServer(service: service)
        let endpoint = try await server.start()
        do {
            let (mcp, proxy) = try connect(endpoint)
            let (_, tools) = try await mcp.prepare()
            #expect(Set(tools.map(\.name)) == Set(MCPResearchClient.toolNames) && tools.allSatisfy { $0.outputSchema != nil })
            let clients: [any ResearchClient] = [service, mcp]
            var rendered: [String] = []
            for client in clients {
                let page = try await client.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10))
                let outline = try await client.outline(.init(project: "fixture-enwiki", candidateID: try #require(page.candidates.first).id))
                var text = "\(page.candidates.map(\.id))|\(outline.snapshot)|\(outline.sections.map(\.location.partID))"
                for section in outline.sections {
                    let passage = try await client.section(.init(snapshot: outline.snapshot, part: section.location, maxTextBytes: nil))
                    let refs = try await client.references(.init(snapshot: outline.snapshot, part: section.location))
                    text += "|\(passage.text)|\(refs.references.map(\.id))|\(refs.unresolvedIDs)|\(refs.associations.count)"
                }
                rendered.append(text)
            }
            #expect(rendered[0] == rendered[1], "direct and MCP paths agree on every section of the pinned revision")
            #expect(proxy.exchanges.withLock { $0 } >= 2 + 2 + 2 * 9)
            // Only real handler invocations reach Activity: 2 + 2×9 tool calls, no local-research events.
            let snapshot = await server.activity.snapshot()
            #expect(snapshot.completed == 20 && snapshot.failed == 0)
            #expect(snapshot.events.allSatisfy { $0.origin != .localResearch })
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }

    @Test @MainActor func guidedJourneyRunsAllHopsAndActivityCountsThem() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        let journey = MCPJourneyController()
        journey.start(endpoint: endpoint, running: true, source: .offlineDemo); await journey.waitUntilFinished()
        #expect(journey.phase == .completed && journey.problem == nil)
        #expect(journey.steps.map(\.tool) == [nil, "search_articles", "get_article_outline", "read_article_section", "get_section_references"])
        #expect(journey.steps.allSatisfy { $0.status == .succeeded && $0.validated && $0.failure == nil })
        #expect(journey.outline?.snapshot.revisionID == "r1" && journey.passage?.selectedPartID == OfflineTour.partID)
        #expect(journey.references?.references.map(\.id) == ["ref-instrument-notes"])
        #expect(await server.activity.snapshot().completed == 4)
        await journey.shutdown()
        #expect(await server.stop())
    }

    @Test @MainActor func journeyNeverConnectsWithoutARunningServer() async throws {
        let made = Mutex(0)
        let journey = MCPJourneyController(makeTransport: { _ in made.withLock { $0 += 1 }; return ParkedTransport() })
        journey.start(endpoint: nil, running: false, source: .offlineDemo)
        journey.start(endpoint: try ServerEndpoint(host: "127.0.0.1", port: 9), running: false, source: .offlineDemo)
        await journey.waitUntilFinished()
        #expect(made.withLock { $0 } == 0 && journey.phase == .failed && !journey.isRunning)
        #expect(journey.steps.count == 1 && journey.steps[0].status == .failed)
    }

    @Test @MainActor func refusedConnectionIsATransportFailure() async throws {
        // Bind, learn the port, stop: nothing listens there afterwards.
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        #expect(await server.stop())
        let journey = MCPJourneyController()
        journey.start(endpoint: endpoint, running: true, source: .offlineDemo); await journey.waitUntilFinished()
        #expect(journey.phase == .failed && journey.steps.last?.failure == MCPJourneyController.describe(MCPResearchFailure.transport))
    }

    @Test @MainActor func cancelAndJoinLeavesNoExchangeInFlight() async throws {
        let parked = ParkedTransport()
        let journey = MCPJourneyController(makeTransport: { _ in parked })
        journey.start(endpoint: try ServerEndpoint(host: "127.0.0.1", port: 9), running: true, source: .offlineDemo)
        for _ in 0..<500 where parked.state.withLock({ $0.entered }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await journey.cancelAndJoin()
        #expect(journey.phase == .cancelled && !journey.isRunning && journey.steps.last?.status == .cancelled)
        #expect(parked.state.withLock { $0.entered == $0.ended && $0.entered >= 1 })
    }

    @Test @MainActor func schemaViolatingAndMismatchedResponsesAreRejected() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        do {
            // Schema violation on the wire: the SDK's outputSchema check rejects it.
            let (bad, badProxy) = try connect(endpoint, rewrite: ("search_articles", #""status":"ok""#, #""status":"maybe""#))
            try await bad.prepare()
            let e1 = await failure { _ = try await bad.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10)) }
            #expect(badProxy.applied == 1 && e1 as? MCPResearchFailure == .invalidResponse)
            // Schema-valid but for another revision: the adapter's identity check rejects it.
            let (direct, _) = try connect(endpoint)
            try await direct.prepare()
            let outline = try await direct.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
            let part = try #require(outline.sections.first?.location)
            let (swapped, swappedProxy) = try connect(endpoint, rewrite: ("read_article_section", #""revisionID":"r1""#, #""revisionID":"r9""#))
            try await swapped.prepare()
            let e2 = await failure { _ = try await swapped.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: nil)) }
            #expect(swappedProxy.applied == 1 && e2 as? MCPResearchFailure == .identityMismatch)
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }

    @Test @MainActor func unpreparedCallsSendNothingAndRejectedArgumentsStayDistinct() async throws {
        let server = LiveServer(service: ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits()))
        let endpoint = try await server.start()
        do {
            let (client, proxy) = try connect(endpoint)
            let e0 = await failure { _ = try await client.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10)) }
            #expect(e0 as? MCPResearchFailure == .notPrepared && proxy.exchanges.withLock { $0 } == 0)
            try await client.prepare()
            // Outside the input schema (limit ≤ 20): refused before the handler.
            let e1 = await failure { _ = try await client.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 21)) }
            let rejected: Bool = { if case .rejected = e1 as? MCPResearchFailure { return true }; return (e1 as? ExplorerProblem)?.code == .invalidArguments }()
            #expect(rejected, "got \(String(describing: e1))")
            // A domain problem stays a typed tool problem, not a transport or protocol failure.
            let e2 = await failure { _ = try await client.outline(.init(project: "fixture-enwiki", candidateID: "missing")) }
            #expect((e2 as? ExplorerProblem)?.code == .unknownCandidate)
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }

    @Test @MainActor func expiredSnapshotIsATypedToolProblemOverMCP() async throws {
        let clock = Clock()
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits(snapshotTTL: 5), clock: { clock.now.withLock { $0 } })
        let server = LiveServer(service: service)
        let endpoint = try await server.start()
        do {
            let (client, _) = try connect(endpoint)
            try await client.prepare()
            let outline = try await client.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
            clock.advance(6)
            let error = await failure { _ = try await client.section(.init(snapshot: outline.snapshot, part: try #require(outline.sections.first?.location), maxTextBytes: nil)) }
            #expect((error as? ExplorerProblem)?.code == .absentSnapshot)
        } catch { _ = await server.stop(); throw error }
        #expect(await server.stop())
    }
}
