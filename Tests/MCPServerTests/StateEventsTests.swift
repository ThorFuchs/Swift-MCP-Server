// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting

private func v05json(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private let v05principal = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
private func v05server(_ catalog: ServerCatalog? = nil) async throws -> Server {
    try await Server.make(info: v05json(#"{"name":"state-events","version":"0.5"}"#), catalog: catalog ?? ServerCatalog(),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("key"), material: Data(repeating: 7, count: 32))], active: ScalarText("key"), epoch: ScalarText("cursor"), clock: { 1000 }))
}
@Suite(.serialized) struct NotificationSilence {
    @Test func actualDispatchSilencesNotificationsPreservesD01() async throws {
        let providers = Mutex(0), attempts = Mutex(0)
        let tool = ToolRegistration(definition: try v05json(#"{"name":"unused","inputSchema":{"type":"object"}}"#)) { _, _ in
            providers.withLock { $0 += 1 }; return try v05json(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await v05server(ServerCatalog(tools: [tool]))
        for text in [
            #"{"jsonrpc":"2.0","method":"com.example/unsupported","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":null}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"unknown","reason":7}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"unknown"}}"#
        ] {
            let before = attempts.withLock { $0 }
            try await server.dispatch(Data(text.utf8), principal: v05principal, origin: ScalarText("origin")) { _ in attempts.withLock { $0 += 1 } }
            #expect(attempts.withLock { $0 } == before, "recognizable notification: \(text)")
        }
        #expect(providers.withLock { $0 } == 0)
        for text in ["{}", "{bad", "[]", #"{"jsonrpc":"2.0","id":null,"method":"tools/list","params":{}}"#] {
            let result = try #require(await server.handle(Data(text.utf8), principal: v05principal, origin: ScalarText("origin")))
            let raw = try JSONParser().parseWithReport(Array(result)).result
            #expect(raw.objectValue?["error"] != nil && raw.objectValue?["id"]?.isNull == true)
        }
        let state = await server.activity
        #expect(state.active == 0 && state.queued == 0 && state.requests == 0 && state.leases == 0 && state.bufferedBytes == 0)
    }
}

private func v05request(_ method: String, fields: String = "", id: Int = 1, caps: String = #"{"roots":{},"elicitation":{"form":{},"url":{}},"sampling":{"tools":{},"context":{}}}"#, meta: String = "") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(caps)\(meta)}\(fields)}}".utf8)
}
private func v05response(_ server: Server, _ request: Data, identity: VerifiedPrincipal = v05principal, origin: String = "origin") async throws -> JSON {
    let bytes = try #require(await server.handle(request,principal:identity,origin:ScalarText(origin)))
    return try JSONParser().parseWithReport(Array(bytes)).result
}
private func v05state(_ result: JSON) throws -> String { try #require(result.objectValue?["result"]?.objectValue?["requestState"]?.stringValue) }
private func v05quote(_ text: String) throws -> String { String(decoding:try JSONWriter().writeWithReport(.string(text)).result,as:UTF8.self) }
private func v05code(_ raw: JSON) -> Int64? { try? raw.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as:Int64.self,limits:.balanced) }
private func v05protection(clock: @escaping @Sendable () -> Int64 = {1000}, version: String = "epoch", keys: [RequestStateProtector.Key]? = nil, active: String = "state", policy: ContinuationPolicy? = nil) throws -> RequestStateProtector {
    try .init(keys: keys ?? [.init(identifier:ScalarText("state"),material:Data(repeating:9,count:32))],active:ScalarText(active),namespace:ScalarText("portable-service"),epoch:ScalarText(version),policy:policy,clock:clock)
}
private func v05make(_ catalog: ServerCatalog, protection: RequestStateProtector? = nil, events: EventPolicy? = nil, configuration: ServerConfiguration? = nil) async throws -> Server {
    try await Server.make(info:v05json(#"{"name":"state-events","version":"0.5"}"#),catalog:catalog,
        cursors:CursorProtector(keys:[.init(identifier:ScalarText("cursor"),material:Data(repeating:9,count:32))],active:ScalarText("cursor"),epoch:ScalarText("cursor"),clock:{1000}),
        configuration:configuration,continuations:protection,events:events)
}
private func v05clean(_ server: Server) async {
    let a = await server.activity
    #expect(a.active == 0 && a.queued == 0 && a.requests == 0 && a.leases == 0 && a.bufferedBytes == 0 && a.subscriptions == 0 && a.eventBytes == 0)
}
private func v05wait(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by:.seconds(10))
    while !(await condition()) { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; await Task.yield() }
}
private let v05complete = #"{"resultType":"complete","content":[],"structuredContent":1}"#
private func v05roots(_ identifier: String = "roots") throws -> InputDescriptor { .init(identifier:ScalarText(identifier),request:try v05json(#"{"method":"roots/list"}"#)) }

@Suite(.serialized) struct MultiRoundCases {
    @Test func threeMethodsCrossInstanceIndependentAndWrongBranches() async throws {
        let calls = Mutex(0)
        let rounds = MultiRoundProvider(version:ScalarText("plan-v1"),inputs:[try v05roots()],replay:.integrityOnly) { _,round,context in
            calls.withLock { $0 += 1 }
            if !round.isRetry { return .inputRequired(.init(inputs:[ScalarText("roots")],state:.null)) }
            #expect(round.responses["roots"]?.objectValue?["roots"]?.arrayValue?.count == 1)
            if case .null = round.state {} else { Issue.record("null handler state was not preserved") }
            switch context.method {
            case .callTool: return .complete(try v05json(v05complete))
            case .readResource: return .complete(try v05json(#"{"resultType":"complete","contents":[{"uri":"fixture://r","text":"done"}]}"#))
            default: return .complete(try v05json(#"{"resultType":"complete","messages":[]}"#))
            }
        }
        let catalog = try ServerCatalog(tools:[.init(definition:v05json(#"{"name":"round","inputSchema":{"type":"object"},"outputSchema":{"type":"integer"}}"#),rounds:rounds)],resources:[.init(definition:v05json(#"{"name":"r","uri":"fixture://r"}"#),rounds:rounds)],prompts:[.init(definition:v05json(#"{"name":"p"}"#),rounds:rounds)])
        let a = try await v05make(catalog,protection:v05protection()), b = try await v05make(catalog,protection:v05protection())
        for (method,fields) in [("tools/call",#", "name":"round", "arguments":{"x":1}"#),("resources/read",#", "uri":"fixture://r""#),("prompts/get",#", "name":"p""#)] {
            let first = try await v05response(a,v05request(method,fields:fields))
            #expect(first.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "input_required")
            #expect(first.objectValue?["result"]?.objectValue?["ttlMs"] == nil)
            await v05clean(a)
            let state = try v05state(first)
            let retry = try await v05response(b,v05request(method,fields:fields + ", \"requestState\": " + v05quote(state) + #", "inputResponses":{"roots":{"roots":[{"uri":"file:///tmp"}]}}, "extra":"ignored""#,id:2),origin:"other-connection")
            #expect(retry.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
            await v05clean(b)
        }
        #expect(calls.withLock{$0} == 6)
        let invalid = MultiRoundProvider(version:ScalarText("bad"),replay:.integrityOnly) { _,_,_ in .inputRequired(.init()) }
        let wrong = ToolRegistration(definition:try v05json(#"{"name":"wrong","inputSchema":{"type":"object"}}"#)) { _,_ in try v05json(#"{"resultType":"input_required","requestState":"unprotected"}"#) }
        let server = try await v05make(ServerCatalog(tools:[wrong,.init(definition:v05json(#"{"name":"invalid","inputSchema":{"type":"object"}}"#),rounds:invalid)]),protection:v05protection())
        for name in ["wrong","invalid"] { #expect(v05code(try await v05response(server,v05request("tools/call",fields:", \"name\": " + v05quote(name)))) == -32603) }
        await v05clean(server)
    }
}

private func v05catalog(_ provider: MultiRoundProvider, scopes: Set<ScalarText> = []) throws -> ServerCatalog {
    try .init(tools:[.init(definition:v05json(#"{"name":"round","inputSchema":{"type":"object"}}"#),requiredScopes:scopes,rounds:provider)])
}
extension MultiRoundCases {
    @Test func mixedScalarInputsPartialFormAndExpectedKinds() async throws {
        let resumed = Mutex(0)
        let form = InputDescriptor(identifier:ScalarText("é"),request:try v05json(#"{"method":"elicitation/create","params":{"message":"name","requestedSchema":{"type":"object","properties":{"name":{"type":"string","minLength":2}},"required":["name"]}}}"#))
        let roots = try v05roots("e\u{301}")
        let sample = InputDescriptor(identifier:ScalarText("sample"),request:try v05json(#"{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"sample"}}],"maxTokens":10,"tools":[],"includeContext":"thisServer"}}"#))
        let url = InputDescriptor(identifier:ScalarText("url"),request:try v05json(#"{"method":"elicitation/create","params":{"mode":"url","message":"confirm","url":"https://example.test"}}"#))
        let provider = MultiRoundProvider(version:ScalarText("mixed"),inputs:[form,roots,sample,url],replay:.integrityOnly) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(inputs:[form.identifier,roots.identifier,sample.identifier,url.identifier],state:.value(.string("private")))) }
            resumed.withLock{$0 += 1}
            #expect(round.responses.count == 4)
            #expect(round.responses["é"]?.objectValue?["action"]?.stringValue == "accept")
            #expect(round.responses["e\u{301}"]?.objectValue?["roots"] != nil)
            return .complete(try v05json(v05complete))
        }
        let server = try await v05make(v05catalog(provider),protection:v05protection())
        let first = try await v05response(server,v05request("tools/call",fields:#", "name":"round""#))
        #expect(first.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?.count == 4)
        let original = try v05state(first)
        let base = #", "name":"round", "requestState":"# + (try v05quote(original))
        for responses in [#"{"é":{"roots":[]}}"#,#"{"é":{"action":"accept","content":{"name":"x"}}}"#,#"{"é":{"roots":[{"uri":"https://invalid.test"}]}}"#,#"{"url":{"action":"accept","content":{"x":true}}}"#] {
            #expect(v05code(try await v05response(server,v05request("tools/call",fields:base + #", "inputResponses":"# + responses,id:2))) == -32602)
        }
        #expect(resumed.withLock{$0} == 0)
        let partial = try await v05response(server,v05request("tools/call",fields:base + #", "inputResponses":{"é":{"action":"accept","content":{"name":"ok"}},"unrelated":{"roots":[]}}"#,id:2))
        #expect(partial.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?.count == 3)
        await v05clean(server)
        let complete = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(v05state(partial)) + #", "inputResponses":{"é":{"roots":[]},"sample":{"role":"assistant","model":"test","content":{"type":"text","text":"done"}},"url":{"action":"decline"},"unrelated":{"action":"cancel"}}"#,id:3))
        #expect(complete.objectValue?["result"] != nil && resumed.withLock{$0} == 1)
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:base + #", "inputResponses":{"unknown":7}"#,id:4))) == -32602)
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:base,id:5,caps:#"{"roots":{},"elicitation":{"form":{},"url":{}},"sampling":{}}"#))) == -32021)
        await v05clean(server)
    }

    @Test func stateBindingTamperPurposeAuthorityRotationAndPlans() async throws {
        let resumed = Mutex(0)
        func provider(_ version: String) -> MultiRoundProvider {
            .init(version:ScalarText(version),replay:.integrityOnly) { _,round,_ in
                if !round.isRetry { return .inputRequired(.init(state:.value(.string("private-state")))) }
                resumed.withLock{$0 += 1}; return .complete(try v05json(v05complete))
            }
        }
        let server = try await v05make(v05catalog(provider("v1")),protection:v05protection())
        let first = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "arguments":{"a":1,"b":"é"}"#))
        let state = try v05state(first)
        let base = #", "name":"round", "arguments":{"b":"é","a":1.0}, "requestState":"#
        for invalid in [state + "!", "c2." + state.dropFirst(3), state.replacingOccurrences(of:"c1.state.",with:"c1.unknown."), "1.state." + state.split(separator:".").last!, "", String(repeating:"A",count:33000)] {
            let response = try await v05response(server,v05request("tools/call",fields:base + v05quote(invalid),id:2))
            #expect(v05code(response) == -32602)
            let bytes = try JSONWriter().writeWithReport(response).result
            #expect(!String(decoding:bytes,as:UTF8.self).contains("private-state"))
        }
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:base + v05quote(state),id:1))) == -32602)
        for foreign in [
            VerifiedPrincipal(subject:ScalarText("mallory"),issuer:ScalarText("issuer"),resource:ScalarText("server"),scopes:[]),
            VerifiedPrincipal(subject:ScalarText("alice"),issuer:ScalarText("issuer"),resource:ScalarText("other"),scopes:[])
        ] { #expect(v05code(try await v05response(server,v05request("tools/call",fields:base + v05quote(state),id:2),identity:foreign)) == -32602) }
        for changed in [#", "name":"round", "arguments":{"a":2,"b":"é"}, "requestState":"#,#", "name":"round", "arguments":{"a":1,"b":"é"}, "requestState":"#,#", "name":"round", "requestState":"#] {
            #expect(v05code(try await v05response(server,v05request("tools/call",fields:changed + v05quote(state),id:2))) == -32602)
        }
        let key1 = try RequestStateProtector.Key(identifier:ScalarText("state"),material:Data(repeating:9,count:32))
        let key2 = try RequestStateProtector.Key(identifier:ScalarText("new"),material:Data(repeating:8,count:32))
        let rotated = try await v05make(v05catalog(provider("v1")),protection:v05protection(keys:[key1,key2],active:"new"))
        #expect(try await v05response(rotated,v05request("tools/call",fields:base + v05quote(state),id:2),origin:"new-origin").objectValue?["result"] != nil)
        let removed = try await v05make(v05catalog(provider("v1")),protection:v05protection(keys:[key2],active:"new"))
        #expect(v05code(try await v05response(removed,v05request("tools/call",fields:base + v05quote(state),id:2))) == -32602)
        let epoch = try await v05make(v05catalog(provider("v1")),protection:v05protection(version:"changed"))
        #expect(v05code(try await v05response(epoch,v05request("tools/call",fields:base + v05quote(state),id:2))) == -32602)
        try await server.replaceCatalog(v05catalog(provider("v2")))
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:base + v05quote(state),id:2))) == -32602)
        #expect(resumed.withLock{$0} == 1)
        let cursor = try CursorProtector(keys:[.init(identifier:ScalarText("state"),material:Data(repeating:9,count:32))],active:ScalarText("state"),epoch:ScalarText("cursor"),clock:{1000})
        let ctx = CursorContext(principal:v05principal,method:.listTools,parameters:try v05json("{}"),generation:1,catalogInstance:ScalarText("catalog"))
        await #expect(throws:CoreFailure.invalidCursor) { _ = try await cursor.open(state,context:ctx,budget:RequestBudget(workUnits:64000000)) }
        let token = try await cursor.seal(offset:1,context:ctx,budget:RequestBudget(workUnits:64000000))
        #expect(v05code(try await v05response(rotated,v05request("tools/call",fields:base + v05quote(token),id:3))) == -32602)
        await v05clean(server); await v05clean(rotated)
    }

    @Test func finiteChainsExpiryInputOnlyDeclineCancelAndRevocation() async throws {
        let now = Mutex(Int64(1000))
        let repeating = MultiRoundProvider(version:ScalarText("repeat"),replay:.integrityOnly) { _,_,_ in .inputRequired(.init(state:.null)) }
        let server = try await v05make(v05catalog(repeating),protection:v05protection(clock:{now.withLock{$0}},policy:ContinuationPolicy(maximumAttempts:2,lifetimeMilliseconds:100,maximumChainWork:128000000)))
        let first = try await v05response(server,v05request("tools/call",fields:#", "name":"round""#))
        now.withLock{$0 = 1050}
        let second = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(v05state(first)),id:2))
        #expect(second.objectValue?["result"]?.objectValue?["inputRequests"] == nil)
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(v05state(second)),id:3))) == -32602)
        now.withLock{$0 = 1100}
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(v05state(first)),id:4))) == -32602)
        let overflow = try await v05make(v05catalog(repeating),protection:v05protection(clock:{Int64.max}))
        #expect(v05code(try await v05response(overflow,v05request("tools/call",fields:#", "name":"round""#))) == -32603)
        let descriptor = InputDescriptor(identifier:ScalarText("form"),request:try v05json(#"{"method":"elicitation/create","params":{"message":"form","requestedSchema":{"type":"object","properties":{}}}}"#))
        let inputOnly = MultiRoundProvider(version:ScalarText("no-state"),inputs:[descriptor],inputOnlyReconstruction:[descriptor.identifier],replay:.integrityOnly) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(inputs:[descriptor.identifier],inputOnly:true)) }
            return .complete(try v05json(v05complete))
        }
        let noState = try await v05make(v05catalog(inputOnly,scopes:[ScalarText("run")]))
        let authorized = VerifiedPrincipal(subject:v05principal.subject,issuer:v05principal.issuer,resource:v05principal.resource,scopes:[ScalarText("run")])
        let initial = try await v05response(noState,v05request("tools/call",fields:#", "name":"round""#),identity:authorized)
        #expect(initial.objectValue?["result"]?.objectValue?["requestState"] == nil)
        for action in ["decline","cancel"] {
            #expect(try await v05response(noState,v05request("tools/call",fields:#", "name":"round", "inputResponses":{"form":{"action":"# + v05quote(action) + "}}",id:2),identity:authorized).objectValue?["result"] != nil)
        }
        await #expect(throws:CoreFailure.insufficientScopes) { _ = try await v05response(noState,v05request("tools/call",fields:#", "name":"round", "inputResponses":{"form":{"action":"cancel"}}"#,id:3)) }
        #expect(v05code(try await v05response(noState,v05request("tools/call",fields:#", "name":"round""#,id:4,caps:"{}"),identity:authorized)) == -32021)
        await v05clean(server); await v05clean(noState)
    }
}

extension MultiRoundCases {
    @Test func replayClaimsRaceRefreshEffectsAndSafeRelease() async throws {
        let store = try StateConsumptionStore(maximumEntries:4,maximumBytes:4096,maximumKeyBytes:256,now:{1000})
        let entered = Mutex(0), released = Mutex(false), completed = Mutex(0)
        let provider = MultiRoundProvider(version:ScalarText("effect"),inputs:[try v05roots()],replay:.consuming(store)) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(inputs:[ScalarText("roots")])) }
            entered.withLock{$0 += 1}
            while !released.withLock({$0}) { try Task.checkCancellation(); await Task.yield() }
            return .complete(try v05json(v05complete))
        }
        let server = try await v05make(v05catalog(provider),protection:v05protection())
        let first = try await v05response(server,v05request("tools/call",fields:#", "name":"round""#))
        let original = try v05state(first)
        let refresh = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(original),id:2))
        let refreshed = try v05state(refresh)
        var results: [JSON] = []
        try await withThrowingTaskGroup(of:JSON.self) { group in
            for (id,token) in [(3,original),(4,refreshed)] {
                group.addTask {
                    let result = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(token) + #", "inputResponses":{"roots":{"roots":[]}}"#,id:id))
                    completed.withLock{$0 += 1}; return result
                }
            }
            try await v05wait { entered.withLock{$0} == 1 && completed.withLock{$0} == 1 }
            released.withLock{$0 = true}
            for try await result in group { results.append(result) }
        }
        #expect(results.filter{$0.objectValue?["result"] != nil}.count == 1)
        #expect(results.filter{v05code($0) == -32602}.count == 1)
        #expect(entered.withLock{$0} == 1)
        #expect(await store.count == 1)
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote(original) + #", "inputResponses":{"roots":{"roots":[]}}"#,id:5))) == -32602)
        await v05clean(server)

        let mode = Mutex(0), effects = Mutex(0)
        let safe = MultiRoundProvider(version:ScalarText("safe"),replay:.consuming(store)) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(state:.null)) }
            if mode.withLock({$0}) == 0 {
                try await round.effect?.releaseForSafeRetry(); throw CoreFailure.invalidOutput
            }
            effects.withLock{$0 += 1}; throw CoreFailure.invalidOutput
        }
        let failServer = try await v05make(v05catalog(safe),protection:v05protection())
        let pending = try v05state(await v05response(failServer,v05request("tools/call",fields:#", "name":"round""#)))
        let fields = #", "name":"round", "requestState":"# + (try v05quote(pending))
        #expect(try await v05response(failServer,v05request("tools/call",fields:fields,id:2)).objectValue?["error"] != nil)
        mode.withLock{$0 = 1}
        #expect(v05code(try await v05response(failServer,v05request("tools/call",fields:fields,id:3))) == -32603)
        #expect(v05code(try await v05response(failServer,v05request("tools/call",fields:fields,id:4))) == -32602)
        #expect(effects.withLock{$0} == 1)
        await v05clean(failServer)
    }

    @Test func consumptionAccountingCapacityExpiryAndForeignSettlement() async throws {
        let now = Mutex(Int64(1000))
        let store = try StateConsumptionStore(maximumEntries:1,maximumBytes:512,maximumKeyBytes:32,now:{now.withLock{$0}})
        let budget = try RequestBudget(workUnits:1000000)
        let claim = try await store.claim(key:[1],expiresAt:1100,budget:budget)
        await #expect(throws:StateConsumptionStore.Failure.full) { _ = try await store.claim(key:[2],expiresAt:1100,budget:budget) }
        let foreign = try StateConsumptionStore(maximumEntries:1,maximumBytes:512,maximumKeyBytes:32,now:{1000})
        await #expect(throws:StateConsumptionStore.Failure.invalidClaim) { try await foreign.commit(claim,budget:budget) }
        try await store.release(claim,budget:budget)
        await #expect(throws:StateConsumptionStore.Failure.invalidClaim) { try await store.release(claim,budget:budget) }
        let committed = try await store.claim(key:[1],expiresAt:1100,budget:budget)
        try await store.commit(committed,budget:budget)
        await #expect(throws:StateConsumptionStore.Failure.invalidClaim) { try await store.release(committed,budget:budget) }
        now.withLock{$0 = 1100}
        let next = try await store.claim(key:[2],expiresAt:1200,budget:budget)
        #expect(await store.count == 1)
        #expect(await store.retainedBytes <= 512)
        #expect(await budget.snapshot.settledWork > 0)
        try await store.release(next,budget:budget)
        #expect(await store.count == 0)
    }

    @Test func cancellationAfterClaimRetainsEffectProtection() async throws {
        let store = try StateConsumptionStore(maximumEntries:4,maximumBytes:4096,maximumKeyBytes:256,now:{1000})
        let entered = Mutex(false)
        let provider = MultiRoundProvider(version:ScalarText("cancel-effect"),replay:.consuming(store)) { _,round,context in
            if !round.isRetry { return .inputRequired(.init(state:.null)) }
            entered.withLock{$0 = true}
            while true { try context.checkCancellation(); await Task.yield() }
        }
        let server = try await v05make(v05catalog(provider),protection:v05protection())
        let pending = try v05state(await v05response(server,v05request("tools/call",fields:#", "name":"round""#)))
        let fields = #", "name":"round", "requestState":"# + (try v05quote(pending))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                await #expect(throws:CancellationError.self) { _ = try await v05response(server,v05request("tools/call",fields:fields,id:2)) }
            }
            try await v05wait { entered.withLock{$0} }
            try await server.cancel(id:RequestID(.number(JSONNumber(integer:2))),principal:v05principal,origin:ScalarText("origin"))
            try await group.waitForAll()
        }
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:fields,id:3))) == -32602)
        await v05clean(server)
    }
}

@Suite(.serialized) struct EventCases {
    @Test func exactFractionalProgressLoggingLevelsAndOneTerminal() async throws {
        let now = Mutex(Int64(1000))
        let tool = ToolRegistration(definition:try v05json(#"{"name":"progress","inputSchema":{"type":"object"}}"#)) { _,context in
            #expect(try await context.progress(JSONNumber(parsing:"0.25")))
            #expect(try await context.progress(JSONNumber(parsing:"0.5")) == false)
            now.withLock{$0 += 100}
            #expect(try await context.progress(JSONNumber(parsing:"9007199254740993.5"),total:JSONNumber(parsing:"9007199254740994.5")))
            await #expect(throws:CoreFailure.invalidInput) { _ = try await context.progress(JSONNumber(parsing:"9007199254740993.5")) }
            await #expect(throws:CoreFailure.invalidInput) { _ = try await context.progress(JSONNumber(parsing:"-1")) }
            await #expect(throws:CoreFailure.invalidInput) { _ = try await context.progress(JSONNumber(integer:100),total:JSONNumber(integer:1)) }
            #expect(try await context.log(.debug,data:.string("filtered")) == false)
            #expect(try await context.log(.error,data:.string("safe-public-message")))
            return try v05json(v05complete)
        }
        let server = try await v05make(ServerCatalog(tools:[tool]),events:EventPolicy(clock:{now.withLock{$0}},logRedactor:{ _ in .string("redacted") }))
        let recorder = try EventCollector()
        try await recorder.dispatch(v05request("tools/call",fields:#", "name":"progress""#,meta:#", "progressToken":9007199254740993, "io.modelcontextprotocol/logLevel":"warning""#),to:server,principal:v05principal,origin:ScalarText("origin"),mode:.http)
        let frames = try await recorder.snapshot.map { try JSONParser().parseWithReport(Array($0)).result }
        #expect(frames.count == 4)
        #expect(frames[0].objectValue?["method"]?.stringValue == "notifications/progress")
        #expect(try frames[0].objectValue?["params"]?.objectValue?["progressToken"]?.numberValue?.integer(as:Int64.self,limits:.balanced) == 9007199254740993)
        #expect(frames[1].objectValue?["params"]?.objectValue?["progress"]?.numberValue?.originalLexeme == "9007199254740993.5")
        #expect(frames[2].objectValue?["method"]?.stringValue == "notifications/message")
        #expect(frames[2].objectValue?["params"]?.objectValue?["data"]?.stringValue == "redacted")
        #expect(frames.last?.objectValue?["result"] != nil)
        #expect(frames.filter{$0.objectValue?["id"] != nil}.count == 1)
        await v05clean(server)
    }

    @Test func defaultOffMissingTokensInvalidLevelAndLateEvents() async throws {
        let escaped = Mutex<RequestContext?>(nil)
        let tool = ToolRegistration(definition:try v05json(#"{"name":"late","inputSchema":{"type":"object"}}"#)) { _,context in
            escaped.withLock{$0 = context}
            #expect(try await context.log(.emergency,data:.string("disabled")) == false)
            await #expect(throws:CoreFailure.eventsUnavailable) { _ = try await context.progress(JSONNumber(integer:1)) }
            return try v05json(v05complete)
        }
        let server = try await v05make(ServerCatalog(tools:[tool]))
        let recorder = try EventCollector()
        try await recorder.dispatch(v05request("tools/call",fields:#", "name":"late""#,meta:#", "io.modelcontextprotocol/logLevel":"debug""#),to:server,principal:v05principal,origin:ScalarText("origin"),mode:.http)
        #expect(await recorder.snapshot.count == 1)
        let context = try #require(escaped.withLock{$0})
        await #expect(throws:CoreFailure.eventsUnavailable) { _ = try await context.progress(JSONNumber(integer:2)) }
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:#", "name":"late""#,id:2,meta:#", "io.modelcontextprotocol/logLevel":"invented""#))) == -32602)
        #expect(try await v05response(server,v05request("server/discover",id:3)).objectValue?["result"]?.objectValue?["capabilities"]?.objectValue?["logging"] == nil)
        await v05clean(server)
    }

    @Test func acknowledgementFiltersVisibilityCoalescingAndD02Modes() async throws {
        let privateResource = ResourceProvider(definition:try v05json(#"{"name":"private","uri":"fixture://private"}"#),requiredScopes:[ScalarText("private")]) { _,_ in try v05json(#"{"resultType":"complete","contents":[]}"#) }
        let publicResource = ResourceProvider(definition:try v05json(#"{"name":"public","uri":"fixture://public"}"#)) { _,_ in try v05json(#"{"resultType":"complete","contents":[]}"#) }
        let catalog = try ServerCatalog(resources:[privateResource,publicResource])
        for mode in [DeliveryMode.stdio,.http] {
            let server = try await v05make(catalog)
            let recorder = try EventCollector()
            try await withThrowingTaskGroup(of:Void.self) { group in
                group.addTask { try await recorder.dispatch(v05request("subscriptions/listen",fields:#", "notifications":{"toolsListChanged":true,"resourceSubscriptions":["fixture://public","fixture://private"]}"#,id:41),to:server,principal:v05principal,origin:ScalarText("origin"),mode:mode) }
                try await v05wait { await recorder.snapshot.count == 1 }
                let a = await server.activity
                #expect(a.subscriptions == 1 && a.leases == 0)
                // A new generation does not pin old plans to this subscription.
                try await server.replaceCatalog(catalog)
                try await server.publish(.resourceUpdated(ScalarText("fixture://private")),audience:.requiringScopes([]))
                try await server.publish(.resourceUpdated(ScalarText("fixture://public")),audience:.principal(VerifiedPrincipal(subject:ScalarText("other"),issuer:v05principal.issuer,resource:v05principal.resource,scopes:[])))
                #expect(await recorder.snapshot.count == 1)
                try await server.publish(.resourceUpdated(ScalarText("fixture://public")),audience:.principal(v05principal))
                try await v05wait { await recorder.snapshot.count == 2 }
                try await server.publish(.toolsChanged,audience:.requiringScopes([]))
                try await v05wait { await recorder.snapshot.count == 3 }
                await server.closeSubscriptions()
                try await group.waitForAll()
            }
            let frames = try await recorder.snapshot.map { try JSONParser().parseWithReport(Array($0)).result }
            #expect(frames[0].objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
            #expect(frames[0].objectValue?["params"]?.objectValue?["notifications"]?.objectValue?["resourceSubscriptions"]?.arrayValue?.count == 1)
            for frame in frames {
                let meta = frame.objectValue?["params"]?.objectValue?["_meta"] ?? frame.objectValue?["result"]?.objectValue?["_meta"]
                #expect(try meta?.objectValue?[ProtocolMetadata.subscriptionID]?.numberValue?.integer(as:Int.self,limits:.balanced) == 41)
                #expect(frame.objectValue?["method"]?.stringValue != "notifications/message" && frame.objectValue?["method"]?.stringValue != "notifications/progress")
            }
            #expect(frames[frames.count - 2].objectValue?["method"]?.stringValue == "notifications/cancelled")
            #expect(frames.filter { $0.objectValue?["method"]?.stringValue == "notifications/cancelled" }.count == 1)
            #expect(frames.last?.objectValue?["result"]?.objectValue?["resultType"]?.stringValue == "complete")
            await v05clean(server)
        }
    }

    @Test func clientCancellationRevocationAndSubscriptionQuota() async throws {
        let server = try await v05make(ServerCatalog(),events:EventPolicy(subscriptions:1,subscriptionsPerPrincipal:1))
        let recorder = try EventCollector()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                await #expect(throws:CancellationError.self) {
                    try await recorder.dispatch(v05request("subscriptions/listen",fields:#", "notifications":{}"#,id:50),to:server,principal:v05principal,origin:ScalarText("origin"),mode:.stdio)
                }
            }
            try await v05wait { await recorder.snapshot.count == 1 }
            let rejected = try EventCollector()
            try await rejected.dispatch(v05request("subscriptions/listen",fields:#", "notifications":{}"#,id:51),to:server,principal:v05principal,origin:ScalarText("origin"),mode:.http)
            let failure = try JSONParser().parseWithReport(Array(await rejected.snapshot[0])).result
            #expect(v05code(failure) == -32603)
            let other = VerifiedPrincipal(subject:ScalarText("foreign"),issuer:v05principal.issuer,resource:v05principal.resource,scopes:[])
            try await server.cancel(id:RequestID(.number(JSONNumber(integer:50))),principal:other,origin:ScalarText("origin"))
            #expect(await server.activity.subscriptions == 1)
            await server.revokeSubscriptions(for:v05principal)
            try await group.waitForAll()
        }
        #expect(await recorder.snapshot.count == 1)
        await v05clean(server)
    }

    @Test func blockedSinkOverflowAndDisconnectedTerminalCannotRetry() async throws {
        let entered = Mutex(false), release = Mutex(false), attempts = Mutex(0), overflow = Mutex(false)
        let clock = Mutex(Int64(1000))
        let tool = ToolRegistration(definition:try v05json(#"{"name":"overflow","inputSchema":{"type":"object"}}"#)) { _,context in
            _ = try await context.progress(JSONNumber(integer:1))
            try await v05wait { entered.withLock{$0} }
            do {
                for n in 2...10 {
                    clock.withLock{$0 += 100}
                    _ = try await context.progress(JSONNumber(integer:n))
                }
            } catch { overflow.withLock{$0 = true}; throw error }
            return try v05json(v05complete)
        }
        let server = try await v05make(ServerCatalog(tools:[tool]),events:EventPolicy(queuedEvents:2,clock:{clock.withLock{$0}}))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                do {
                    try await server.dispatchEvents(v05request("tools/call",fields:#", "name":"overflow""#,meta:#", "progressToken":"token""#),principal:v05principal,origin:ScalarText("origin"),mode:.http) { _ in
                        attempts.withLock{$0 += 1}; entered.withLock{$0 = true}
                        while !release.withLock({$0}) { try Task.checkCancellation(); await Task.yield() }
                    }
                    Issue.record("overflow should terminate this stream")
                } catch { #expect(error is CoreFailure || error is CancellationError) }
            }
            try await v05wait { entered.withLock{$0} }
            try await v05wait { overflow.withLock{$0} }
            release.withLock{$0 = true}
            try await group.waitForAll()
        }
        #expect(attempts.withLock{$0} <= 2)
        await v05clean(server)
        let normal = try await v05make(ServerCatalog())
        let writes = Mutex(0)
        await #expect(throws:CoreFailure.self) {
            try await normal.dispatchEvents(v05request("tools/list"),principal:v05principal,origin:ScalarText("origin"),mode:.http) { _ in writes.withLock{$0 += 1}; throw CoreFailure.disconnected }
        }
        #expect(writes.withLock{$0} == 1)
        await v05clean(normal)
    }
}

extension MultiRoundCases {
    @Test func outgoingSamplingRulesToolInputsAndTemplateContinuation() async throws {
        let invalidHistories = [
            #"{"messages":[{"role":"assistant","content":{"type":"tool_use","id":"a","name":"f","input":{}}}],"maxTokens":10}"#,
            #"{"messages":[{"role":"user","content":[{"type":"tool_result","toolUseId":"a","content":[]},{"type":"text","text":"mixed"}]}],"maxTokens":10}"#,
            #"{"messages":[{"role":"user","content":{"type":"image","data":"bad!","mimeType":"image/png"}}],"maxTokens":10}"#
        ]
        for raw in invalidHistories {
            let input = InputDescriptor(identifier:ScalarText("s"),request:try v05json(#"{"method":"sampling/createMessage","params":"# + raw + "}"))
            let p = MultiRoundProvider(version:ScalarText("bad"),inputs:[input],replay:.integrityOnly) { _,_,_ in .inputRequired(.init(inputs:[input.identifier])) }
            await #expect(throws:CoreFailure.invalidInput) { _ = try await v05make(v05catalog(p),protection:v05protection()) }
        }
        let sampling = InputDescriptor(identifier:ScalarText("s"),request:try v05json(#"{"method":"sampling/createMessage","params":{"messages":[{"role":"assistant","content":{"type":"tool_use","id":"a","name":"f","input":{}}},{"role":"user","content":{"type":"tool_result","toolUseId":"a","content":[]}}],"maxTokens":10,"toolChoice":{"mode":"required"},"tools":[{"name":"f","inputSchema":{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}}]}}"#))
        let effects = Mutex(0)
        let p = MultiRoundProvider(version:ScalarText("sampling-v1"),inputs:[sampling],replay:.integrityOnly) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(inputs:[sampling.identifier])) }
            effects.withLock{$0 += 1}; return .complete(try v05json(v05complete))
        }
        let server = try await v05make(v05catalog(p),protection:v05protection())
        let token = try v05state(await v05response(server,v05request("tools/call",fields:#", "name":"round""#)))
        let fields = #", "name":"round", "requestState":"# + (try v05quote(token)) + #", "inputResponses":{"s":"#
        for content in [#"{"type":"text","text":"no required tool"}"#,
            #"{"type":"tool_use","id":"x","name":"other","input":{"n":1}}"#,
            #"{"type":"tool_use","id":"x","name":"f","input":{"n":"bad"}}"#,
            #"[{"type":"tool_use","id":"x","name":"f","input":{"n":1}},{"type":"tool_use","id":"x","name":"f","input":{"n":2}}]"#] {
            let response = #"{"role":"assistant","model":"synthetic","content":"# + content + "}}"
            #expect(v05code(try await v05response(server,v05request("tools/call",fields:fields + response,id:2))) == -32602)
        }
        #expect(effects.withLock{$0} == 0)
        #expect(try await v05response(server,v05request("tools/call",fields:fields + #"{"role":"assistant","model":"synthetic","content":{"type":"tool_use","id":"x","name":"f","input":{"n":1}}}}"#,id:3)).objectValue?["result"] != nil)
        let templateRounds = MultiRoundProvider(version:ScalarText("template-v1"),replay:.integrityOnly) { input,round,_ in
            if !round.isRetry { return .inputRequired(.init(state:.null)) }
            if case .value(let uri) = input {
                return .complete(try v05json(#"{"resultType":"complete","contents":[{"uri":"# + v05quote(uri.stringValue!) + #","text":"done"}]}"#))
            }
            throw CoreFailure.invalidInput
        }
        let templates = try ServerCatalog(templates:[.init(definition:v05json(#"{"name":"template","uriTemplate":"fixture://{name}"}"#),matches:{ uri,_ in uri.hasPrefix("fixture://") },rounds:templateRounds)])
        let a = try await v05make(templates,protection:v05protection()), b = try await v05make(templates,protection:v05protection())
        let state = try v05state(await v05response(a,v05request("resources/read",fields:#", "uri":"fixture://dynamic""#)))
        #expect(try await v05response(b,v05request("resources/read",fields:#", "uri":"fixture://dynamic", "requestState":"# + v05quote(state),id:2)).objectValue?["result"] != nil)
        await v05clean(server); await v05clean(a); await v05clean(b)
    }
}
extension EventCases {
    @Test func replaceableEventsCoalesceBehindAcknowledgementAndLateTokenCannotEmit() async throws {
        let entered = Mutex(false), release = Mutex(false)
        let recorder = try EventCollector()
        let server = try await v05make(ServerCatalog(),events:EventPolicy(queuedEvents:2))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                try await server.dispatchEvents(v05request("subscriptions/listen",fields:#", "notifications":{"toolsListChanged":true}"#,id:70),principal:v05principal,origin:ScalarText("origin"),mode:.http) { bytes in
                    if !entered.withLock({$0}) {
                        entered.withLock{$0 = true}
                        while !release.withLock({$0}) { try Task.checkCancellation(); await Task.yield() }
                    }
                    try await recorder.record(bytes)
                }
            }
            try await v05wait { entered.withLock{$0} }
            for _ in 0..<10 { try await server.publish(.toolsChanged,audience:.principal(v05principal)) }
            #expect(await server.activity.subscriptions == 1)
            await server.closeSubscriptions()
            release.withLock{$0 = true}
            try await group.waitForAll()
        }
        let frames = try await recorder.snapshot.map { try v05json(String(decoding:$0,as:UTF8.self)) }
        #expect(frames.count == 3)
        #expect(frames[0].objectValue?["method"]?.stringValue == "notifications/subscriptions/acknowledged")
        #expect(frames[1].objectValue?["method"]?.stringValue == "notifications/tools/list_changed")
        #expect(frames[2].objectValue?["result"] != nil)
        await v05clean(server)
        let escaped = Mutex<RequestContext?>(nil)
        let tool = ToolRegistration(definition:try v05json(#"{"name":"late","inputSchema":{"type":"object"}}"#)) { _,context in
            escaped.withLock{$0 = context}; return try v05json(v05complete)
        }
        let late = try await v05make(ServerCatalog(tools:[tool]))
        let sink = try EventCollector()
        try await sink.dispatch(v05request("tools/call",fields:#", "name":"late""#,meta:#", "progressToken":"active-token""#),to:late,principal:v05principal,origin:ScalarText("origin"),mode:.http)
        let context = try #require(escaped.withLock{$0})
        await #expect(throws:CoreFailure.eventsUnavailable) { _ = try await context.progress(JSONNumber(integer:1)) }
        #expect(await sink.snapshot.count == 1)
        await v05clean(late)
    }
}

extension EventCases {
    @Test func principalGlobalBytesEncodingFailureAndDeadlineRelease() async throws {
        for global in [256,512] {
            let entered = Mutex(false), hold = Mutex(false)
            let provider = ToolRegistration(definition:try v05json(#"{"name":"hold","inputSchema":{"type":"object"}}"#)) { _,context in
                _ = try await context.progress(JSONNumber(integer:1))
                if context.id.value.numberValue?.originalLexeme == "80" {
                    hold.withLock{$0 = true}
                    while true { try context.checkCancellation(); await Task.yield() }
                }
                return try v05json(v05complete)
            }
            let server = try await v05make(ServerCatalog(tools:[provider]),events:EventPolicy(queuedBytes:256,globalBytes:global,principalBytes:256,notificationBytes:256))
            try await withThrowingTaskGroup(of:Void.self) { group in
                group.addTask {
                    do {
                        try await server.dispatchEvents(v05request("tools/call",fields:#", "name":"hold""#,id:80,meta:#", "progressToken":"p""#),principal:v05principal,origin:ScalarText("origin"),mode:.http) { _ in
                            entered.withLock{$0 = true}
                            while true { try Task.checkCancellation(); await Task.yield() }
                        }
                        Issue.record("cancelled held stream unexpectedly succeeded")
                    } catch { #expect(error is CoreFailure || error is CancellationError) }
                }
                try await v05wait { entered.withLock{$0} && hold.withLock{$0} }
                let same = try EventCollector()
                do {
                    try await same.dispatch(v05request("tools/call",fields:#", "name":"hold""#,id:81,meta:#", "progressToken":"p""#),to:server,principal:v05principal,origin:ScalarText("origin"),mode:.http)
                    Issue.record("per-principal byte reservation should fail")
                } catch { #expect(error is CoreFailure) }
                let foreign = VerifiedPrincipal(subject:ScalarText("other"),issuer:v05principal.issuer,resource:v05principal.resource,scopes:[])
                let other = try EventCollector()
                if global == 256 {
                    do {
                        try await other.dispatch(v05request("tools/call",fields:#", "name":"hold""#,id:82,meta:#", "progressToken":"p""#),to:server,principal:foreign,origin:ScalarText("origin"),mode:.http)
                        Issue.record("global byte reservation should fail")
                    } catch { #expect(error is CoreFailure) }
                } else {
                    try await other.dispatch(v05request("tools/call",fields:#", "name":"hold""#,id:82,meta:#", "progressToken":"p""#),to:server,principal:foreign,origin:ScalarText("origin"),mode:.http)
                    #expect(await other.snapshot.count == 2)
                }
                #expect(await server.activity.eventBytes <= global)
                try await server.cancel(id:RequestID(.number(JSONNumber(integer:80))),principal:v05principal,origin:ScalarText("origin"))
                try await group.waitForAll()
            }
            await v05clean(server)
        }
        let large = ToolRegistration(definition:try v05json(#"{"name":"large","inputSchema":{"type":"object"}}"#)) { _,context in
            _ = try await context.progress(JSONNumber(integer:1),message:String(repeating:"x",count:1000))
            return try v05json(v05complete)
        }
        let bounded = try await v05make(ServerCatalog(tools:[large]),events:EventPolicy(queuedBytes:256,globalBytes:512,principalBytes:256,notificationBytes:256))
        let writes = Mutex(0)
        do {
            try await bounded.dispatchEvents(v05request("tools/call",fields:#", "name":"large""#,meta:#", "progressToken":"p""#),principal:v05principal,origin:ScalarText("origin"),mode:.http) { _ in writes.withLock{$0 += 1} }
            Issue.record("oversized event encoding should fail")
        } catch { #expect(error is CoreFailure || error is JSONFailure) }
        #expect(writes.withLock{$0} <= 1)
        await v05clean(bounded)
        let expires = try await v05make(ServerCatalog(),configuration:ServerConfiguration(deadlineMilliseconds:10))
        let sink = try EventCollector()
        await #expect(throws:CoreFailure.deadline) {
            try await sink.dispatch(v05request("subscriptions/listen",fields:#", "notifications":{}"#),to:expires,principal:v05principal,origin:ScalarText("origin"),mode:.http)
        }
        #expect(await sink.snapshot.count <= 1)
        await v05clean(expires)
    }
}

private struct V05FailingRelease: ContinuationConsumption {
    let store: StateConsumptionStore
    var maximumSettlementWork: UInt64 { store.maximumSettlementWork }
    func claim(key: [UInt8], expiresAt: Int64, budget: RequestBudget) async throws -> ConsumptionClaim {
        try await store.claim(key:key,expiresAt:expiresAt,budget:budget)
    }
    func commit(_ claim: ConsumptionClaim, budget: RequestBudget) async throws { try await store.commit(claim,budget:budget) }
    func release(_ claim: ConsumptionClaim, budget: RequestBudget) async throws {
        try await budget.consume(1); throw CoreFailure.disconnected
    }
}
extension MultiRoundCases {
    @Test func caughtSettlementFailureNeverReturnsSuccess() async throws {
        let store = try StateConsumptionStore(maximumEntries:2,maximumBytes:1024,maximumKeyBytes:64,now:{1000})
        let rounds = MultiRoundProvider(version:ScalarText("failed-release"),replay:.consuming(V05FailingRelease(store:store))) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(state:.null)) }
            do { try await round.effect?.releaseForSafeRetry() } catch {}
            return .complete(try v05json(v05complete))
        }
        let server = try await v05make(v05catalog(rounds),protection:v05protection())
        let token = try v05state(await v05response(server,v05request("tools/call",fields:#", "name":"round""#)))
        let fields = #", "name":"round", "requestState":"# + (try v05quote(token))
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:fields,id:2))) == -32603)
        #expect(await store.count == 1)
        #expect(v05code(try await v05response(server,v05request("tools/call",fields:fields,id:3))) == -32602)
        await v05clean(server)
    }
}

extension NotificationSilence {
    @Test func notificationSaturationAndCompletedForeignCancellationStaySilent() async throws {
        let entered = Mutex(false), providerCalls = Mutex(0), writes = Mutex(0)
        let tool = ToolRegistration(definition:try v05json(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,context in
            entered.withLock{$0 = true}; providerCalls.withLock{$0 += 1}
            while true { try context.checkCancellation(); await Task.yield() }
        }
        let server = try await v05make(ServerCatalog(tools:[tool]),configuration:ServerConfiguration(activeRequests:1,queuedRequests:1,requestsPerPrincipal:1))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                await #expect(throws:CancellationError.self) {
                    try await server.dispatch(v05request("tools/call",fields:#", "name":"wait""#,id:101),principal:v05principal,origin:ScalarText("origin")) { _ in writes.withLock{$0 += 1} }
                }
            }
            try await v05wait { entered.withLock{$0} }
            group.addTask {
                await #expect(throws:CancellationError.self) {
                    try await server.dispatch(v05request("tools/list",id:102),principal:v05principal,origin:ScalarText("origin")) { _ in writes.withLock{$0 += 1} }
                }
            }
            try await v05wait { await server.activity.queued == 1 }
            for raw in [#"{"jsonrpc":"2.0","method":"unknown"}"#,#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#] {
                await #expect(throws:AdmissionController.Failure.saturated) {
                    try await server.dispatch(Data(raw.utf8),principal:v05principal,origin:ScalarText("origin")) { _ in writes.withLock{$0 += 1} }
                }
            }
            let foreign = VerifiedPrincipal(subject:ScalarText("foreign"),issuer:v05principal.issuer,resource:v05principal.resource,scopes:[])
            try await server.cancel(id:RequestID(.number(JSONNumber(integer:101))),principal:foreign,origin:ScalarText("origin"))
            try await server.cancel(id:RequestID(.number(JSONNumber(integer:999))),principal:v05principal,origin:ScalarText("origin"))
            #expect(await server.activity.requests == 1)
            try await server.cancel(id:RequestID(.number(JSONNumber(integer:101))),principal:v05principal,origin:ScalarText("origin"))
            group.cancelAll(); try await group.waitForAll()
        }
        try await server.dispatch(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":101}}"#.utf8),principal:v05principal,origin:ScalarText("origin")) { _ in writes.withLock{$0 += 1} }
        #expect(writes.withLock{$0} == 0)
        #expect(providerCalls.withLock{$0} == 1)
        await v05clean(server)
    }
}
extension MultiRoundCases {
    @Test func authenticatedMalformedClaimsRejectBeforeProviderAndOperationalSettlementCode() async throws {
        let resumed = Mutex(0)
        let p = MultiRoundProvider(version:ScalarText("claims"),replay:.integrityOnly) { _,round,_ in
            if !round.isRetry { return .inputRequired(.init(state:.null)) }
            resumed.withLock{$0 += 1}; return .complete(try v05json(v05complete))
        }
        let server = try await v05make(v05catalog(p),protection:v05protection())
        let token = try v05state(await v05response(server,v05request("tools/call",fields:#", "name":"round""#)))
        let encoded = String(token.split(separator:".").last!)
        let base64 = encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/") + String(repeating:"=",count:(4-encoded.utf8.count%4)%4)
        let material = SymmetricKey(data:Data(repeating:9,count:32))
        // Independent synthetic-key claim fixture. No SDK private token API.
        let aad = Data("Swift-MCP/continuation\0version=1\0binding=1\0state".utf8)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined:try #require(Data(base64Encoded:base64))),using:material,authenticating:aad)
        let claims = try #require(JSONParser().parseWithReport(Array(plain)).result.objectValue)
        var payloads = [Data("{}".utf8),Data("{bad".utf8)]
        for (field,value) in [
            ("version",2),("bindingVersion",2),("issued",-1),("expires",Int64.max),
            ("attempts",0),("maximumAttempts",65),("logicalRound",999),("statePresence",3)
        ] {
            let raw = try claims.setting(.number(JSONNumber(integer:value)),for:JSONKey(field))
            payloads.append(try JSONWriter().writeWithReport(.object(raw)).result)
        }
        for (index,payload) in payloads.enumerated() {
            let box = try AES.GCM.seal(payload,using:material,authenticating:aad)
            let encoded = try #require(box.combined).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            let rejected = try await v05response(server,v05request("tools/call",fields:#", "name":"round", "requestState":"# + v05quote("c1.state." + encoded),id:2))
            #expect(v05code(rejected) == -32602, "authenticated malformed claim fixture index: \(index)")
        }
        #expect(resumed.withLock{$0} == 0)
        await v05clean(server)
        let empty = try await v05make(ServerCatalog())
        await #expect(throws:CoreFailure.limit) { try await empty.publish(.resourceUpdated(ScalarText(String(repeating:"x",count:4097))),audience:.requiringScopes([])) }
        await v05clean(empty)
    }
}

extension NotificationSilence {
    @Test func parsedNotificationCannotBecomeResponseOnRecoveryExhaustion() async throws {
        let bytes = Data((#"{"jsonrpc":"2.0","method":"unsupported","params":{"text":""# + String(repeating:"x",count:2000) + #""}}"#).utf8)
        let report = try JSONParser().parseWithReport(Array(bytes))
        // Exact native parser cost plus the existing finite admission/copy,
        // terminal and observer debits; leave less than the recovery byte debit.
        let work = UInt64(bytes.count) * 4 + 108 + 4096 + 12002 + report.statistics[.workUnits] + UInt64(bytes.count / 2)
        let server = try await v05make(ServerCatalog(),configuration:ServerConfiguration(requestWork:work,terminalWork:4096))
        let writes = Mutex(0)
        do {
            try await server.dispatch(bytes,principal:v05principal,origin:ScalarText("origin")) { _ in writes.withLock{$0 += 1} }
        } catch { #expect(error is RequestBudget.Failure || error is CancellationError) }
        #expect(writes.withLock{$0} == 0)
        await v05clean(server)
    }
}
