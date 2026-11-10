// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

private func s07EventServer(_ handler: @escaping ProviderHandler, policy: EventPolicy) async throws -> Server {
    let tool = ToolRegistration(definition: try StateFixture.json(#"{"name":"events","inputSchema":{"type":"object"}}"#), handler: handler)
    return try await Server.make(info: StateFixture.json(#"{"name":"s07-events","version":"1"}"#),
        catalog: ServerCatalog(tools: [tool]), cursors: StateFixture.cursors(), events: policy)
}
private func s07Complete() throws -> JSON { try StateFixture.json(#"{"resultType":"complete","content":[]}"#) }
private func s07Frames(_ collector: EventCollector) async throws -> [JSON] {
    try await collector.snapshot.map { try JSONParser().parseWithReport(Array($0)).result }
}
private func s07Dispatch(_ server: Server, metadata: String = "") async throws -> [JSON] {
    let collector = try EventCollector(maximumFrames: 16, maximumBytes: 65536)
    try await collector.dispatch(StateFixture.request("tools/call", fields: #", "name":"events""#, metadata: metadata),
        to: server, principal: StateFixture.principal, origin: StateFixture.origin, mode: .http)
    return try await s07Frames(collector)
}
private func s07EventClean(_ server: Server) async {
    await StateFixture.clean(server)
    let state = await server.activity
    #expect(state.eventBytes == 0 && state.subscriptions == 0)
}

// Uses the actual public core with a deterministic clock. DeliveryMode.http here
// is in-process ordering, never a listener/TLS/disconnect qualification result.
@Suite(.serialized) struct S07EventAcceptance {
    @Test func configuredRedactorWithoutRequestOptInIsSilent() async throws {
        let redactions = Mutex(0)
        let policy = try EventPolicy(clock: { 1000 }, logRedactor: { value in
            redactions.withLock { $0 += 1 }; return value
        })
        let server = try await s07EventServer({ _, context in
            #expect(try await context.log(.emergency, data: .string("must stay private")) == false)
            return try s07Complete()
        }, policy: policy)
        let discovery = try await StateFixture.response(server, StateFixture.request("server/discover"))
        #expect(discovery.objectValue?["result"]?.objectValue?["capabilities"]?.objectValue?["logging"]?.objectValue != nil)
        let frames = try await s07Dispatch(server)
        #expect(redactions.withLock { $0 } == 0)
        #expect(frames.count == 1 && frames.first?.objectValue?["result"] != nil)
        await s07EventClean(server)
    }

    @Test func logThresholdThrottleAndRedactionArePerRequest() async throws {
        let clock = Mutex(Int64(1000)), inputs = Mutex([JSON]())
        let raw = try StateFixture.json(#"{"credential":"private","message":"visible"}"#)
        let safe = try StateFixture.json(#"{"message":"visible"}"#)
        let policy = try EventPolicy(clock: { clock.withLock { $0 } }, logRedactor: { value in
            inputs.withLock { $0.append(value) }; return safe
        })
        let server = try await s07EventServer({ _, context in
            #expect(try await context.log(.info, data: raw) == false)
            #expect(try await context.log(.warning, data: raw, logger: "public-category"))
            #expect(try await context.log(.emergency, data: raw) == false)
            clock.withLock { $0 += 50 }
            #expect(try await context.log(.error, data: raw))
            return try s07Complete()
        }, policy: policy)
        for _ in 0..<2 {
            let frames = try await s07Dispatch(server, metadata: #", "io.modelcontextprotocol/logLevel":"warning""#)
            #expect(frames.count == 3)
            #expect(frames.dropLast().map { $0.objectValue?["method"]?.stringValue } == ["notifications/message", "notifications/message"])
            #expect(frames[0].objectValue?["params"]?.objectValue?["level"]?.stringValue == "warning")
            #expect(frames[1].objectValue?["params"]?.objectValue?["level"]?.stringValue == "error")
            #expect(frames[0].objectValue?["params"]?.objectValue?["logger"]?.stringValue == "public-category")
            for frame in frames.dropLast() {
                #expect(frame.objectValue?["params"]?.objectValue?["data"] == safe)
                #expect(frame.objectValue?["params"]?.objectValue?["data"]?.objectValue?["credential"] == nil)
                #expect(frame.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?[ProtocolMetadata.subscriptionID] == nil)
            }
            #expect(frames.last?.objectValue?["result"] != nil)
            await s07EventClean(server)
        }
        #expect(inputs.withLock { $0 } == [raw, raw, raw, raw])
    }

    @Test func redactorFailureCannotEmitRawDataOrAdvanceThrottle() async throws {
        enum RedactionFailure: Error, Equatable { case refused }
        let attempts = Mutex(0), safe = JSON.string("redacted")
        let policy = try EventPolicy(clock: { 1000 }, logRedactor: { _ in
            let index = attempts.withLock { value in value += 1; return value }
            if index == 1 { throw RedactionFailure.refused }
            return safe
        })
        let server = try await s07EventServer({ _, context in
            await #expect(throws: RedactionFailure.refused) {
                _ = try await context.log(.error, data: .string("private first input"))
            }
            // Same instant: the failed redactor must not mark a log as sent.
            #expect(try await context.log(.error, data: .string("private retry input")))
            return try s07Complete()
        }, policy: policy)
        let frames = try await s07Dispatch(server, metadata: #", "io.modelcontextprotocol/logLevel":"debug""#)
        #expect(attempts.withLock { $0 } == 2 && frames.count == 2)
        #expect(frames.first?.objectValue?["params"]?.objectValue?["data"] == safe)
        #expect(frames.last?.objectValue?["result"] != nil)
        await s07EventClean(server)
    }

    @Test func suppressedProgressDoesNotAdvanceAcceptedValueOrEmissionClock() async throws {
        let clock = Mutex(Int64(1000))
        let policy = try EventPolicy(clock: { clock.withLock { $0 } })
        let server = try await s07EventServer({ _, context in
            #expect(try await context.progress(JSONNumber(integer: 1)))
            clock.withLock { $0 = 1010 }
            #expect(try await context.progress(JSONNumber(integer: 3)) == false)
            // Invalid values are rejected even during the suppression interval.
            await #expect(throws: CoreFailure.invalidInput) { _ = try await context.progress(JSONNumber(integer: 1)) }
            clock.withLock { $0 = 1040 }
            #expect(try await context.progress(JSONNumber(integer: 2)))
            return try s07Complete()
        }, policy: policy)
        let frames = try await s07Dispatch(server, metadata: #", "progressToken":"e\u0301""#)
        #expect(frames.count == 3)
        let values = frames.dropLast().compactMap { $0.objectValue?["params"]?.objectValue?["progress"]?.numberValue }
        #expect(values == [JSONNumber(integer: 1), JSONNumber(integer: 2)])
        #expect(frames.dropLast().allSatisfy { $0.objectValue?["params"]?.objectValue?["progressToken"]?.stringValue == "e\u{301}" })
        #expect(frames.last?.objectValue?["result"] != nil)
        await s07EventClean(server)
    }

    @Test(arguments: [#""exact-string""#, "9007199254740993"])
    func exactProgressSeparatesAdjacentValuesAndEchoesOriginalToken(token: String) async throws {
        let clock = Mutex(Int64(1000))
        let lexemes = ["9007199254740993.25", "9007199254740993.5", "9007199254740993.75"]
        let total = try JSONNumber(parsing: "9007199254740993.75")
        let policy = try EventPolicy(clock: { clock.withLock { $0 } })
        let server = try await s07EventServer({ _, context in
            for lexeme in lexemes {
                let value = try JSONNumber(parsing: lexeme)
                #expect(try await context.progress(value, total: total))
                await #expect(throws: CoreFailure.invalidInput) { _ = try await context.progress(value, total: total) }
                clock.withLock { $0 += 40 }
            }
            await #expect(throws: CoreFailure.invalidInput) {
                _ = try await context.progress(JSONNumber(parsing: "9007199254740994"), total: total)
            }
            return try s07Complete()
        }, policy: policy)
        let frames = try await s07Dispatch(server, metadata: ",\"progressToken\":\(token)")
        let originalToken = try StateFixture.json(token)
        #expect(frames.count == 4)
        for (index, frame) in frames.dropLast().enumerated() {
            #expect(frame.objectValue?["method"]?.stringValue == "notifications/progress")
            #expect(frame.objectValue?["params"]?.objectValue?["progressToken"] == originalToken)
            #expect(frame.objectValue?["params"]?.objectValue?["progress"]?.numberValue == (try JSONNumber(parsing: lexemes[index])))
            #expect(frame.objectValue?["params"]?.objectValue?["total"]?.numberValue == total)
        }
        #expect(frames.last?.objectValue?["result"] != nil)
        await s07EventClean(server)
    }

    @Test func backwardEventClockAndInvalidProgressProduceNoExtraFrame() async throws {
        let clock = Mutex(Int64(1000))
        let policy = try EventPolicy(clock: { clock.withLock { $0 } })
        let server = try await s07EventServer({ _, context in
            await #expect(throws: CoreFailure.invalidInput) { _ = try await context.progress(JSONNumber(integer: -1)) }
            await #expect(throws: CoreFailure.invalidInput) {
                _ = try await context.progress(JSONNumber(integer: 2), total: JSONNumber(integer: 1))
            }
            #expect(try await context.progress(JSONNumber(integer: 0)))
            clock.withLock { $0 = 999 }
            await #expect(throws: CoreFailure.invalidPolicy) { _ = try await context.progress(JSONNumber(integer: 1)) }
            clock.withLock { $0 = 1040 }
            #expect(try await context.progress(JSONNumber(integer: 1)))
            return try s07Complete()
        }, policy: policy)
        let frames = try await s07Dispatch(server, metadata: #", "progressToken":0"#)
        #expect(frames.count == 3)
        #expect(frames.dropLast().compactMap { $0.objectValue?["params"]?.objectValue?["progress"]?.numberValue } == [JSONNumber(integer: 0), JSONNumber(integer: 1)])
        #expect(frames.last?.objectValue?["result"] != nil)
        await s07EventClean(server)
    }
}
