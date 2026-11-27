// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private enum MRTRAuditError: Error, Equatable, Sendable { case unexpectedExchange, host, rendezvous }
private func mrtrJSON(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private func mrtrObject(_ text: String) throws -> JSONObject { try #require(try mrtrJSON(text).objectValue) }
private func mrtrResult(_ result: String) -> String { #"{"jsonrpc":"2.0","id":$ID,"result":\#(result)}"# }
private func mrtrInput(_ requests: String? = nil, state: String? = nil) -> String {
    var result = #"{"resultType":"input_required""#
    if let requests { result += #","inputRequests":\#(requests)"# }
    if let state { result += #","requestState":\#(state)"# }
    return mrtrResult(result + "}")
}
private func mrtrDone(_ text: String = "done") -> String {
    mrtrResult(#"{"resultType":"complete","content":[{"type":"text","text":"\#(text)"}]}"#)
}
private let mrtrForm = #"{"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}"#
private let mrtrURL = #"{"method":"elicitation/create","params":{"mode":"url","message":"Consent?","url":"https://example.invalid/consent"}}"#
private let mrtrSampling = #"{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Question"}}],"maxTokens":16}}"#
private let mrtrRoots = #"{"method":"roots/list"}"#
private func mrtrMap(_ key: String, _ request: String) -> String { #"{"\#(key)":\#(request)}"# }

private struct MRTRRequestRecord: Sendable {
    let route: String, method: String, id: Int
    let params: JSONObject
}

/// Finite, transport-neutral, public API only. Select the response by the
/// actual route and round; an unexpected exchange throws rather than looping.
/// No suspension occurs under the receipt lock. IDs are read from the wire.
private final class MRTRScript: ClientTransport, Sendable {
    private let plans: [String: [String]]
    private let storage = Mutex<[MRTRRequestRecord]>([])
    init(_ replies: [String], route: String = "probe") { plans = [route: replies] }
    init(plans: [String: [String]]) { self.plans = plans }
    var records: [MRTRRequestRecord] { storage.withLock { $0 } }
    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try mrtrObject(String(decoding: request.body, as: UTF8.self))
        let number = try #require(body["id"]?.numberValue)
        let id = try number.integer(as: Int.self)
        #expect(body["id"] == request.id.value)
        #expect(body["method"]?.stringValue == request.method)
        let params = try #require(body["params"]?.objectValue)
        let route = request.name ?? request.method
        let (index, previous) = storage.withLock { rows in
            let matching = rows.filter { $0.route == route }
            rows.append(.init(route: route, method: request.method, id: id, params: params))
            return (matching.count, matching.last?.id)
        }
        guard let replies = plans[route], index < replies.count else { throw MRTRAuditError.unexpectedExchange }
        var frame = replies[index].replacingOccurrences(of: "$ID", with: String(id))
        if let previous { frame = frame.replacingOccurrences(of: "$PREVIOUS", with: String(previous)) }
        try await receive(Data(frame.utf8))
    }
}

private func mrtrInvalid(_ body: () async throws -> Void) async {
    do { try await body(); Issue.record("invalid MRTR input unexpectedly completed") }
    catch ClientError.invalidResponse(_) { }
    catch { Issue.record("wrong error category: \(error)") }
}
private func mrtrCapabilities(_ row: MRTRRequestRecord) -> JSONObject? {
    row.params["_meta"]?.objectValue?["io.modelcontextprotocol/clientCapabilities"]?.objectValue
}

private final class MRTRSignal: Sendable {
    private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { channel.continuation.yield(()); channel.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.channel.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw MRTRAuditError.rendezvous }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw MRTRAuditError.rendezvous
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
private final class MRTROverlap: Sendable {
    private let arrivals = Mutex(0)
    private let signal = MRTRSignal()
    func meet() async throws {
        let previous = arrivals.withLock { n in defer { n += 1 }; return n }
        if previous == 1 { signal.send(); return }
        guard previous == 0 else { throw MRTRAuditError.rendezvous }
        try await signal.wait()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ClientMRTRContractCases {
    @Test func multipleRoundsReplaceOpaqueStateAndExactResponseKeys() async throws {
        let batch = #"{"form":\#(mrtrForm),"sample":\#(mrtrSampling),"roots":\#(mrtrRoots)}"#
        let transport = MRTRScript([mrtrInput(batch, state: #""opaque:e\u0301""#),
                                    mrtrInput(state: #""opaque:\u00e9""#),
                                    mrtrInput(mrtrMap("again", mrtrRoots)), mrtrDone()])
        let observed = Mutex<[String]>([])
        let configuration = ClientConfiguration(info: try mrtrJSON(#"{"name":"audit","version":"1"}"#),
            elicitation: .init { request in
                #expect(request.message == "Name?")
                if case .form(let schema) = request.mode { #expect(schema.objectValue?["required"]?.arrayValue == [.string("name")]) }
                else { Issue.record("implicit form did not map to form") }
                observed.withLock { $0.append("form") }
                return .accept(content: try mrtrObject(#"{"name":"Ada"}"#))
            }, sampling: { request in
                #expect(request.messages.first?.text == "Question" && request.maxTokens == 16)
                observed.withLock { $0.append("sample") }
                return try .text("answer", model: "host")
            }, roots: {
                observed.withLock { $0.append("roots") }
                return [Root(uri: "file:///workspace", name: "workspace")]
            }, maximumInputRounds: 3)
        let arguments = try mrtrJSON(#"{"original":[1,"value"]}"#)
        let result = try await Client(transport: transport, configuration: configuration).callTool("probe", arguments: arguments, onProgress: { _ in })
        #expect(result.text == "done")
        let rows = transport.records
        try #require(rows.count == 4)
        #expect(Set(rows.map(\.id)).count == 4)
        var tokens: [String] = []
        for row in rows {
            #expect(row.method == "tools/call" && row.params["name"] == .string("probe") && row.params["arguments"] == arguments)
            let meta = try #require(row.params["_meta"]?.objectValue)
            #expect(meta["io.modelcontextprotocol/protocolVersion"] == .string("2026-07-28"))
            #expect(meta["io.modelcontextprotocol/clientInfo"] == configuration.info)
            let capabilities = try #require(mrtrCapabilities(row))
            #expect(capabilities["elicitation"]?.objectValue?["form"] != nil && capabilities["elicitation"]?.objectValue?["url"] == nil)
            #expect(capabilities["sampling"]?.objectValue != nil && capabilities["roots"]?.objectValue != nil)
            tokens.append(try #require(meta["progressToken"]?.stringValue))
        }
        #expect(Set(tokens).count == 4)
        #expect(rows[0].params["requestState"] == nil && rows[0].params["inputResponses"] == nil)
        #expect(Array(try #require(rows[1].params["requestState"]?.stringValue).utf8) == Array("opaque:e\u{301}".utf8))
        #expect(Array(try #require(rows[2].params["requestState"]?.stringValue).utf8) == Array("opaque:\u{e9}".utf8))
        let replies = try #require(rows[1].params["inputResponses"]?.objectValue)
        #expect(Set(replies.map(\.key.string)) == ["form", "sample", "roots"])
        #expect(replies["form"] == (try mrtrJSON(#"{"action":"accept","content":{"name":"Ada"}}"#)))
        #expect(replies["sample"] == (try mrtrJSON(#"{"role":"assistant","content":{"type":"text","text":"answer"},"model":"host","stopReason":"endTurn"}"#)))
        #expect(replies["roots"] == (try mrtrJSON(#"{"roots":[{"uri":"file:///workspace","name":"workspace"}]}"#)))
        #expect(rows[2].params["inputResponses"] == nil && rows[3].params["requestState"] == nil)
        let last = try #require(rows[3].params["inputResponses"]?.objectValue)
        #expect(last.count == 1 && last["again"] == replies["roots"])
        #expect(observed.withLock { $0.sorted() } == ["form", "roots", "roots", "sample"])
    }

    @Test func resourceAndPromptSupportStateOnlyContinuation() async throws {
        let transport = MRTRScript(plans: [
            "file:///audit": [mrtrInput(state: #""resource-state""#), mrtrResult(#"{"resultType":"complete","contents":[{"uri":"file:///audit","text":"resource"}],"ttlMs":0,"cacheScope":"private"}"#)],
            "prompt": [mrtrInput(state: #""prompt-state""#), mrtrResult(#"{"resultType":"complete","messages":[{"role":"user","content":{"type":"text","text":"prompt"}}]}"#)]])
        let client = Client(transport: transport)
        #expect(try await client.readResource("file:///audit").count == 1)
        #expect(try await client.getPrompt("prompt", arguments: ["x":"y"]).messages.count == 1)
        let rows = transport.records
        try #require(rows.count == 4)
        #expect(rows.map(\.method) == ["resources/read", "resources/read", "prompts/get", "prompts/get"])
        #expect(rows[1].params["requestState"] == .string("resource-state") && rows[3].params["requestState"] == .string("prompt-state"))
        let promptArguments = try mrtrJSON(#"{"x":"y"}"#)
        #expect(rows[1].params["uri"] == .string("file:///audit") && rows[3].params["arguments"] == promptArguments)
        #expect(rows.allSatisfy { $0.params["inputResponses"] == nil })
        #expect(Set(rows.map(\.id)).count == 4)
    }

    @Test func parallelCallsKeepIdenticalInputKeysAndDifferentStateIsolated() async throws {
        let overlap = MRTROverlap()
        func initial(_ label: String) -> String {
            mrtrInput(mrtrMap("same-key", #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8,"systemPrompt":"\#(label)"}}"#), state: #""state-\#(label)""#)
        }
        let transport = MRTRScript(plans: ["A":[initial("A"),mrtrDone("A")], "B":[initial("B"),mrtrDone("B")]])
        let client = Client(transport: transport, configuration: .init(sampling: { request in
            let label = try #require(request.systemPrompt)
            try await overlap.meet()
            return try .text(label, model: "host")
        }))
        async let a = client.callTool("A")
        async let b = client.callTool("B")
        let results = try await (a,b)
        #expect(results.0.text == "A" && results.1.text == "B")
        let rows = transport.records
        try #require(rows.count == 4)
        #expect(Set(rows.map(\.id)).count == 4)
        for label in ["A", "B"] {
            let own = rows.filter { $0.route == label }
            try #require(own.count == 2)
            #expect(own[0].params["requestState"] == nil && own[0].params["inputResponses"] == nil)
            #expect(own[1].params["requestState"] == .string("state-" + label))
            let answers = try #require(own[1].params["inputResponses"]?.objectValue)
            #expect(answers.count == 1 && answers["same-key"]?.objectValue?["content"]?.objectValue?["text"] == .string(label))
        }
    }

    @Test func unsupportedCoreMethodRejectsInputRequiredBeforeHost() async throws {
        let calls = Mutex(0)
        let transport = MRTRScript([mrtrInput(mrtrMap("s", mrtrSampling)), mrtrResult(#"{"resultType":"complete","tools":[],"ttlMs":0,"cacheScope":"private"}"#)], route: "tools/list")
        let client = Client(transport: transport, configuration: .init(sampling: { _ in calls.withLock { $0 += 1 }; return try .text("unexpected", model: "host") }))
        await mrtrInvalid { _ = try await client.listTools() }
        #expect(calls.withLock { $0 } == 0 && transport.records.count == 1)
    }

    @Test func inputRequiredWithoutEitherFieldDoesNotRetry() async {
        let transport = MRTRScript([mrtrInput(), mrtrDone()])
        await mrtrInvalid { _ = try await Client(transport: transport).callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func previousRoundResponseIDIsRejectedBeforeHost() async {
        let calls = Mutex(0)
        let transport = MRTRScript([mrtrInput(state: #""first""#), mrtrInput(mrtrMap("s", mrtrSampling)).replacingOccurrences(of: "$ID", with: "$PREVIOUS"), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in calls.withLock { $0 += 1 }; return try .text("unexpected", model: "host") }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(calls.withLock { $0 } == 0 && transport.records.count == 2)
    }

    @Test func wrongJSONRPCVersionCannotTriggerHost() async {
        let calls = Mutex(0)
        let invalid = mrtrInput(mrtrMap("s", mrtrSampling)).replacingOccurrences(of: #""jsonrpc":"2.0""#, with: #""jsonrpc":"1.0""#)
        let transport = MRTRScript([invalid, mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in calls.withLock { $0 += 1 }; return try .text("unexpected", model: "host") }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(calls.withLock { $0 } == 0 && transport.records.count == 1)
    }

    @Test func malformedWireInputBatchIsRejectedBeforeAnyHost() async {
        let calls = Mutex(0)
        let invalid = #"{"good":\#(mrtrRoots),"bad":{"method":"sampling/createMessage","params":{"messages":[]}}}"#
        let transport = MRTRScript([mrtrInput(invalid), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in calls.withLock { $0 += 1 }; return try .text("x", model: "host") }, roots: { calls.withLock { $0 += 1 }; return [] }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(calls.withLock { $0 } == 0 && transport.records.count == 1)
    }

    @Test func undeclaredKnownHandlersReturnExactUnsupportedInput() async {
        for (method, request) in [("elicitation/create", mrtrForm), ("sampling/createMessage", mrtrSampling), ("roots/list", mrtrRoots)] {
            let transport = MRTRScript([mrtrInput(mrtrMap("input", request)), mrtrDone()])
            await #expect(throws: ClientError.unsupportedInput(method: method)) { _ = try await Client(transport: transport).callTool("probe") }
            #expect(transport.records.count == 1)
            if let row = transport.records.first { #expect(mrtrCapabilities(row)?.isEmpty == true) }
        }
    }

    @Test func unadvertisedURLModeDoesNotReachHandler() async {
        let calls = Mutex(0)
        let transport = MRTRScript([mrtrInput(mrtrMap("url", mrtrURL)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(elicitation: .init { _ in calls.withLock { $0 += 1 }; return .cancel }))
        await #expect(throws: ClientError.unsupportedInput(method: "elicitation/create")) { _ = try await client.callTool("probe") }
        #expect(calls.withLock { $0 } == 0 && transport.records.count == 1)
    }

    @Test func acceptedFormCannotOmitRequiredContent() async {
        let transport = MRTRScript([mrtrInput(mrtrMap("form", mrtrForm)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(elicitation: .init { _ in .accept(content: nil) }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func acceptedURLCannotReturnFormContent() async {
        let transport = MRTRScript([mrtrInput(mrtrMap("url", mrtrURL)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(elicitation: .init(form: false, url: true) { _ in .accept(content: try mrtrObject(#"{"name":"unexpected"}"#)) }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func declineCancelAndURLAcceptanceHaveNoContent() async throws {
        for (request, answer, action) in [(mrtrForm, ElicitationResponse.decline, "decline"), (mrtrForm, .cancel, "cancel"), (mrtrURL, .accept(content: nil), "accept")] {
            let transport = MRTRScript([mrtrInput(mrtrMap("input", request)), mrtrDone()])
            let client = Client(transport: transport, configuration: .init(elicitation: .init(form: true, url: true) { typed in
                if request == mrtrURL {
                    if case .url(let url, _) = typed.mode { #expect(url.absoluteString == "https://example.invalid/consent") }
                    else { Issue.record("expected URL mode") }
                }
                return answer
            }))
            #expect(try await client.callTool("probe").text == "done")
            let rows = transport.records
            try #require(rows.count == 2)
            let reply = try #require(rows[1].params["inputResponses"]?.objectValue?["input"]?.objectValue)
            #expect(reply["action"] == .string(action) && reply["content"] == nil)
        }
    }

    @Test func samplingToolsAndToolChoiceRequireAdvertisedCapability() async {
        for field in [#""tools":[]"#, #""toolChoice":{"mode":"auto"}"#] {
            let calls = Mutex(0)
            let request = #"{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8,\#(field)}}"#
            let transport = MRTRScript([mrtrInput(mrtrMap("s", request)), mrtrDone()])
            let client = Client(transport: transport, configuration: .init(sampling: { _ in calls.withLock { $0 += 1 }; return try .text("unexpected", model: "host") }))
            do { _ = try await client.callTool("probe"); Issue.record("unadvertised sampling feature accepted") }
            catch ClientError.invalidResponse(_) { }
            catch ClientError.unsupportedInput(let method) { #expect(method == "sampling/createMessage") }
            catch { Issue.record("wrong error category: \(error)") }
            #expect(calls.withLock { $0 } == 0 && transport.records.count == 1)
            if let row = transport.records.first { #expect(mrtrCapabilities(row)?["sampling"]?.objectValue?["tools"] == nil) }
        }
    }

    @Test func invalidSamplingResultCannotBeRetriedToServer() async {
        let transport = MRTRScript([mrtrInput(mrtrMap("s", mrtrSampling)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in SamplingResponse(content: .null, model: "host") }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func nonFileRootIsRejectedBeforeContinuation() async {
        let transport = MRTRScript([mrtrInput(mrtrMap("r", mrtrRoots)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(roots: { [Root(uri: "https://example.invalid/root")] }))
        await mrtrInvalid { _ = try await client.callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func directAnswerValidatesMalformedKnownRequestsBeforeHost() async throws {
        let calls = Mutex(0)
        let transport = MRTRScript([])
        let client = Client(transport: transport, configuration: .init(
            elicitation: .init { _ in calls.withLock { $0 += 1 }; return .decline },
            sampling: { _ in calls.withLock { $0 += 1 }; return try .text("x", model: "host") },
            roots: { calls.withLock { $0 += 1 }; return [] }))
        for request in [#"{"method":"elicitation/create","params":{"message":"missing schema"}}"#, #"{"method":"sampling/createMessage","params":{"messages":[]}}"#, #"{"method":"roots/list","params":"not an object"}"#] {
            let input = try mrtrObject(mrtrMap("k", request))
            await mrtrInvalid { _ = try await client.answerInputRequests(input) }
        }
        #expect(calls.withLock { $0 } == 0 && transport.records.isEmpty)
    }

    @Test func directExtensionHandlerPreservesRawParamsAndKey() async throws {
        let transport = MRTRScript([])
        let params = try mrtrJSON(#"{"custom":[1,{"value":"raw"}]}"#)
        let response = try mrtrJSON(#"{"resultType":"complete","extensionValue":{"kept":true}}"#)
        let client = Client(transport: transport, configuration: .init(additionalInputHandlers: ["example/input": { raw in #expect(raw == params); return response }]))
        let input = try mrtrObject(#"{"opaque-key":{"method":"example/input","params":{"custom":[1,{"value":"raw"}]}}}"#)
        let output = try await client.answerInputRequests(input)
        #expect(output.objectValue?.count == 1 && output.objectValue?["opaque-key"] == response)
        #expect(transport.records.isEmpty)
    }

    @Test func handlerErrorPropagatesUnchangedWithoutRetry() async {
        let transport = MRTRScript([mrtrInput(mrtrMap("s", mrtrSampling)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in throw MRTRAuditError.host }))
        await #expect(throws: MRTRAuditError.host) { _ = try await client.callTool("probe") }
        #expect(transport.records.count == 1)
    }

    @Test func cancellationDuringHandlerPreventsAnotherRound() async throws {
        let entered = MRTRSignal()
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancelled = Mutex(false)
        let transport = MRTRScript([mrtrInput(mrtrMap("s", mrtrSampling)), mrtrDone()])
        let client = Client(transport: transport, configuration: .init(sampling: { _ in
            entered.send()
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            cancelled.withLock { $0 = Task.isCancelled }
            return try .text("late answer", model: "host")
        }))
        let task = Task { try await client.callTool("probe") }
        do { try await entered.wait() }
        catch { task.cancel(); gate.continuation.finish(); _ = await task.result; throw error }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        gate.continuation.finish()
        #expect(cancelled.withLock { $0 } && transport.records.count == 1)
    }

    @Test func preCancelledDirectAnswerCannotInvokeHost() async throws {
        let calls = Mutex(0)
        let transport = MRTRScript([])
        let client = Client(transport: transport, configuration: .init(roots: { calls.withLock { $0 += 1 }; return [] }))
        let input = try mrtrObject(mrtrMap("r", mrtrRoots))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(Task.isCancelled)
                await #expect(throws: CancellationError.self) { _ = try await client.answerInputRequests(input) }
            }
            try await group.waitForAll()
        }
        #expect(calls.withLock { $0 } == 0 && transport.records.isEmpty)
    }

    @Test func preCancelledCallDoesNotStartExchange() async throws {
        let transport = MRTRScript([mrtrDone()])
        let client = Client(transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(Task.isCancelled)
                await #expect(throws: CancellationError.self) { _ = try await client.callTool("probe") }
            }
            try await group.waitForAll()
        }
        #expect(transport.records.isEmpty)
    }

    @Test func inputRoundLimitPermitsBoundaryAndRejectsNextBeforeHandler() async throws {
        #expect(ClientConfiguration(maximumInputRounds: 0).maximumInputRounds == 1)
        let input = mrtrInput(mrtrMap("r", mrtrRoots))
        for excessive in [false, true] {
            let calls = Mutex(0)
            let transport = MRTRScript([input, input, excessive ? input : mrtrDone(), mrtrDone()])
            let client = Client(transport: transport, configuration: .init(roots: { calls.withLock { $0 += 1 }; return [] }, maximumInputRounds: 2))
            if excessive { await #expect(throws: ClientError.tooManyInputRounds) { _ = try await client.callTool("probe") } }
            else { #expect(try await client.callTool("probe").text == "done") }
            #expect(calls.withLock { $0 } == 2 && transport.records.count == 3)
        }
    }

    @Test func ordinaryServerErrorAfterInputRoundIsNotReexecuted() async throws {
        let data = try mrtrJSON(#"{"detail":"kept"}"#)
        let transport = MRTRScript([mrtrInput(state: #""state""#), #"{"jsonrpc":"2.0","id":$ID,"error":{"code":-32603,"message":"failed","data":{"detail":"kept"}}}"#, mrtrDone()])
        await #expect(throws: ClientError.server(code: -32603, message: "failed", data: data)) { _ = try await Client(transport: transport).callTool("probe") }
        #expect(transport.records.count == 2)
    }
}
