// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// The fixture binary Scripts/test.sh builds (Tools/StdioFixture); its absence is an error.
private func fixture() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["MCP_STDIO_FIXTURE"], FileManager.default.isExecutableFile(atPath: path) else {
        throw StdioClientTransportError.notRunning
    }
    return path
}

/// Runs the transport for the body's duration, then shuts it down and joins it.
private func withStdio(_ transport: StdioClientTransport, trace: StdioStartupTrace? = nil,
                       _ body: @escaping @Sendable (Client) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            if let trace { try await trace.run(transport) }
            else { try await transport.run() }
        }
        let client = Client(transport: transport)
        // run() is ready once exchanges are accepted; discover doubles as the readiness probe.
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do { _ = try await client.discover(); trace?.ready(); break }
            catch StdioClientTransportError.notRunning where ContinuousClock.now < end {
                trace?.notRunning()
                try await Task.sleep(for: .milliseconds(20))
            }
            catch {
                trace?.mark("discover.error \(String(reflecting: error))")
                throw error
            }
        }
        trace?.mark("body.begin")
        do { try await body(client) } catch {
            trace?.mark("body.error \(String(reflecting: error))")
            transport.shutdown()
            do { try await group.waitForAll() }
            catch { trace?.mark("join.error \(String(reflecting: error))") }
            throw error
        }
        trace?.mark("shutdown.requested")
        transport.shutdown()
        try await group.waitForAll()
        trace?.mark("shutdown.joined")
    }
}

@Suite(.serialized) struct StdioClientCases {
    @Test func concurrentRequestsProgressAndShutdownOverOneChannel() async throws {
        let trace = StdioStartupTrace("StdioClientCases.concurrentRequestsProgressAndShutdownOverOneChannel")
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(try fixture())),
            standardError: { trace.fixtureLine($0) }))
        try await withStdio(transport, trace: trace) { client in
            #expect(try await client.listTools().items.count == 5)
            // Four requests in flight on the shared channel are routed back by id.
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<3 { group.addTask { try await client.callTool("delay").resultType } }
                group.addTask { try await client.callTool("echo").text }
                var results: [String] = []
                for try await result in group { results.append(result) }
                #expect(results.sorted() == ["complete", "complete", "complete", "世界\nhello"])
            }
            let progress = Mutex<[Double]>([])
            _ = try await client.callTool("publish", onProgress: { value in progress.withLock { $0.append(value.progress) } })
            #expect(progress.withLock { $0 } == [0.25])
        }
        // After shutdown the transport refuses new exchanges.
        await #expect(throws: StdioClientTransportError.notRunning) { _ = try await Client(transport: transport).listTools() }
    }

    @Test func cancellingACallNotifiesTheServerAndKeepsTheChannelUsable() async throws {
        let entered = Mutex(0)
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(try fixture())),
            standardError: { line in if line.contains("ENTERED slow") { entered.withLock { $0 += 1 } } }))
        try await withStdio(transport) { client in
            let call = Task { try await client.callTool("slow") }
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while entered.withLock({ $0 }) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
            call.cancel()
            await #expect(throws: CancellationError.self) { _ = try await call.value }
            // The server stopped the slow call (it only ends by cancellation) and keeps serving.
            #expect(try await client.callTool("echo").text == "世界\nhello")
        }
    }
}
