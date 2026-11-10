// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

private func eventServer(_ catalog: ServerCatalog, policy: EventPolicy? = nil) async throws -> Server {
    try await Server.make(info: StateFixture.json(#"{"name":"event-native","version":"1"}"#), catalog: catalog,
        cursors: StateFixture.cursors(), events: policy)
}
private func eventClean(_ server: Server) async {
    await StateFixture.clean(server)
    let state = await server.activity
    #expect(state.subscriptions == 0 && state.eventBytes == 0)
}
private func eventWait(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; try await Task.sleep(for: .milliseconds(1)) }
}
private func eventMessages(_ collector: EventCollector) async throws -> [JSON] {
    try await collector.snapshot.map { try JSONParser().parseWithReport(Array($0)).result }
}
private func eventTool(_ handler: @escaping ProviderHandler) throws -> ToolRegistration {
    .init(definition: try StateFixture.json(#"{"name":"event","inputSchema":{"type":"object"}}"#), handler: handler)
}
private func eventResources() throws -> [ResourceProvider] {
    try ["fixture://one", "fixture://two"].enumerated().map { index, uri in
        ResourceProvider(definition: try StateFixture.json("{\"name\":\"r\(index)\",\"uri\":\"\(uri)\"}")) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[]}"#)
        }
    }
}
private func overflowListen(id: String) -> Data {
    listenRequest(id: id, filters: #"{"toolsListChanged":true,"resourceSubscriptions":["fixture://one","fixture://two"]}"#)
}
private func eventComplete() throws -> JSON { try StateFixture.json(#"{"resultType":"complete","content":[]}"#) }
private func listenRequest(id: String = "9007199254740993", filters: String = #"{"toolsListChanged":true}"#) -> Data {
    StateFixture.request("subscriptions/listen", fields: ",\"notifications\":\(filters)", id: id)
}

@Suite(.serialized) struct RestorationEventCases {
    @Test func exactFractionalProgressAndLoggingPrecedeOneTerminal() async throws {
        let clock = Mutex(Int64(1000)), escaped = Mutex<RequestContext?>(nil)
        let tool = try eventTool { _, context in
            let events = context; escaped.withLock { $0 = events }
            #expect(try await events.progress(JSONNumber(parsing: "0.5"), total: JSONNumber(parsing: "9007199254740994")))
            await #expect(throws: CoreFailure.invalidInput) { _ = try await events.progress(JSONNumber(parsing: "0.5")) }
            #expect(try await events.progress(JSONNumber(parsing: "0.75")) == false)
            clock.withLock { $0 += 50 }
            #expect(try await events.progress(JSONNumber(parsing: "9007199254740993.25")))
            #expect(try await events.log(.debug, data: .string("filtered")) == false)
            #expect(try await events.log(.warning, data: .string("safe")))
            return try eventComplete()
        }
        let server = try await eventServer(ServerCatalog(tools: [tool]), policy: EventPolicy(clock: { clock.withLock { $0 } }, logRedactor: { $0 }))
        let collector = try EventCollector()
        let bytes = StateFixture.request("tools/call", fields: #", "name":"event""#, id: #""call""#,
            metadata: #", "progressToken":9007199254740993,"io.modelcontextprotocol/logLevel":"warning""#)
        try await server.dispatchEvents(bytes, principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { try await collector.record($0) }
        let messages = try await eventMessages(collector)
        #expect(messages.count == 4)
        #expect(messages.dropLast().compactMap { $0.objectValue?["method"]?.stringValue } == ["notifications/progress", "notifications/progress", "notifications/message"])
        #expect(messages.last?.objectValue?["id"]?.stringValue == "call")
        #expect(messages[1].objectValue?["params"]?.objectValue?["progress"]?.numberValue == (try JSONNumber(parsing: "9007199254740993.25")))
        #expect(try messages[0].objectValue?["params"]?.objectValue?["progressToken"]?.numberValue?.integer(as: Int64.self, limits: .balanced) == 9_007_199_254_740_993)
        #expect(messages.dropLast().allSatisfy { $0.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?[ProtocolMetadata.subscriptionID] == nil })
        let events = try #require(escaped.withLock { $0 })
        await #expect(throws: CoreFailure.eventsUnavailable) { _ = try await events.progress(JSONNumber(integer: 9_007_199_254_740_994)) }
        await #expect(throws: CoreFailure.eventsUnavailable) { _ = try await events.log(.emergency, data: .string("late")) }
        #expect(await collector.snapshot.count == 4)
        await eventClean(server)
    }

    @Test func loggingDefaultsOffAndOneResponseListenIsExplicitlyUnsupported() async throws {
        let calls = Mutex(0)
        let tool = try eventTool { _, context in
            calls.withLock { $0 += 1 }
            let events = context
            #expect(try await events.log(.emergency, data: .string("disabled")) == false)
            return try eventComplete()
        }
        let server = try await eventServer(ServerCatalog(tools: [tool]))
        let discovery = try await StateFixture.response(server, StateFixture.request("server/discover"))
        #expect(discovery.objectValue?["result"]?.objectValue?["capabilities"]?.objectValue?["logging"] == nil)
        let collector = try EventCollector()
        try await server.dispatchEvents(StateFixture.request("tools/call", fields: #", "name":"event""#,
            metadata: #", "io.modelcontextprotocol/logLevel":"debug""#), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { try await collector.record($0) }
        #expect(await collector.snapshot.count == 1)
        let unsupported = try await StateFixture.response(server, listenRequest())
        #expect(try unsupported.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32601)
        let bad = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"event""#,
            metadata: #", "io.modelcontextprotocol/logLevel":"verbose""#))
        #expect(bad.objectValue?["error"] != nil && calls.withLock { $0 } == 1)
        await eventClean(server)
    }

    @Test func acknowledgedFiltersAudienceAndD02Modes() async throws {
        let tool = try eventTool { _, _ in try eventComplete() }
        let publicResource = ResourceProvider(definition: try StateFixture.json(#"{"name":"public","uri":"fixture://public"}"#)) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[]}"#)
        }
        let privateResource = ResourceProvider(definition: try StateFixture.json(#"{"name":"private","uri":"fixture://private"}"#), requiredScopes: [ScalarText("secret")]) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[]}"#)
        }
        let server = try await eventServer(ServerCatalog(tools: [tool], resources: [publicResource, privateResource]))
        for mode in [DeliveryMode.stdio, .http] {
            let collector = try EventCollector()
            let bytes = listenRequest(filters: #"{"toolsListChanged":true,"promptsListChanged":true,"resourceSubscriptions":["fixture://public","fixture://private"]}"#)
            let operation = Task { try await server.dispatchEvents(bytes, principal: StateFixture.principal, origin: StateFixture.origin, mode: mode) { try await collector.record($0) } }
            do {
                try await eventWait { await collector.snapshot.count == 1 }
                try await server.publish(.resourceUpdated(ScalarText("fixture://private")), audience: .requiringScopes([]))
                try await server.publish(.resourceUpdated(ScalarText("fixture://public")), audience: .principal(VerifiedPrincipal(subject: ScalarText("excluded"), issuer: StateFixture.principal.issuer, resource: StateFixture.principal.resource, scopes: [])))
                try await server.publish(.resourceUpdated(ScalarText("fixture://public")), audience: .principal(StateFixture.principal))
                try await server.publish(.toolsChanged, audience: .requiringScopes([]))
                try await server.publish(.promptsChanged, audience: .requiringScopes([]))
                try await eventWait { await collector.snapshot.count >= 4 }
                await server.closeSubscriptions()
                try await operation.value
            } catch { operation.cancel(); _ = await operation.result; throw error }
            let messages = try await eventMessages(collector)
            let methods = messages.compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(methods == ["notifications/subscriptions/acknowledged","notifications/resources/updated","notifications/tools/list_changed","notifications/prompts/list_changed","notifications/cancelled"])
            let selected = try #require(messages.first?.objectValue?["params"]?.objectValue?["notifications"]?.objectValue)
            #expect(selected["promptsListChanged"]?.booleanValue == true)
            #expect(selected["resourceSubscriptions"]?.arrayValue?.compactMap(\.stringValue) == ["fixture://public"])
            for message in messages {
                let meta = message.objectValue?["params"]?.objectValue?["_meta"] ?? message.objectValue?["result"]?.objectValue?["_meta"]
                #expect(try meta?.objectValue?[ProtocolMetadata.subscriptionID]?.numberValue?.integer(as: Int64.self, limits: .balanced) == 9_007_199_254_740_993)
            }
            #expect(messages.last?.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
            await eventClean(server)
        }
    }

    @Test func slowWriterOverflowCancelsAndReleasesInflightBytes() async throws {
        let entered = Mutex(false)
        let server = try await eventServer(ServerCatalog(tools: [eventTool { _, _ in try eventComplete() }], resources: eventResources()),
            policy: EventPolicy(queuedEvents: 2, queuedBytes: 1024, globalBytes: 4096, principalBytes: 2048, notificationBytes: 512))
        let operation = Task {
            try await server.dispatchEvents(overflowListen(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { _ in
                entered.withLock { $0 = true }
                while true { try await Task.sleep(for: .milliseconds(1)) }
            }
        }
        do {
            try await eventWait { entered.withLock { $0 } }
            #expect(await server.activity.eventBytes > 0)
            try await server.publish(.resourceUpdated(ScalarText("fixture://one")), audience: .requiringScopes([]))
            try await server.publish(.resourceUpdated(ScalarText("fixture://two")), audience: .requiringScopes([]))
            // The restored public writer surfaces the aborted sink as disconnected.
            await #expect(throws: CoreFailure.disconnected) { try await operation.value }
        } catch { operation.cancel(); _ = await operation.result; throw error }
        await eventClean(server)
    }

    @Test func failedSinkAndClientCancellationHaveNoInventedComplete() async throws {
        let attempts = Mutex(0), server = try await eventServer(ServerCatalog(tools: [eventTool { _, _ in try eventComplete() }]))
        await #expect(throws: CoreFailure.disconnected) {
            try await server.dispatchEvents(listenRequest(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { _ in
                attempts.withLock { $0 += 1 }; throw CoreFailure.invalidOutput
            }
        }
        #expect(attempts.withLock { $0 } == 1)
        await eventClean(server)
        let collector = try EventCollector()
        let operation = Task { try await server.dispatchEvents(listenRequest(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .stdio) { try await collector.record($0) } }
        do {
            try await eventWait { await collector.snapshot.count == 1 }
            let foreign = VerifiedPrincipal(subject: ScalarText("foreign"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
            try await server.cancel(id: RequestID(.number(JSONNumber(integer: 1))), principal: foreign, origin: StateFixture.origin)
            #expect(await server.activity.subscriptions == 1)
            try await server.cancel(id: RequestID(.number(JSONNumber(integer: 1))), principal: StateFixture.principal, origin: StateFixture.origin)
            await #expect(throws: CancellationError.self) { try await operation.value }
        } catch { operation.cancel(); _ = await operation.result; throw error }
        let messages = try await eventMessages(collector)
        #expect(messages.count == 1 && messages[0].objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
        await eventClean(server)
    }

    @Test func subscriberQuotaRejectsSecondBeforeAcknowledgement() async throws {
        let server = try await eventServer(ServerCatalog(tools: [eventTool { _, _ in try eventComplete() }]), policy: EventPolicy(subscriptions: 1, subscriptionsPerPrincipal: 1))
        let first = try EventCollector(), second = try EventCollector()
        let operation = Task { try await server.dispatchEvents(listenRequest(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { try await first.record($0) } }
        do {
            try await eventWait { await first.snapshot.count == 1 }
            try await server.dispatchEvents(listenRequest(id: "2"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { try await second.record($0) }
            let rejected = try await eventMessages(second)
            #expect(rejected.count == 1 && rejected[0].objectValue?["error"] != nil && rejected[0].objectValue?["method"] == nil)
            await server.closeSubscriptions(for: StateFixture.principal, origin: StateFixture.origin)
            try await operation.value
        } catch { operation.cancel(); _ = await operation.result; throw error }
        await eventClean(server)
    }
}

@Suite(.serialized) struct RestorationEventOwnershipCases {
    @Test func overflowingSubscriberCannotStarveAnotherPrincipal() async throws {
        let blocked = Mutex(false)
        let bob = VerifiedPrincipal(subject: ScalarText("bob"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
        let server = try await eventServer(ServerCatalog(tools: [eventTool { _, _ in try eventComplete() }], resources: eventResources()),
            policy: EventPolicy(queuedEvents: 2, queuedBytes: 1024, globalBytes: 4096, principalBytes: 2048, notificationBytes: 512))
        let fast = try EventCollector()
        let slowOperation = Task { try await server.dispatchEvents(overflowListen(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { _ in
            blocked.withLock { $0 = true }; while true { try await Task.sleep(for: .milliseconds(1)) }
        } }
        let fastOperation = Task { try await server.dispatchEvents(overflowListen(id: "2"), principal: bob, origin: StateFixture.origin, mode: .http) { try await fast.record($0) } }
        do {
            try await eventWait { let count = await fast.snapshot.count; return blocked.withLock { $0 } && count == 1 }
            try await server.publish(.resourceUpdated(ScalarText("fixture://one")), audience: .requiringScopes([]))
            try await eventWait { await fast.snapshot.count == 2 }
            try await server.publish(.resourceUpdated(ScalarText("fixture://two")), audience: .requiringScopes([]))
            await #expect(throws: CoreFailure.disconnected) { try await slowOperation.value }
            try await eventWait { await fast.snapshot.count == 3 }
            #expect(await server.activity.subscriptions == 1)
            await server.closeSubscriptions(for: StateFixture.principal, origin: StateFixture.origin)
            #expect(await server.activity.subscriptions == 1)
            await server.closeSubscriptions(for: bob, origin: StateFixture.origin)
            try await fastOperation.value
        } catch { slowOperation.cancel(); fastOperation.cancel(); _ = await slowOperation.result; _ = await fastOperation.result; throw error }
        await eventClean(server)
    }

    @Test func globalByteCeilingIsIndependentOfStreamEventCount() async throws {
        let entered = Mutex(0), release = Mutex(false)
        let bob = VerifiedPrincipal(subject: ScalarText("bob"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
        let server = try await eventServer(ServerCatalog(tools: [eventTool { _, _ in try eventComplete() }]),
            policy: EventPolicy(queuedEvents: 8, queuedBytes: 768, globalBytes: 768, principalBytes: 768, notificationBytes: 512))
        let sink: ResponseSink = { _ in entered.withLock { $0 += 1 }; while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) } }
        let aliceOperation = Task { try await server.dispatchEvents(listenRequest(id: "1"), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http, send: sink) }
        // Admit the second stream after the first acknowledgment has shrunk
        // its reservation. Concurrent initial512-byte reservations deliberately
        // would reject admission before this steady-state global-ceiling probe.
        do { try await eventWait { entered.withLock { $0 } == 1 } }
        catch { aliceOperation.cancel(); _ = await aliceOperation.result; throw error }
        let bobOperation = Task { try await server.dispatchEvents(listenRequest(id: "2"), principal: bob, origin: StateFixture.origin, mode: .http, send: sink) }
        do {
            try await eventWait { entered.withLock { $0 } == 2 }
            let before = await server.activity
            #expect(before.eventBytes > 0 && before.eventBytes <= 768)
            // The next512-byte reservation fits one stream/principal but exceeds
            // the global account already holding both acknowledgments.
            #expect(before.eventBytes / 2 + 512 <= 768 && before.eventBytes + 512 > 768)
            try await server.publish(.toolsChanged, audience: .principal(StateFixture.principal))
            try await eventWait { await server.activity.subscriptions == 1 }
            await #expect(throws: CoreFailure.disconnected) { try await aliceOperation.value }
            #expect(await server.activity.subscriptions == 1)
            release.withLock { $0 = true }
            await server.closeSubscriptions(for: bob, origin: StateFixture.origin)
            try await bobOperation.value
        } catch { aliceOperation.cancel(); bobOperation.cancel(); _ = await aliceOperation.result; _ = await bobOperation.result; throw error }
        await eventClean(server)
    }

    @Test func terminalCancellationRaceAndSerializationExhaustionStaySingleOwner() async throws {
        let entered = Mutex(0), released = Mutex(false)
        let server = try await eventServer(ServerCatalog(tools: [eventTool { _, context in
            entered.withLock { $0 += 1 }
            while !released.withLock({ $0 }) { try context.checkCancellation(); await Task.yield() }
            return try eventComplete()
        }]))
        for id in 1...8 {
            released.withLock { $0 = false }
            let collector = try EventCollector()
            let operation = Task { try await server.dispatchEvents(StateFixture.request("tools/call", fields: #", "name":"event""#, id: String(id)), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { try await collector.record($0) } }
            do { try await eventWait { entered.withLock { $0 } == id } }
            catch { operation.cancel(); _ = await operation.result; throw error }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { released.withLock { $0 = true } }
                group.addTask { operation.cancel() }
            }
            _ = await operation.result
            let messages = try await eventMessages(collector)
            #expect(messages.filter { $0.objectValue?["id"] != nil }.count <= 1)
            await eventClean(server)
        }
        let big = try eventTool { _, _ in
            struct Result: Encodable { let resultType = "complete"; let content: [Text] }
            struct Text: Encodable { let type = "text"; let text: String }
            return try JSONValueEncoder().encodeWithReport(Result(content: [.init(text: String(repeating: "x", count: 40_000))])).result
        }
        let small = try await Server.make(info: StateFixture.json(#"{"name":"event-limit","version":"1"}"#), catalog: ServerCatalog(tools: [big]),
            cursors: StateFixture.cursors(), configuration: ServerConfiguration(terminalWork: 4096))
        let attempts = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await small.dispatchEvents(StateFixture.request("tools/call", fields: #", "name":"event""#), principal: StateFixture.principal, origin: StateFixture.origin, mode: .http) { _ in attempts.withLock { $0 += 1 } }
        }
        #expect(attempts.withLock { $0 } == 0)
        await eventClean(small)
    }
}
