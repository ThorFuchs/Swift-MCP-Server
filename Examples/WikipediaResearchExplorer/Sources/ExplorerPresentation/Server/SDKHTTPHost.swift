// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPServiceLifecycle
import ExplorerMCP
import WikimediaAccess
import ExplorerDomain

private struct ToolActivityObserver: ExplorerToolObserver {
    let activity: ActivityStore, runID: UUID
    let profile: SourceProfile
    func withToolCall(_ name: String, operation: @escaping @Sendable () async throws -> JSON) async throws -> JSON {
        let token = await activity.startCall(run: runID, operation: name, profile: profile)
        do {
            let result = try await operation()
            await activity.finishCall(token, outcome: result.objectValue?["isError"]?.booleanValue == true ? .toolProblem : .success)
            return result
        } catch {
            await activity.finishCall(token, outcome: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
}
/// App-only host. Constructing this value owns no socket or SDK runtime.
public actor SDKHTTPHost: ExplorerHTTPHost {
    private let service: ExplorerService, activity: ActivityStore, runID: UUID, configuration: LocalEndpoint
    private var runtime: ServerService?
    private var core: Server?
    private var stopRequested = false
    private var used = false
    public init(service: ExplorerService, activity: ActivityStore, runID: UUID, configuration: LocalEndpoint) {
        self.service = service; self.activity = activity; self.runID = runID; self.configuration = configuration
    }
    public func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws {
        guard !used else { throw HostFailure.invalidConfiguration }; used = true
        guard !stopRequested else { return }
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let server: Server
        do {
            server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: key,
                clock: { Int64(Date().timeIntervalSince1970 * 1000) }, observer: ToolActivityObserver(activity: activity, runID: runID, profile: service.profile))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Bounded startup-phase failure, before HTTPTransport or readiness.
            // This is not a diagnosis that every catalog failure is a resource
            // failure; keep the unchanged catalog oracle for the real cause.
            throw HostFailure.catalogUnavailable
        }
        core = server
        do {
            let principal = VerifiedPrincipal(subject: ScalarText(service.profile == .offlineDemo ? "local-offline-demo" : "local-wikipedia-english"), issuer: ScalarText("wre-app"), resource: ScalarText("wre-loopback-http"), scopes: [])
            let transport = try HTTPTransport(server: server, configuration: .init(host: "127.0.0.1", port: configuration.port,
                admission: .init(maximumBodyBytes: 65_536),
                authority: AuthorityPolicy(authorities: ["127.0.0.1"], origins: [], portPolicy: .boundListener),
                security: .loopbackDevelopment(principal), connections: 16, headerBytes: 8192, headerCount: 64,
                ioMilliseconds: 10_000, drainMilliseconds: 3000))
            let component = try TransportService(name: "http", run: { announce in
                try await transport.run { address in
                    guard !address.tls else { throw HostFailure.invalidConfiguration }
                    try await announce(); await ready(try ServerEndpoint(host: address.host, port: address.port))
                }
            }, shutdown: { await transport.shutdown() })
            let runtime = try ServerService(components: [component], stopAdmission: { await server.stopAdmission(); await server.closeSubscriptions() })
            self.runtime = runtime
            if stopRequested { runtime.requestShutdown() }
            try await runtime.run()
            let report = await runtime.report
            guard report.started == report.joined, report.failure == nil else { throw HostFailure.cleanupDebt }
        } catch {
            let primary = error
            guard await settle(server) else { throw HostFailure.cleanupDebt }
            throw primary
        }
        guard await settle(server) else { throw HostFailure.cleanupDebt }
    }
    private func settle(_ server: Server) async -> Bool {
        await server.stopAdmission(); await server.closeSubscriptions()
        let a = await server.activity
        guard a.active == 0, a.queued == 0, a.requests == 0, a.leases == 0,
              a.bufferedBytes == 0, a.subscriptions == 0, a.eventBytes == 0,
              a.inspections == 0, a.queuedInspections == 0 else { return false }
        core = nil; runtime = nil; return true
    }
    public func stop() async throws { stopRequested = true; runtime?.requestShutdown() }
}
