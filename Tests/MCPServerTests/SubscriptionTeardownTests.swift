// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

private let teardownPrincipal = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("host"), resource: ScalarText("server"), scopes: [])
private let teardownOrigin = ScalarText("origin")
private func teardownServer() async throws -> Server {
    try await Server.make(info: JSONParser().parse(#"{"name":"teardown","version":"1"}"#), catalog: ServerCatalog(),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 8, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
}
private func teardownRequest(_ id: JSON) throws -> Data {
    let rawID = String(decoding: try JSONWriter().writeWithReport(id).result, as: UTF8.self)
    return Data(("{\"jsonrpc\":\"2.0\",\"id\":" + rawID + #", "method":"subscriptions/listen","params":{"notifications":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#).utf8)
}
private func teardownWait(_ condition: @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw CoreFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func teardownFrames(_ collector: EventCollector) async throws -> [JSON] {
    try await collector.snapshot.map { try JSONParser().parseWithReport(Array($0)).result }
}
private func teardownClean(_ server: Server) async {
    let s = await server.activity
    #expect(s.active == 0 && s.queued == 0 && s.requests == 0 && s.leases == 0 && s.bufferedBytes == 0 && s.subscriptions == 0 && s.eventBytes == 0)
}

// These exercise the actual core/event writer in two delivery modes. Real HTTP
// framing, socket cancellation and TLS shutdown remain separate qualification.
@Suite(.serialized) struct Sprint01SubscriptionTeardown {
    @Test func bothDeliveryModesSendOneCorrelatedCancellationBeforeComplete() async throws {
        for mode in [DeliveryMode.stdio, .http] {
            for id in [JSON.number(JSONNumber(integer: 0)), .number(JSONNumber(integer: 9_007_199_254_740_993)), .string("e\u{301}")] {
                let server = try await teardownServer(), collector = try EventCollector()
                let request = try teardownRequest(id)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll() }
                    group.addTask { try await collector.dispatch(request, to: server, principal: teardownPrincipal, origin: teardownOrigin, mode: mode) }
                    try await teardownWait { await collector.snapshot.count == 1 }
                    await server.closeSubscriptions()
                    try await group.waitForAll()
                }
                let frames = try await teardownFrames(collector)
                #expect(frames.count == 3)
                #expect(frames.compactMap { $0.objectValue?["method"]?.stringValue } == ["notifications/subscriptions/acknowledged", "notifications/cancelled"])
                let cancelled = try #require(frames.first(where: { $0.objectValue?["method"]?.stringValue == "notifications/cancelled" }))
                #expect(cancelled.objectValue?["params"]?.objectValue?["requestId"] == id)
                #expect(frames.last?.objectValue?["id"] == id)
                #expect(frames.last?.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
                for frame in frames {
                    let meta = frame.objectValue?["params"]?.objectValue?["_meta"] ?? frame.objectValue?["result"]?.objectValue?["_meta"]
                    #expect(meta?.objectValue?[ProtocolMetadata.subscriptionID] == id)
                }
                await teardownClean(server)
            }
        }
    }

    @Test func closingOnePrincipalAndOriginDoesNotTearDownOtherStreams() async throws {
        let server = try await teardownServer()
        let one = try EventCollector(), otherOrigin = try EventCollector(), otherPrincipal = try EventCollector()
        let peer = VerifiedPrincipal(subject: ScalarText("bob"), issuer: teardownPrincipal.issuer, resource: teardownPrincipal.resource, scopes: [])
        let request = try teardownRequest(.number(JSONNumber(integer: 0)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await one.dispatch(request, to: server, principal: teardownPrincipal, origin: teardownOrigin, mode: .http) }
            group.addTask { try await otherOrigin.dispatch(request, to: server, principal: teardownPrincipal, origin: ScalarText("other-origin"), mode: .http) }
            group.addTask { try await otherPrincipal.dispatch(request, to: server, principal: peer, origin: teardownOrigin, mode: .http) }
            try await teardownWait {
                let a = await one.snapshot.count
                let b = await otherOrigin.snapshot.count
                let c = await otherPrincipal.snapshot.count
                return a == 1 && b == 1 && c == 1
            }
            await server.closeSubscriptions(for: teardownPrincipal, origin: teardownOrigin)
            try await teardownWait { await one.snapshot.count == 3 }
            #expect(await otherOrigin.snapshot.count == 1)
            #expect(await otherPrincipal.snapshot.count == 1)
            await server.closeSubscriptions()
            try await group.waitForAll()
        }
        #expect(await one.snapshot.count == 3)
        #expect(await otherOrigin.snapshot.count == 3)
        #expect(await otherPrincipal.snapshot.count == 3)
        await teardownClean(server)
    }

    @Test func clientCancellationEmitsNoServerTeardownOrCompletion() async throws {
        for mode in [DeliveryMode.stdio, .http] {
            let server = try await teardownServer(), collector = try EventCollector()
            let id = try RequestID(.number(JSONNumber(integer: 17)))
            let request = try teardownRequest(id.value)
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    await #expect(throws: CancellationError.self) {
                        try await collector.dispatch(request, to: server, principal: teardownPrincipal, origin: teardownOrigin, mode: mode)
                    }
                }
                try await teardownWait { await collector.snapshot.count == 1 }
                try await server.cancel(id: id, principal: teardownPrincipal, origin: teardownOrigin)
                try await group.waitForAll()
            }
            let frames = try await teardownFrames(collector)
            #expect(frames.count == 1 && frames.first?.objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
            await teardownClean(server)
        }
    }

    @Test func failedCancellationWriteDoesNotInventDeliveryOrTryACompleteResponse() async throws {
        let server = try await teardownServer(), acknowledged = Mutex(false), attempts = Mutex([String]()), sinkFaultRaised = Mutex(false)
        let request = try teardownRequest(.number(JSONNumber(integer: 23)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                // Producer/writer completion can race after cancellation was
                // queued. Observe failure and the exact injected write boundary,
                // without claiming which concurrent owner error wins or calling
                // an arbitrary error actual Task cancellation.
                await #expect(throws: CoreFailure.self) {
                    try await server.dispatchEvents(request, principal: teardownPrincipal, origin: teardownOrigin, mode: .http) { bytes in
                        let frame = try JSONParser().parseWithReport(Array(bytes)).result
                        let method = frame.objectValue?["method"]?.stringValue ?? "terminal-response"
                        attempts.withLock { $0.append(method) }
                        if method == "notifications/subscriptions/acknowledged" { acknowledged.withLock { $0 = true } }
                        else { sinkFaultRaised.withLock { $0 = true }; throw CoreFailure.invalidOutput }
                    }
                }
            }
            try await teardownWait { acknowledged.withLock { $0 } }
            await server.closeSubscriptions()
            try await group.waitForAll()
        }
        #expect(attempts.withLock { $0 } == ["notifications/subscriptions/acknowledged", "notifications/cancelled"])
        #expect(sinkFaultRaised.withLock { $0 })
        await teardownClean(server)
    }
}
