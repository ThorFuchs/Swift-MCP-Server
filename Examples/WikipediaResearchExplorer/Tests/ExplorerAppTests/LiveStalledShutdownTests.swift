// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
@testable import WikimediaAccess
import ExplorerPresentation
@testable import WikipediaResearchExplorerApp

private actor LoopbackForwarder: LiveTransport {
    private var transport: WikipediaHTTPTransport?
    private var target: URL?
    func configure(_ transport: WikipediaHTTPTransport, target: URL) { self.transport = transport; self.target = target }
    func get(_ url: URL, deadline: ContinuousClock.Instant) async throws -> LiveHTTPResponse {
        guard let transport, let target else { throw LiveFailure.url }
        return try await transport.get(target, deadline: deadline)
    }
}
@Suite @MainActor struct LiveStalledShutdownTests {
    private enum Failure: Error { case timeout(String) }
    private func waitFile(_ file: URL, seconds: Int = 8) async throws -> String {
        for _ in 0..<(seconds * 100) {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timeout(file.lastPathComponent)
    }
    private func waitServer(_ app: AppLifetime) async throws {
        for _ in 0..<1200 {
            if app.server?.phase == .running { return }
            if app.server?.phase == .failed { throw Failure.timeout("server failed") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.timeout("server startup")
    }
    @Test func quitJoinsRealServerAndStalledURLSessionPeer() async throws {
        let forwarder = LoopbackForwarder()
        let service = ExplorerService(provider: WikipediaProvider(transport: forwarder), limits: try ExplorerLimits())
        let app = AppLifetime(profile: .wikipediaEnglish, loadService: { _ in service }, makeHost: { service, activity, id in
            SDKHTTPHost(service: service, activity: activity, runID: id, configuration: try LocalEndpoint(port: 0))
        })
        app.prepare(); await app.waitUntilPrepared(); app.startServer()
        do { try await waitServer(app) }
        catch { _ = await app.quit(waitMilliseconds: 10_000); throw error }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wre-app-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/Testing/live_stall_peer.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-S", "-B", fixture.path, directory.path]
        do { try process.run() } catch { _ = await app.quit(waitMilliseconds: 10_000); throw error }
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let port = try #require(Int(try await waitFile(directory.appendingPathComponent("port"))))
            let configuration = URLSessionConfiguration.ephemeral
            let transport = WikipediaHTTPTransport(configuration: configuration, allowedURL: { url in
                url.scheme == "http" && url.host == "127.0.0.1" && url.port == port && url.path == "/stall" && url.query == nil
            })
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/stall"))
            await forwarder.configure(transport, target: url)
            let research = try #require(app.research)
            research.query = "stall"; research.search()
            _ = try await waitFile(directory.appendingPathComponent("sent"))
            let clean = await app.quit(waitMilliseconds: 10_000)
            let closed = try await waitFile(directory.appendingPathComponent("closed"))
            print("App quit result: \(clean); real stalled peer observed: \(closed)")
            #expect(clean)
            #expect(app.server?.phase == .stopped && app.server?.cleanupDebt == false)
            #expect(closed == "eof" || closed == "reset")
        } catch {
            if process.isRunning { process.terminate() }
            _ = await app.quit(waitMilliseconds: 10_000)
            throw error
        }
    }
}
