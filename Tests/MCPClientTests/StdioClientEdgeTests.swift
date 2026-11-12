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

private func fixture() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["MCP_STDIO_FIXTURE"], FileManager.default.isExecutableFile(atPath: path) else {
        throw StdioClientTransportError.notRunning
    }
    return path
}
private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }

/// Waits until the transport accepts exchanges (discover is the probe).
private func ready(_ client: Client) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(30))
    while true {
        do { _ = try await client.discover(); return }
        catch StdioClientTransportError.notRunning where ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
    }
}

@Suite(.serialized) struct StdioClientEdgeCases {
    @Test func listenOverStdioAcknowledgesAndCancelsCleanly() async throws {
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(try fixture()))))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            let client = Client(transport: transport)
            try await ready(client)
            let acknowledged = Mutex(false)
            let listening = Task {
                try await client.listen(try json(#"{"toolsListChanged":true}"#)) { event in
                    if case .acknowledged = event { acknowledged.withLock { $0 = true } }
                }
            }
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while !acknowledged.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
            #expect(acknowledged.withLock { $0 })
            // Cancelling the listen call sends notifications/cancelled; the channel stays usable.
            listening.cancel()
            await #expect(throws: CancellationError.self) { try await listening.value }
            #expect(try await client.callTool("echo").text == "世界\nhello")
            transport.shutdown()
            try await group.waitForAll()
        }
    }

    @Test func pendingRequestLimitAndOversizedMessagesFailClosed() async throws {
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(try fixture())),
            maximumPendingRequests: 1, maximumMessageBytes: 65_536))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            let client = Client(transport: transport)
            try await ready(client)
            // One request in flight: a second concurrent one is refused, not queued without bound.
            let first = Task { try await client.callTool("delay") }
            try await Task.sleep(for: .milliseconds(50))
            await #expect(throws: StdioClientTransportError.busy) { _ = try await client.callTool("echo") }
            _ = try await first.value
            // A response line beyond maximumMessageBytes ends the run; the call fails.
            await #expect(throws: (any Error).self) { _ = try await client.callTool("big") }
            await #expect(throws: StdioClientTransportError.messageTooLarge) { try await group.next() }
            group.cancelAll()
        }
    }

    @Test func aTransportCanBeRunAgainAfterTheServerExited() async throws {
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(try fixture()))))
        for round in 0..<2 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await transport.run() }
                let client = Client(transport: transport)
                try await ready(client)
                #expect(try await client.callTool("echo").text == "世界\nhello", "round \(round)")
                transport.shutdown()
                try await group.waitForAll()
            }
        }
    }
}
