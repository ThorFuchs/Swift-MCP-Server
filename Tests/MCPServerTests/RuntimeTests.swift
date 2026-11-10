// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private func json(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private func principal(_ name: String = "alice", scopes: Set<ScalarText> = []) -> VerifiedPrincipal {
    .init(subject: ScalarText(name), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: scopes)
}
private func protector(epoch: String = "runtime", clock: @escaping @Sendable () -> Int64 = { 1000 }) throws -> CursorProtector {
    try .init(keys: [.init(identifier: ScalarText("key"), material: Data(repeating: 7, count: 32))], active: ScalarText("key"), epoch: ScalarText(epoch), clock: clock)
}
private func request(_ method: String, fields: String = "", id: String = "9007199254740993", caps: String = "{}", version: String = "2026-07-28") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"\(version)\",\"io.modelcontextprotocol/clientCapabilities\":\(caps)}\(fields)}}".utf8)
}
private func make(_ catalog: ServerCatalog, configuration: ServerConfiguration? = nil) async throws -> Server {
    try await Server.make(info: json(#"{"name":"native","version":"0.1"}"#), catalog: catalog, cursors: protector(), configuration: configuration)
}
private func response(_ server: Server, _ bytes: Data, identity: VerifiedPrincipal = principal()) async throws -> JSON {
    let data = try #require(await server.handle(bytes, principal: identity, origin: ScalarText("origin")))
    return try JSONParser().parseWithReport(Array(data)).result
}
private func code(_ value: JSON) -> Int64? {
    try? value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int64.self, limits: .balanced)
}
private func clean(_ server: Server) async {
    let state = await server.activity
    #expect(state.active == 0 && state.queued == 0 && state.requests == 0 && state.leases == 0 && state.bufferedBytes == 0)
}
private func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) { guard ContinuousClock.now < until else { throw CoreFailure.deadline }; await Task.yield() }
}
private final class Latch: Sendable {
    let entered = Mutex(0), released = Mutex(false)
    func block() async throws { entered.withLock { $0 += 1 }; while !released.withLock({ $0 }) { try Task.checkCancellation(); await Task.yield() } }
}
private let toolResult = #"{"resultType":"complete","content":[{"type":"text","text":"ok"}]}"#

