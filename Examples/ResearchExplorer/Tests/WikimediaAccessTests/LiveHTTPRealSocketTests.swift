// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
@testable import WikimediaAccess

@Suite(.serialized) @MainActor struct LiveHTTPRealSocketTests {
    private func wait(_ file: URL, seconds: Int = 8) async throws -> String {
        for _ in 0..<(seconds * 100) {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.timeout(file.lastPathComponent)
    }
    private enum FixtureFailure: Error { case timeout(String) }
    private func check(deadline: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wre-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/Testing/live_stall_peer.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-S", "-B", fixture.path, directory.path]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        let port = try #require(Int(try await wait(directory.appendingPathComponent("port"))))
        let configuration = URLSessionConfiguration.ephemeral
        let transport = WikipediaHTTPTransport(configuration: configuration, allowedURL: { url in
            url.scheme == "http" && url.host == "127.0.0.1" && url.port == port && url.path == "/stall" && url.query == nil
        })
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/stall"))
        let task = Task { try await transport.get(url, deadline: ContinuousClock.now.advanced(by: .seconds(deadline ? 2 : 6))) }
        do {
            _ = try await wait(directory.appendingPathComponent("sent"))
            if !deadline { task.cancel() }
            do { _ = try await task.value; Issue.record("A partial response must not complete successfully") }
            catch is CancellationError { if deadline { Issue.record("Expected timeout rather than cancellation") } }
            catch let problem as ExplorerProblem { #expect(deadline && problem.code == .upstreamTimedOut) }
            let closed = try await wait(directory.appendingPathComponent("closed"))
            print("Loopback peer observed: \(closed)")
            #expect(closed == "eof" || closed == "reset")
        } catch { task.cancel(); _ = await task.result; throw error }
    }
    @Test func cancellationClosesStalledRealSocket() async throws { try await check(deadline: false) }
    @Test func deadlineClosesStalledRealSocket() async throws { try await check(deadline: true) }
}
