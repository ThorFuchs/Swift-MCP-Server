// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

private func exJSON(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let exNS = ScalarText("com.example/demo"), exMethod = ScalarText("com.example/demo/run"), exTag = ScalarText("com.example/demo/done")
private let exPrincipal = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [ScalarText("run")])
private func exRequest(method: String = exMethod.description, id: Int = 1, fields: String = #", "count":1"#, settings: String = #"{"version":1,"flavor":"blue"}"#, extraMeta: String = "") -> Data {
    let capabilities = settings == "absent" ? "{}" : "{\"extensions\":{\"com.example/demo\":\(settings)}}"
    return Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(capabilities)\(extraMeta)}\(fields)}}".utf8)
}
private func exQuote(_ s: String) throws -> String { String(decoding: try WireCodec.write(.string(s), limits: .balanced).result, as: UTF8.self) }
private func exRegistration(handler: @escaping ProviderHandler) throws -> ExtensionRegistration {
    try .init(identifier: exNS, settingsSchema: exJSON(#"{"type":"object","properties":{"version":{"const":1},"flavor":{"type":"string"}},"required":["version"]}"#),
        requests: [.init(method: exMethod, parametersSchema: exJSON(#"{"type":"object","properties":{"count":{"type":"integer"}},"required":["count"],"additionalProperties":false}"#), resultTypes: [exTag], requiredScopes: [ScalarText("run")], handler: handler)],
        results: [.init(type: exTag, schema: exJSON(#"{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}"#), coreMethods: [.callTool])],
        inputs: [.init(method: ScalarText("com.example/demo/confirm"), requestSchema: exJSON(#"{"type":"object","properties":{"method":{"const":"com.example/demo/confirm"}},"required":["method"]}"#), responseSchema: exJSON(#"{"type":"object","properties":{"approved":{"type":"boolean"}},"required":["approved"]}"#))],
        notifications: [.init(method: ScalarText("com.example/demo/note"), parametersSchema: exJSON(#"{"type":"object","properties":{"seq":{"type":"integer"}},"required":["seq"]}"#))])
}
private func exServer(_ registrations: [ExtensionRegistration], tools: [ToolRegistration] = [], configuration: ServerConfiguration? = nil) async throws -> Server {
    try await Server.make(info: exJSON(#"{"name":"extension","version":"1"}"#), catalog: ServerCatalog(tools: tools, extensions: registrations),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }), configuration: configuration,
        continuations: RequestStateProtector(keys: [.init(identifier: ScalarText("state"), material: Data(repeating: 3, count: 32))], active: ScalarText("state"), namespace: ScalarText("extension-tests"), epoch: ScalarText("v6"), clock: { 1000 }))
}
private func exResponse(_ server: Server, _ data: Data, principal: VerifiedPrincipal = exPrincipal) async throws -> JSON {
    try exJSON(String(decoding: #require(await server.handle(data, principal: principal, origin: ScalarText("host"))), as: UTF8.self))
}
private func exCode(_ value: JSON) -> Int? { try? value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) }
private func exClean(_ server: Server) async {
    let a = await server.activity
    #expect(a.active == 0 && a.requests == 0 && a.leases == 0 && a.bufferedBytes == 0 && a.eventBytes == 0)
}
@Suite(.serialized) struct ExtensionCases {
    @Test func activationSchemaDirectionsScopesAndMixedCoreResultsRemainExact() async throws {
        let calls = Mutex(0)
        let registration = try exRegistration { _, context in
            #expect(context.method.core == nil && context.method.extensionNamespace == exNS)
            calls.withLock { $0 += 1 }
            return try exJSON(#"{"resultType":"com.example/demo/done","value":2}"#)
        }
        let core = ToolRegistration(definition: try exJSON(#"{"name":"ext-tool","inputSchema":{"type":"object"}}"#)) { _, _ in
            try exJSON(#"{"resultType":"com.example/demo/done","value":3}"#)
        }
        let server = try await exServer([registration], tools: [core])
        for (settings, expected) in [("absent", -32601), (#"{"version":2}"#, -32602)] {
            #expect(exCode(try await exResponse(server, exRequest(settings: settings))) == expected)
        }
        #expect(exCode(try await exResponse(server, exRequest(fields: #", "count":"bad""#))) == -32602)
        let noScope = VerifiedPrincipal(subject: exPrincipal.subject, issuer: exPrincipal.issuer, resource: exPrincipal.resource, scopes: [])
        await #expect(throws: CoreFailure.insufficientScopes) { _ = try await exResponse(server, exRequest(), principal: noScope) }
        #expect(calls.withLock { $0 } == 0)
        #expect(try await exResponse(server, exRequest()).objectValue?["result"]?.objectValue?["resultType"]?.stringValue == exTag.description)
        #expect(exCode(try await exResponse(server, exRequest(method: "com.example/demo/confirm"))) == -32600)
        #expect(exCode(try await exResponse(server, exRequest(method: "com.example/demo/note"))) == -32600)
        #expect(exCode(try await exResponse(server, exRequest(method: "tools/call", fields: #", "name":"ext-tool""#, settings: "absent"))) == -32603)
        #expect(try await exResponse(server, exRequest(method: "tools/call", fields: #", "name":"ext-tool""#)).objectValue?["result"] != nil)
        #expect(WireMethod.allCases.count == 21 && FrozenWireDefinition.allCases.count == 155)
        await exClean(server)
    }
    @Test func registryRejectsDuplicatesCollisionsInvalidPlansAndUnsupportedReferences() async throws {
        let valid = try exRegistration { _, _ in try exJSON(#"{"resultType":"com.example/demo/done","value":1}"#) }
        await #expect(throws: CoreFailure.invalidInput) { _ = try await exServer([valid, valid]) }
        let collision = ExtensionRegistration(identifier: exNS, settingsSchema: .boolean(true), requests: [.init(method: ScalarText("tools/call"), parametersSchema: .boolean(true), resultTypes: [exTag]) { _, _ in .null }], results: valid.results)
        await #expect(throws: CoreFailure.invalidInput) { _ = try await exServer([collision]) }
        let wrong = ExtensionRegistration(identifier: exNS, settingsSchema: .boolean(true), requests: valid.requests, results: [valid.results[0], valid.results[0]])
        await #expect(throws: CoreFailure.invalidInput) { _ = try await exServer([wrong]) }
        let unsupported = ExtensionRegistration(identifier: exNS, settingsSchema: .boolean(true), results: [.init(type: exTag, schema: .boolean(true), coreMethods: [.listTools])])
        await #expect(throws: CoreFailure.invalidInput) { _ = try await exServer([unsupported]) }
        let bad = ExtensionRegistration(identifier: exNS, settingsSchema: try exJSON(#"{"$ref":"https://schemas.example.invalid/remote"}"#))
        await #expect(throws: (any Error).self) { _ = try await exServer([bad]) }
    }
    @Test func supplementalNotificationsUseOwnedChannelAndInvalidOrLateFormsCannotEmit() async throws {
        let escaped = Mutex<RequestContext?>(nil)
        let registration = try exRegistration { _, context in
            escaped.withLock { $0 = context }
            await #expect(throws: CoreFailure.invalidOutput) { try await context.notify(extensionMethod: ScalarText("com.example/demo/note"), parameters: exJSON(#"{"seq":"wrong"}"#)) }
            try await context.notify(extensionMethod: ScalarText("com.example/demo/note"), parameters: exJSON(#"{"seq":1}"#))
            return try exJSON(#"{"resultType":"com.example/demo/done","value":1}"#)
        }
        let server = try await exServer([registration]), collector = try EventCollector()
        try await collector.dispatch(exRequest(), to: server, principal: exPrincipal, origin: ScalarText("host"), mode: .http)
        let frames = try await collector.snapshot.map { try exJSON(String(decoding: $0, as: UTF8.self)) }
        #expect(frames.count == 2 && frames[0].objectValue?["method"]?.stringValue == "com.example/demo/note")
        #expect(frames[0].objectValue?["id"] == nil && frames[1].objectValue?["result"] != nil)
        let context = try #require(escaped.withLock { $0 })
        await #expect(throws: (any Error).self) { try await context.notify(extensionMethod: ScalarText("com.example/demo/note"), parameters: exJSON(#"{"seq":2}"#)) }
        let attempts = Mutex(0)
        try await server.dispatch(Data(#"{"jsonrpc":"2.0","method":"com.example/demo/note","params":{"seq":1}}"#.utf8), principal: exPrincipal, origin: ScalarText("host")) { _ in attempts.withLock { $0 += 1 } }
        #expect(attempts.withLock { $0 } == 0)
        await exClean(server)
    }
    @Test func declaredInputRequiredRetriesBindSettingsParametersAndCompatiblePlan() async throws {
        let effects = Mutex(0)
        let input = InputDescriptor(identifier: ScalarText("proof"), request: try exJSON(#"{"method":"com.example/demo/confirm"}"#))
        let provider = MultiRoundProvider(version: ScalarText("v1"), inputs: [input], replay: .integrityOnly) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(inputs: [input.identifier], state: .null)) }
            #expect(round.responses["proof"]?.objectValue?["approved"]?.booleanValue == true)
            effects.withLock { $0 += 1 }
            return .supplemental(try exJSON(#"{"resultType":"com.example/demo/done","value":1}"#))
        }
        let ordinary = try exRegistration { _, _ in .null }
        let rounds = ExtensionRegistration(identifier: exNS, settingsSchema: ordinary.settingsSchema,
            requests: [.init(method: exMethod, parametersSchema: ordinary.requests[0].parametersSchema, resultTypes: [exTag], requiredScopes: [ScalarText("run")], rounds: provider)], results: ordinary.results, inputs: ordinary.inputs)
        let a = try await exServer([rounds]), b = try await exServer([rounds])
        let first = try await exResponse(a, exRequest())
        let token = try #require(first.objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
        #expect(first.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?["proof"] != nil)
        await exClean(a)
        let fields = #", "count":1.0, "requestState":"# + (try exQuote(token))
        #expect(exCode(try await exResponse(b, exRequest(id: 2, fields: fields + #", "inputResponses":{"proof":{"roots":[]}}"#))) == -32602)
        #expect(exCode(try await exResponse(b, exRequest(id: 2, fields: fields, settings: #"{"version":1,"flavor":"green"}"#))) == -32602)
        let partial = try await exResponse(b, exRequest(id: 2, fields: fields))
        #expect(partial.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "input_required")
        #expect(effects.withLock { $0 } == 0)
        let state = try #require(partial.objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
        let done = try await exResponse(a, exRequest(id: 3, fields: #", "count":1, "requestState":"# + exQuote(state) + #", "inputResponses":{"proof":{"approved":true},"unrelated":{"approved":false}}"#))
        #expect(done.objectValue?["result"] != nil && effects.withLock { $0 } == 1)
        await exClean(a); await exClean(b)
    }
    @Test func malformedForeignOutputsAndSwallowedOperationalErrorNeverSucceed() async throws {
        for raw in ["null", #"{"resultType":"com.example/demo/foreign","value":1}"#, #"{"resultType":"com.example/demo/done","value":"bad"}"#, #"{"resultType":"com.example/demo/done","value":1,"_meta":0}"#] {
            let server = try await exServer([exRegistration { _, _ in try exJSON(raw) }])
            #expect(exCode(try await exResponse(server, exRequest())) == -32603)
            await exClean(server)
        }
        let escaped = Mutex<RequestBudget?>(nil)
        let exhausted = try await exServer([exRegistration { _, context in
            escaped.withLock { $0 = context.budget }
            do { try await context.budget.consume(UInt64.max) } catch { }
            return try exJSON(#"{"resultType":"com.example/demo/done","value":1}"#)
        }])
        #expect(try await exResponse(exhausted, exRequest()).objectValue?["result"] == nil)
        let budget = try #require(escaped.withLock { $0 })
        await #expect(throws: (any Error).self) { try await budget.consume(1) }
        #expect(await budget.snapshot.isTerminal)
        await exClean(exhausted)
    }
    @Test func registryCountAndSchemaSizeCeilingsAreOperationalAdmissionFailures() async throws {
        let registrations = (0..<65).map { ExtensionRegistration(identifier: ScalarText("com.example/n\($0)"), settingsSchema: .boolean(true)) }
        await #expect(throws: CoreFailure.limit) { _ = try await exServer(registrations) }
        let raw = try JSONValueEncoder().encodeWithReport(["description": String(repeating: "x", count: 262145)]).result
        await #expect(throws: (any Error).self) { _ = try await exServer([.init(identifier: exNS, settingsSchema: raw)]) }
    }
    @Test func changedDeclaredResponsePlanRejectsOldStateBeforeProviderEffect() async throws {
        let effects = Mutex(0)
        let descriptor = InputDescriptor(identifier: ScalarText("proof"), request: try exJSON(#"{"method":"com.example/demo/confirm"}"#))
        let provider = MultiRoundProvider(version: ScalarText("v1"), inputs: [descriptor], replay: .integrityOnly) { _, round, _ in
            if !round.isRetry { return .inputRequired(.init(inputs: [descriptor.identifier], state: .null)) }
            effects.withLock { $0 += 1 }; return .supplemental(try exJSON(#"{"resultType":"com.example/demo/done","value":1}"#))
        }
        let original = try exRegistration { _, _ in .null }
        func registration(_ schema: JSON) -> ExtensionRegistration {
            .init(identifier: exNS, settingsSchema: original.settingsSchema,
                requests: [.init(method: exMethod, parametersSchema: original.requests[0].parametersSchema, resultTypes: [exTag], rounds: provider)], results: original.results,
                inputs: [.init(method: ScalarText("com.example/demo/confirm"), requestSchema: original.inputs[0].requestSchema, responseSchema: schema)])
        }
        let a = try await exServer([registration(original.inputs[0].responseSchema)])
        let state = try #require(try await exResponse(a, exRequest()).objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
        let b = try await exServer([registration(exJSON(#"{"type":"object","properties":{"approved":{"const":true}},"required":["approved"]}"#))])
        #expect(exCode(try await exResponse(b, exRequest(fields: #", "count":1,"requestState":"# + exQuote(state) + #", "inputResponses":{"proof":{"approved":true}}"#))) == -32602)
        #expect(effects.withLock { $0 } == 0)
        await exClean(a); await exClean(b)
    }
    @Test func extensionCancellationDoesNotCrossPrincipalOrCurrentNegotiation() async throws {
        let entered = Mutex(Set<ScalarText>())
        let registration = try exRegistration { _, context in
            entered.withLock { $0.insert(context.principal.subject) }
            while true { try context.checkCancellation(); await Task.yield() }
        }
        let server = try await exServer([registration])
        let bob = VerifiedPrincipal(subject: ScalarText("bob"), issuer: exPrincipal.issuer, resource: exPrincipal.resource, scopes: exPrincipal.scopes)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for principal in [exPrincipal, bob] { group.addTask {
                do { _ = try await server.handle(exRequest(), principal: principal, origin: ScalarText("host")) }
                catch is CancellationError { }
            } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while entered.withLock({ $0.count }) < 2 { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; await Task.yield() }
            try await server.cancel(id: RequestID(.number(JSONNumber(integer: 1))), principal: exPrincipal, origin: ScalarText("host"))
            #expect(exCode(try await exResponse(server, exRequest(id: 2, settings: "absent"), principal: bob)) == -32601)
            while await server.activity.active != 1 { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; await Task.yield() }
            #expect(await server.activity.active == 1)
            try await server.cancel(id: RequestID(.number(JSONNumber(integer: 1))), principal: bob, origin: ScalarText("host"))
            try await group.waitForAll()
        }
        await exClean(server)
    }

    @Test func changedAllowedResultTagWithIdenticalPayloadSchemaInvalidatesState() async throws {
        let effects = Mutex(0), original = try exRegistration { _, _ in .null }
        let other = ScalarText("com.example/demo/other")
        func registration(_ tag: ScalarText) -> ExtensionRegistration {
            let provider = MultiRoundProvider(version: ScalarText("v1"), replay: .integrityOnly) { _, round, _ in
                if !round.isRetry { return .inputRequired(.init(state: .null)) }
                effects.withLock { $0 += 1 }
                return .supplemental(try exJSON("{\"resultType\":\"\(tag.description)\",\"value\":1}"))
            }
            return .init(identifier: exNS, settingsSchema: original.settingsSchema,
                requests: [.init(method: exMethod, parametersSchema: original.requests[0].parametersSchema, resultTypes: [tag], rounds: provider)],
                results: [.init(type: exTag, schema: original.results[0].schema), .init(type: other, schema: original.results[0].schema)])
        }
        let a = try await exServer([registration(exTag)]), b = try await exServer([registration(other)])
        let state = try #require(try await exResponse(a, exRequest()).objectValue?["result"]?.objectValue?["requestState"]?.stringValue)
        #expect(exCode(try await exResponse(b, exRequest(fields: #", "count":1, "requestState":"# + exQuote(state)))) == -32602)
        #expect(effects.withLock { $0 } == 0)
        await exClean(a); await exClean(b)
    }

}