@Suite(.serialized) struct RuntimeCases {
    @Test func typedRawAndAllContentForms() async throws {
        struct Arguments: Decodable, Sendable { let count: Int }
        struct Output: Encodable, Sendable { let count: Int }
        let typed = ToolRegistration.typed(definition: try json(#"{"name":"typed","inputSchema":{"type":"object","required":["count"],"properties":{"count":{"type":"integer"}}},"outputSchema":{"type":"object","required":["count"],"properties":{"count":{"type":"integer"}}}}"#), input: Arguments.self) { input, context in
            #expect(context.principal.subject == ScalarText("alice"))
            #expect(context.protocolVersion == ScalarText("2026-07-28"))
            #expect(context.capabilities.count == 0 && context.extensions.count == 0)
            return Output(count: input.count + 1)
        }
        let raw = ToolRegistration(definition: try json(#"{"name":"raw","inputSchema":{"type":"object"}}"#)) { _, _ in
            try json(#"{"resultType":"complete","isError":true,"structuredContent":{"blob":"application-data"},"content":[{"type":"text","text":"failed"},{"type":"image","data":"YQ==","mimeType":"image/png"},{"type":"audio","data":"Yg==","mimeType":"audio/wav"},{"type":"resource_link","name":"link","uri":"fixture://x"},{"type":"resource","resource":{"uri":"fixture://x","blob":"Yw=="}},{"type":"resource","resource":{"uri":"fixture://x","text":"embedded"}}]}"#)
        }
        let server = try await make(ServerCatalog(tools: [typed, raw]))
        let typedResponse = try await response(server, request("tools/call", fields: #", "name":"typed", "arguments":{"count":4}"#))
        #expect(try typedResponse.objectValue?["id"]?.numberValue?.integer(as: Int64.self, limits: .balanced) == 9_007_199_254_740_993)
        #expect(try typedResponse.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["count"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 5)
        let result = try #require(await response(server, request("tools/call", fields: #", "name":"raw""#)).objectValue?["result"])
        #expect(result.objectValue?["isError"]?.booleanValue == true)
        #expect(result.objectValue?["content"]?.arrayValue?.count == 6)
        #expect(result.objectValue?["_meta"]?.objectValue?[ProtocolMetadata.serverInfo]?.objectValue?["name"]?.stringValue == "native")
        await clean(server)
    }

    @Test func invalidInputsOutputAndOperationalCatchCannotSucceed() async throws {
        let calls = Mutex(0)
        let definition = try json(#"{"name":"checked","inputSchema":{"type":"object","required":["nested"],"properties":{"nested":{"type":"object","required":["x"],"properties":{"x":{"type":"integer","x-mcp-header":"X"}}}}},"outputSchema":{"type":"integer"}}"#)
        let checked = ToolRegistration(definition: definition) { _, _ in calls.withLock { $0 += 1 }; return try json(#"{"resultType":"complete","content":[],"structuredContent":"wrong"}"#) }
        let poisoned = ToolRegistration(definition: try json(#"{"name":"poisoned","inputSchema":{"type":"object"}}"#)) { _, context in
            do { try await context.budget.consume(UInt64.max) } catch { }
            return try json(toolResult)
        }
        let unsettled = ToolRegistration(definition: try json(#"{"name":"unsettled","inputSchema":{"type":"object"}}"#)) { _, context in
            _ = try await context.budget.reserve(10); return try json(toolResult)
        }
        let server = try await make(ServerCatalog(tools: [checked, poisoned, unsettled]))
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"checked", "arguments":{"nested":{"x":null}}"#))) == -32602)
        #expect(calls.withLock { $0 } == 0)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"checked", "arguments":{"nested":{"x":1}}"#))) == -32603)
        #expect(calls.withLock { $0 } == 1)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"poisoned""#))) == -32603)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"unsettled""#))) == -32603)
        await clean(server)
    }

    @Test func authoritativeScopesCapabilitiesAndExtensionsArePerRequest() async throws {
        let seen = Mutex(0)
        let tool = ToolRegistration(definition: try json(#"{"name":"secured","inputSchema":{"type":"object"}}"#), requiredScopes: [ScalarText("run")], requiredFeatures: [.roots]) { _, context in
            seen.withLock { $0 += 1 }
            #expect(context.extensions["com.example/checked"]?.objectValue?["enabled"]?.booleanValue == true)
            return try json(toolResult)
        }
        let ext = ExtensionRegistration(identifier: ScalarText("com.example/checked"), settingsSchema: try json(#"{"type":"object","required":["enabled"],"properties":{"enabled":{"const":true}}}"#))
        let server = try await make(ServerCatalog(tools: [tool], extensions: [ext]))
        await #expect(throws: CoreFailure.insufficientScopes) { _ = try await response(server, request("tools/call", fields: #", "name":"secured""#)) }
        let identity = principal(scopes: [ScalarText("run")])
        let missing = try await response(server, request("tools/call", fields: #", "name":"secured""#), identity: identity)
        #expect(code(missing) == -32021)
        #expect(missing.objectValue?["error"]?.objectValue?["data"]?.objectValue?["requiredCapabilities"]?.objectValue?["roots"]?.objectValue != nil)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"secured""#, caps: #"{"roots":{},"extensions":{"com.example/checked":{"enabled":false}}}"#), identity: identity)) == -32602)
        let accepted = try await response(server, request("tools/call", fields: #", "name":"secured""#, caps: #"{"roots":{},"extensions":{"com.example/checked":{"enabled":true},"com.example/unknown":{}}}"#), identity: identity)
        #expect(accepted.objectValue?["result"] != nil && seen.withLock { $0 } == 1)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"secured""#), identity: identity)) == -32021)
        #expect(try await response(server, request("tools/list")).objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.isEmpty == true)
        await clean(server)
    }

    @Test func errorsRemainAtTheirOwnLayersAndD01Null() async throws {
        let host = ToolRegistration(definition: try json(#"{"name":"host","inputSchema":{"type":"object"}}"#)) { _, _ in throw CoreFailure.invalidOutput }
        let server = try await make(ServerCatalog(tools: [host]))
        let malformed = try await response(server, Data("{bad".utf8))
        #expect(code(malformed) == -32700 && malformed.objectValue?["id"]?.isNull == true)
        #expect(code(try await response(server, Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list","params":{}}"#.utf8))) == -32600)
        #expect(code(try await response(server, request("unknown"))) == -32601)
        #expect(code(try await response(server, request("initialize"))) == -32601)
        #expect(code(try await response(server, request("subscriptions/listen"))) == -32601)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"absent""#))) == -32602)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"host""#))) == -32603)
        let version = try await response(server, request("tools/list", version: "legacy"))
        #expect(code(version) == -32022)
        #expect(version.objectValue?["error"]?.objectValue?["data"]?.objectValue?["requested"]?.stringValue == "legacy")
        await clean(server)
    }

    @Test func resourcesPromptsCompletionAndSixCacheHints() async throws {
        let resource = ResourceProvider(definition: try json(#"{"name":"r","uri":"fixture://r"}"#)) { _, _ in try json(#"{"resultType":"complete","contents":[{"uri":"fixture://r","text":"text"},{"uri":"fixture://r","blob":"YQ=="}]}"#) }
        let template = ResourceTemplateProvider(definition: try json(#"{"name":"t","uriTemplate":"fixture://t/{id}"}"#), matches: { uri, _ in uri.hasPrefix("fixture://t/") }) { _, _ in try json(#"{"resultType":"complete","contents":[{"uri":"fixture://t/x","text":"template"}]}"#) }
        let prompt = PromptProvider(definition: try json(#"{"name":"p","arguments":[{"name":"name","required":true}]}"#)) { _, _ in try json(#"{"resultType":"complete","messages":[{"role":"user","content":{"type":"text","text":"hello"}},{"role":"assistant","content":{"type":"image","data":"YQ==","mimeType":"image/png"}}]}"#) }
        let completion = CompletionProvider { _, _ in try .init(values: (0..<101).map(String.init), total: 150) }
        let server = try await make(ServerCatalog(resources: [resource], templates: [template], prompts: [prompt], completion: completion))
        for method in ["server/discover", "tools/list", "resources/list", "resources/templates/list", "prompts/list", "resources/read"] {
            let fields = method == "resources/read" ? #", "uri":"fixture://r""# : ""
            let result = try #require(await response(server, request(method, fields: fields)).objectValue?["result"]?.objectValue)
            #expect(result["cacheScope"]?.stringValue == "private")
            #expect(try result["ttlMs"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 0)
        }
        #expect(try await response(server, request("resources/read", fields: #", "uri":"fixture://t/x""#)).objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.count == 1)
        #expect(code(try await response(server, request("prompts/get", fields: #", "name":"p""#))) == -32602)
        #expect(try await response(server, request("prompts/get", fields: #", "name":"p", "arguments":{"name":"Ada"}"#)).objectValue?["result"]?.objectValue?["messages"]?.arrayValue?.count == 2)
        let complete = try #require(await response(server, request("completion/complete", fields: #", "ref":{"type":"ref/prompt","name":"p"}, "argument":{"name":"name","value":"A"}"#)).objectValue?["result"]?.objectValue?["completion"]?.objectValue)
        #expect(complete["values"]?.arrayValue?.count == 100 && complete["hasMore"]?.booleanValue == true)
        #expect(try complete["total"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 150)
        try await server.replaceCatalog(ServerCatalog(resources: [resource], cache: CacheHints(ttlMilliseconds: 42, scope: .public)))
        #expect(try await response(server, request("resources/list")).objectValue?["result"]?.objectValue?["cacheScope"]?.stringValue == "public")
        await clean(server)
    }

    @Test func binaryErrorsNeverBecomeSuccessfulResponses() async throws {
        let bad = ToolRegistration(definition: try json(#"{"name":"binary","inputSchema":{"type":"object"}}"#)) { _, _ in try json(#"{"resultType":"complete","content":[{"type":"image","data":"YQ==\n","mimeType":"image/png"}]}"#) }
        let server = try await make(ServerCatalog(tools: [bad]))
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"binary""#))) == -32603)
        await clean(server)
    }

    @Test func coherentGenerationAcrossProviderSuspension() async throws {
        let latch = Latch()
        let old = ToolRegistration(definition: try json(#"{"name":"generation","inputSchema":{"type":"object"},"outputSchema":{"const":"old"}}"#)) { _, context in
            #expect(context.generation == 1); try await latch.block()
            return try json(#"{"resultType":"complete","content":[],"structuredContent":"old"}"#)
        }
        let next = ToolRegistration(definition: try json(#"{"name":"generation","inputSchema":{"type":"object"},"outputSchema":{"const":"new"}}"#)) { _, context in
            #expect(context.generation == 2); return try json(#"{"resultType":"complete","content":[],"structuredContent":"new"}"#)
        }
        let server = try await make(ServerCatalog(tools: [old]))
        let child = Task { try await response(server, request("tools/call", fields: #", "name":"generation""#, id: "1")) }
        try await wait { latch.entered.withLock { $0 } == 1 }
        try await server.replaceCatalog(ServerCatalog(tools: [next]))
        #expect(try await response(server, request("tools/call", fields: #", "name":"generation""#, id: "2")).objectValue?["result"]?.objectValue?["structuredContent"]?.stringValue == "new")
        latch.released.withLock { $0 = true }
        #expect(try await child.value.objectValue?["result"]?.objectValue?["structuredContent"]?.stringValue == "old")
        await clean(server)
    }

    @Test func catalogPaginationEmptyAndStaleCursorsAndScalarNames() async throws {
        let names = ["é", "e\u{301}", "z"]
        let tools = try names.map { name in ToolRegistration(definition: try json("{\"name\":\"\(name)\",\"inputSchema\":{\"type\":\"object\"}}")) { _, _ in try json(toolResult) } }
        let config = try ServerConfiguration(pageEntries: 1)
        let server = try await make(ServerCatalog(tools: tools), configuration: config)
        let first = try #require(await response(server, request("tools/list")).objectValue?["result"]?.objectValue)
        let token = try #require(first["nextCursor"]?.stringValue)
        #expect(first["tools"]?.arrayValue?.count == 1)
        #expect(code(try await response(server, request("tools/list", fields: #", "cursor":"""#))) == -32602)
        let second = try await response(server, request("tools/list", fields: ",\"cursor\":\"\(token)\""))
        #expect(second.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == 1)
        let lastToken = try #require(second.objectValue?["result"]?.objectValue?["nextCursor"]?.stringValue)
        let last = try #require(await response(server, request("tools/list", fields: ",\"cursor\":\"\(lastToken)\"" )).objectValue?["result"]?.objectValue)
        #expect(last["nextCursor"] == nil && last["tools"]?.arrayValue?.count == 1 && last["cacheScope"]?.stringValue == "private")
        #expect(code(try await response(server, request("tools/list", fields: ",\"cursor\":\"\(token)\""), identity: principal("bob"))) == -32602)
        #expect(try await response(server, request("tools/call", fields: #", "name":"é""#)).objectValue?["result"] != nil)
        #expect(try await response(server, request("tools/call", fields: ",\"name\":\"e\u{301}\"" )).objectValue?["result"] != nil)
        await #expect(throws: CoreFailure.duplicate) { try await server.replaceCatalog(ServerCatalog(tools: [tools[0], tools[0]])) }
        #expect(await server.activity.generation == 1)
        try await server.replaceCatalog(ServerCatalog(tools: tools))
        #expect(code(try await response(server, request("tools/list", fields: ",\"cursor\":\"\(token)\""))) == -32602)
        await clean(server)
    }

    @Test func ownedCancellationSeparatesPrincipalOriginAndExactID() async throws {
        let latch = Latch()
        let tool = ToolRegistration(definition: try json(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _, _ in try await latch.block(); return try json(toolResult) }
        let server = try await make(ServerCatalog(tools: [tool]))
        let child = Task { try await response(server, request("tools/call", fields: #", "name":"wait""#, id: "1e2")) }
        try await wait { latch.entered.withLock { $0 } == 1 }
        try await server.cancel(id: RequestID(json("100")), principal: principal("bob"), origin: ScalarText("origin"))
        try await server.cancel(id: RequestID(json("100")), principal: principal(), origin: ScalarText("other"))
        #expect(await server.activity.requests == 1)
        #expect(code(try await response(server, request("tools/call", fields: #", "name":"wait""#, id: "100"))) == -32600)
        try await server.cancel(id: RequestID(json("100")), principal: principal(), origin: ScalarText("origin"))
        await #expect(throws: CancellationError.self) { _ = try await child.value }
        await clean(server)
    }

    @Test func runtimeSaturationQueuedCancellationAndSinkAttempt() async throws {
        let latch = Latch(), writes = Mutex(0)
        let tool = ToolRegistration(definition: try json(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _, _ in try await latch.block(); return try json(toolResult) }
        let config = try ServerConfiguration(activeRequests: 1, queuedRequests: 1, requestsPerPrincipal: 1)
        let server = try await make(ServerCatalog(tools: [tool]), configuration: config)
        let first = Task { try await response(server, request("tools/call", fields: #", "name":"wait""#, id: "1")) }
        try await wait { latch.entered.withLock { $0 } == 1 }
        let queued = Task { try await response(server, request("tools/list", id: "2")) }
        try await wait { await server.activity.queued == 1 }
        await #expect(throws: AdmissionController.Failure.saturated) { _ = try await response(server, request("tools/list", id: "3")) }
        queued.cancel(); await #expect(throws: CancellationError.self) { _ = try await queued.value }
        first.cancel(); await #expect(throws: CancellationError.self) { _ = try await first.value }
        await clean(server)
        await #expect(throws: CoreFailure.disconnected) {
            try await server.dispatch(request("tools/list"), principal: principal(), origin: ScalarText("origin")) { _ in writes.withLock { $0 += 1 }; throw CoreFailure.disconnected }
        }
        #expect(writes.withLock { $0 } == 1)
        await clean(server)
    }

    @Test func completionZeroHundredAndClippedTotals() async throws {
        let server = try await make(ServerCatalog(completion: CompletionProvider { _, _ in try .init(values: []) }))
        for count in [0, 100, 101] {
            try await server.replaceCatalog(ServerCatalog(completion: CompletionProvider { _, _ in try .init(values: (0..<count).map(String.init)) }))
            let completion = try #require(await response(server, request("completion/complete", fields: #", "ref":{"type":"ref/prompt","name":"p"}, "argument":{"name":"x","value":""}"#)).objectValue?["result"]?.objectValue?["completion"]?.objectValue)
            #expect(completion["values"]?.arrayValue?.count == min(count, 100))
            #expect(completion["hasMore"]?.booleanValue == (count > 100))
            #expect(try completion["total"]?.numberValue?.integer(as: Int.self, limits: .balanced) == count)
        }
        #expect(throws: CoreFailure.invalidOutput) { try CompletionPage(values: ["x"], total: 0) }
        #expect(throws: CoreFailure.invalidOutput) { try CompletionPage(values: ["x"], total: 1, hasMore: true) }
        await clean(server)
    }

    @Test func finiteTerminalReserveAndEscapedContextNeverReopen() async throws {
        let account = Mutex<RequestBudget?>(nil)
        let tool = ToolRegistration(definition: try json(#"{"name":"account","inputSchema":{"type":"object"}}"#)) { _, context in account.withLock { $0 = context.budget }; return try json(toolResult) }
        let server = try await make(ServerCatalog(tools: [tool]))
        _ = try await response(server, request("tools/call", fields: #", "name":"account""#))
        let escaped = try #require(account.withLock { $0 })
        await #expect(throws: RequestBudget.Failure.exhausted) { try await escaped.consume(0) }
        let small = try await make(ServerCatalog(), configuration: ServerConfiguration(requestWork: 270_000))
        let error = try await response(small, request("tools/list"))
        #expect(code(error) == -32603 && error.objectValue?["result"] == nil)
        await clean(small); await clean(server)
    }

    @Test func runtimeStopRejectsQueueAndFutureWithoutCancellingHostTask() async throws {
        let latch = Latch()
        let tool = ToolRegistration(definition: try json(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _, _ in try await latch.block(); return try json(toolResult) }
        let server = try await make(ServerCatalog(tools: [tool]), configuration: ServerConfiguration(activeRequests: 1, queuedRequests: 1, requestsPerPrincipal: 1))
        let active = Task { try await response(server, request("tools/call", fields: #", "name":"wait""#, id: "1")) }
        try await wait { latch.entered.withLock { $0 } == 1 }
        let queued = Task { try await response(server, request("tools/list", id: "2")) }
        try await wait { await server.activity.queued == 1 }
        await server.stopAdmission()
        await #expect(throws: AdmissionController.Failure.stopped) { _ = try await queued.value }
        await #expect(throws: AdmissionController.Failure.stopped) { _ = try await response(server, request("tools/list", id: "3")) }
        #expect(await server.activity.active == 1)
        latch.released.withLock { $0 = true }; _ = try await active.value
        await clean(server)
    }

    @Test func terminalSerializationExhaustionAttemptsNoWrite() async throws {
        let writes = Mutex(0)
        let tool = ToolRegistration(definition: try json(#"{"name":"large","inputSchema":{"type":"object"}}"#)) { _, _ in
            try json("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"" + String(repeating: "x", count: 10000) + "\"}]}")
        }
        let server = try await make(ServerCatalog(tools: [tool]), configuration: ServerConfiguration(terminalWork: 4096))
        await #expect(throws: CoreFailure.limit) {
            try await server.dispatch(request("tools/call", fields: #", "name":"large""#), principal: principal(), origin: ScalarText("origin")) { _ in writes.withLock { $0 += 1 } }
        }
        #expect(writes.withLock { $0 } == 0)
        await clean(server)
    }

    @Test func providerCompletionCancellationAndSinkFailureRaceOwnCleanup() async throws {
        let writes = Mutex<[String: Int]>([:])
        let tool = ToolRegistration(definition: try json(#"{"name":"race","inputSchema":{"type":"object"}}"#)) { _, context in
            try await Task.sleep(for: .milliseconds(10)); try context.checkCancellation(); return try json(toolResult)
        }
        let server = try await make(ServerCatalog(tools: [tool]), configuration: ServerConfiguration(bufferedBytes: 67_108_864))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let name = String(index), identity = principal(name)
                    let cancellation = Task {
                        do { try await Task.sleep(for: .milliseconds(10)); try await server.cancel(id: RequestID(json(name)), principal: identity, origin: ScalarText("origin")) }
                        catch let failure as AdmissionController.Failure { #expect(failure == .saturated) }
                        catch { Issue.record("Unexpected control error \(error)") }
                    }
                    do {
                        try await server.dispatch(request("tools/call", fields: #", "name":"race""#, id: name), principal: identity, origin: ScalarText("origin")) { _ in
                            writes.withLock { $0[name, default: 0] += 1 }; throw CoreFailure.disconnected
                        }
                        Issue.record("Throwing sink cannot complete successfully")
                    } catch is CancellationError { }
                    catch let failure as CoreFailure { #expect(failure == .disconnected) }
                    catch { Issue.record("Unexpected pipeline error \(error)") }
                    await cancellation.value
                }
            }
        }
        #expect(writes.withLock { $0.values.allSatisfy { $0 == 1 } })
        await clean(server)
    }

    @Test func deadlineJoinsUncooperativeCallbackAndBoundsRetainedWork() async throws {
        let entered = Mutex(false), release = Mutex(false), ended = Mutex(false), sends = Mutex(0)
        let tool = ToolRegistration(definition: try json(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _, _ in
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) { await Task.yield() } // deliberately ignores cancellation
            return try json(toolResult)
        }
        let config = try ServerConfiguration(deadlineMilliseconds: 100)
        let server = try await make(ServerCatalog(tools: [tool]), configuration: config)
        let child = Task {
            defer { ended.withLock { $0 = true } }
            try await server.dispatch(request("tools/call", fields: #", "name":"wait""#), principal: principal(), origin: ScalarText("origin")) { _ in sends.withLock { $0 += 1 } }
        }
        try await wait { entered.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(150))
        let active = await server.activity.active
        #expect(!ended.withLock { $0 } && active == 1)
        release.withLock { $0 = true }
        await #expect(throws: CoreFailure.deadline) { try await child.value }
        #expect(sends.withLock { $0 } == 0)
        await clean(server)
        await #expect(throws: CoreFailure.limit) { _ = try await response(server, Data(repeating: 32, count: config.messageBytes + 1)) }
        await clean(server)
    }
}

@Test func cursorPurposeBindingRotationExpiryAndTamper() async throws {
    let now = Mutex<Int64>(1000)
    let key = try CursorProtector.Key(identifier: ScalarText("a"), material: Data(repeating: 1, count: 32))
    let next = try CursorProtector.Key(identifier: ScalarText("b"), material: Data(repeating: 2, count: 32))
    func box(_ keys: [CursorProtector.Key], active: String = "a", epoch: String = "epoch") throws -> CursorProtector {
        try .init(keys: keys, active: ScalarText(active), epoch: ScalarText(epoch), ttlMilliseconds: 100, clock: { now.withLock { $0 } })
    }
    func context(_ identity: VerifiedPrincipal = principal(), method: WireMethod = .listTools, params: String = "{}", generation: UInt64 = 1, instance: String = "instance") throws -> CursorContext {
        try .init(principal: identity, method: method, parameters: json(params), generation: generation, catalogInstance: ScalarText(instance))
    }
    func account() throws -> RequestBudget { try .init(workUnits: 8_000_000) }
    let boxA = try box([key]), ctx = try context()
    let token = try await boxA.seal(offset: 2, context: ctx, budget: account())
    #expect(try await boxA.open(token, context: ctx, budget: account()) == 2)
    for changed in [try context(principal("bob")), try context(principal(scopes: [ScalarText("scope")])), try context(method: .listResources), try context(params: #"{"x":null}"#), try context(generation: 2), try context(instance: "restart")] {
        await #expect(throws: CoreFailure.invalidCursor) { _ = try await boxA.open(token, context: changed, budget: account()) }
    }
    for bad in ["", token + "=", "0." + token.dropFirst(2), String(token.dropLast()) + (token.last == "A" ? "B" : "A")] {
        await #expect(throws: CoreFailure.invalidCursor) { _ = try await boxA.open(bad, context: ctx, budget: account()) }
    }
    let rotated = try box([key, next], active: "b")
    #expect(try await rotated.open(token, context: ctx, budget: account()) == 2)
    await #expect(throws: CoreFailure.invalidCursor) { _ = try await box([next], active: "b").open(token, context: ctx, budget: account()) }
    await #expect(throws: CoreFailure.invalidCursor) { _ = try await box([key], epoch: "new").open(token, context: ctx, budget: account()) }
    now.withLock { $0 = 1100 }
    await #expect(throws: CoreFailure.invalidCursor) { _ = try await boxA.open(token, context: ctx, budget: account()) }
}
