// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

// Deliberately no @testable import. Validate public methods against independently
// authored wire results and exact request params, not the SDK's view initializers.
private func consumerJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

private struct ConsumerStep: Sendable {
    let method: String
    let params: String
    let payload: String
    let name: String?
    let replyKey: String
    init(_ method: String, _ params: String, _ payload: String, name: String? = nil, replyKey: String = "result") {
        self.method = method; self.params = params; self.payload = payload
        self.name = name; self.replyKey = replyKey
    }
}

private final class ConsumerScript: ClientTransport, Sendable {
    private let steps: [ConsumerStep]
    private let position = Mutex(0)
    init(_ steps: [ConsumerStep]) { self.steps = steps }
    var count: Int { position.withLock { $0 } }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let index = position.withLock { n in let i = n; n += 1; return i }
        let step = try #require(steps.indices.contains(index) ? steps[index] : nil)
        let body = try #require(try consumerJSON(String(decoding: request.body, as: UTF8.self)).objectValue)
        let params = try #require(body["params"]?.objectValue)
        let expected = try #require(try consumerJSON(step.params).objectValue)
        let meta = try #require(params["_meta"]?.objectValue)
        #expect(request.method == step.method && body["method"]?.stringValue == step.method)
        #expect(request.name == step.name)
        #expect(body["jsonrpc"]?.stringValue == "2.0" && body["id"] == request.id.value)
        #expect(meta["io.modelcontextprotocol/protocolVersion"]?.stringValue == "2026-07-28")
        #expect(meta["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil)
        #expect(params.count == expected.count + 1)
        for member in expected { #expect(params[member.key.string] == member.value) }
        let response = JSON.object(try JSONObject(members: [
            JSONMember("jsonrpc", value: .string("2.0")), JSONMember("id", value: request.id.value),
            JSONMember(step.replyKey, value: try consumerJSON(step.payload))
        ]))
        try await receive(try WireCodec.write(response, limits: .balanced).result)
    }
}

private func expectInvalidConsumerResult(_ body: () async throws -> Void) async {
    do { try await body(); Issue.record("invalid result reached the public consumer") }
    catch ClientError.invalidResponse(_) {}
    catch { Issue.record("unexpected error category: \(error)") }
}

@Suite(.serialized) struct PublicConsumerContractCases {
    @Test func resourcePagesPreserveRawMetadataAndEmptyCursor() async throws {
        let first = #"{"resultType":"complete","ttlMs":42,"cacheScope":"private","nextCursor":"","resources":[{"uri":"file:///docs/a","name":"a","title":"A","mimeType":"text/plain","description":"first","size":7,"_meta":{"example.org/marker":"resource"}}]}"#
        let last = #"{"resultType":"complete","ttlMs":0,"cacheScope":"public","resources":[]}"#
        let script = ConsumerScript([.init("resources/list", "{}", first),
                                     .init("resources/list", #"{"cursor":""}"#, last)])
        let client = Client(transport: script)
        let page: Page<Resource> = try await client.listResources()
        #expect(page.nextCursor == "" && page.items.count == 1)
        let item = try #require(page.items.first)
        #expect(item.uri == "file:///docs/a" && item.name == "a" && item.mimeType == "text/plain" && item.description == "first")
        #expect(page.raw == (try consumerJSON(first)))
        #expect(item.raw == (try consumerJSON(first)).objectValue?["resources"]?.arrayValue?.first)
        let terminal = try await client.listResources(cursor: try #require(page.nextCursor))
        #expect(terminal.items.isEmpty && terminal.nextCursor == nil)
        #expect(terminal.raw == (try consumerJSON(last)) && script.count == 2)
    }

    @Test func resourceTemplatesPreserveOriginalTemplateAndOpaqueCursor() async throws {
        let first = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","nextCursor":"a+b/%2F=","resourceTemplates":[{"uriTemplate":"file:///repo/{path}","name":"source","title":"Source","description":"Source file","mimeType":"text/plain","_meta":{"example.org/marker":7}}]}"#
        let last = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","resourceTemplates":[]}"#
        let script = ConsumerScript([.init("resources/templates/list", "{}", first),
            .init("resources/templates/list", #"{"cursor":"a+b/%2F="}"#, last)])
        let client = Client(transport: script)
        let page: Page<ResourceTemplate> = try await client.listResourceTemplates()
        let item = try #require(page.items.first)
        #expect(page.items.count == 1 && page.nextCursor == "a+b/%2F=")
        #expect(item.uriTemplate == "file:///repo/{path}" && item.name == "source" && item.title == "Source")
        #expect(item.description == "Source file" && item.mimeType == "text/plain")
        #expect(item.raw == (try consumerJSON(first)).objectValue?["resourceTemplates"]?.arrayValue?.first)
        #expect(page.raw == (try consumerJSON(first)))
        let terminal = try await client.listResourceTemplates(cursor: try #require(page.nextCursor))
        #expect(terminal.items.isEmpty && terminal.nextCursor == nil && script.count == 2)
    }

    @Test func resourceReadReturnsAllTextAndBinaryEntriesInOrder() async throws {
        let uri = "file:///repo/index%20file"
        let result = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"file:///repo/index%20file","mimeType":"text/plain","text":"Hällo"},{"uri":"file:///repo/image","blob":"AAEC/w=="},{"uri":"file:///repo/empty","text":""}]}"#
        let script = ConsumerScript([.init("resources/read", #"{"uri":"file:///repo/index%20file"}"#, result, name: uri)])
        let entries: [ResourceContents] = try await Client(transport: script).readResource(uri)
        #expect(entries == [.text(uri: uri, mimeType: "text/plain", text: "Hällo"),
                            .blob(uri: "file:///repo/image", mimeType: nil, data: Data([0,1,2,255])),
                            .text(uri: "file:///repo/empty", mimeType: nil, text: "")])
        #expect(entries.map(\.bytes) == [Array("Hällo".utf8), [0,1,2,255], []])
        #expect(script.count == 1)
    }

    @Test func existingEmptyResourceIsNotConvertedToNotFound() async throws {
        let script = ConsumerScript([.init("resources/read", #"{"uri":"file:///empty"}"#,
            #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[]}"#, name: "file:///empty")])
        #expect(try await Client(transport: script).readResource("file:///empty").isEmpty)
        #expect(script.count == 1)
    }

    @Test func resourceNotFoundPreservesModernAndLegacyTypedErrors() async throws {
        for code in [-32602, -32002] {
            let payload = #"{"code":\#(code),"message":"not found","data":{"uri":"file:///missing"}}"#
            let script = ConsumerScript([.init("resources/read", #"{"uri":"file:///missing"}"#,
                payload, name: "file:///missing", replyKey: "error")])
            let expected = ClientError.server(code: code, message: "not found", data: try consumerJSON(#"{"uri":"file:///missing"}"#))
            await #expect(throws: expected) { _ = try await Client(transport: script).readResource("file:///missing") }
            #expect(script.count == 1)
        }
    }

    @Test func resourceReadRejectsInvalidBlobAndMissingRequiredMetadata() async throws {
        for result in [
            #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"file:///a","blob":"%%%"}]}"#,
            #"{"resultType":"complete","contents":[{"uri":"file:///a","text":"x"}]}"#,
            #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"text":"no uri"}]}"#
        ] {
            let script = ConsumerScript([.init("resources/read", #"{"uri":"file:///a"}"#, result, name: "file:///a")])
            await expectInvalidConsumerResult { _ = try await Client(transport: script).readResource("file:///a") }
            #expect(script.count == 1)
        }
    }

    @Test func promptPagesPreserveArgumentsAndRawMetadata() async throws {
        let first = #"{"resultType":"complete","ttlMs":30,"cacheScope":"private","nextCursor":"","prompts":[{"name":"review","title":"Review","description":"Review code","arguments":[{"name":"source","required":true}],"_meta":{"example.org/marker":true}}]}"#
        let last = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","prompts":[]}"#
        let script = ConsumerScript([.init("prompts/list", "{}", first), .init("prompts/list", #"{"cursor":""}"#, last)])
        let client = Client(transport: script)
        let page: Page<Prompt> = try await client.listPrompts()
        let prompt = try #require(page.items.first)
        #expect(prompt.name == "review" && prompt.description == "Review code" && page.nextCursor == "")
        #expect(page.raw == (try consumerJSON(first)))
        #expect(prompt.raw == (try consumerJSON(first)).objectValue?["prompts"]?.arrayValue?.first)
        let terminal = try await client.listPrompts(cursor: try #require(page.nextCursor))
        #expect(terminal.items.isEmpty && terminal.nextCursor == nil && script.count == 2)
    }

    @Test func promptGetEncodesArgumentsAndPreservesMixedContent() async throws {
        let result = #"{"resultType":"complete","description":"Review","_meta":{"example.org/marker":true},"messages":[{"role":"user","content":{"type":"text","text":"Question"}},{"role":"assistant","content":{"type":"image","mimeType":"image/png","data":"iVBORw=="}},{"role":"user","content":{"type":"audio","mimeType":"audio/wav","data":"AAEC"}},{"role":"assistant","content":{"type":"resource_link","uri":"file:///ref","name":"ref","title":"Reference","mimeType":"text/plain"}},{"role":"user","content":{"type":"resource","resource":{"uri":"file:///data","blob":"AAEC"}}}]}"#
        let script = ConsumerScript([.init("prompts/get", #"{"name":"review","arguments":{"language":"Swift","source":"a\nb"}}"#, result, name: "review"),
            .init("prompts/get", #"{"name":"review"}"#, #"{"resultType":"complete","messages":[]}"#, name: "review")])
        let client = Client(transport: script)
        let prompt: PromptResult = try await client.getPrompt("review", arguments: ["source":"a\nb", "language":"Swift"])
        #expect(prompt.description == "Review")
        #expect(prompt.messages.map(\.role) == [.user,.assistant,.user,.assistant,.user])
        #expect(prompt.messages.map(\.content) == [.text("Question"), .image(data: Data([137,80,78,71]), mimeType: "image/png"),
            .audio(data: Data([0,1,2]), mimeType: "audio/wav"),
            .resourceLink(uri: "file:///ref", name: "ref", mimeType: "text/plain", description: nil),
            .embeddedResource(.blob(uri: "file:///data", mimeType: nil, data: Data([0,1,2])))])
        #expect(prompt.raw == (try consumerJSON(result)))
        let empty = try await client.getPrompt("review")
        #expect(empty.description == nil && empty.messages.isEmpty && script.count == 2)
    }

    @Test func malformedPromptAndTemplateResultsDoNotReachConsumer() async throws {
        let badRole = ConsumerScript([.init("prompts/get", #"{"name":"x"}"#,
            #"{"resultType":"complete","messages":[{"role":"system","content":{"type":"text","text":"x"}}]}"#, name: "x")])
        await expectInvalidConsumerResult { _ = try await Client(transport: badRole).getPrompt("x") }
        let badTemplate = ConsumerScript([.init("resources/templates/list", "{}",
            #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","resourceTemplates":[{"name":"x"}]}"#)])
        await expectInvalidConsumerResult { _ = try await Client(transport: badTemplate).listResourceTemplates() }
        #expect(badRole.count == 1 && badTemplate.count == 1)
    }

    @Test func completionEncodesBothReferencesAndOptionalContext() async throws {
        let result = #"{"resultType":"complete","completion":{"values":["swift","swiftui"],"total":7,"hasMore":true},"_meta":{"example.org/marker":1}}"#
        let second = #"{"resultType":"complete","completion":{"values":[],"hasMore":false}}"#
        let third = #"{"resultType":"complete","completion":{"values":["a"]}}"#
        let script = ConsumerScript([
            .init("completion/complete", #"{"ref":{"type":"ref/prompt","name":"review"},"argument":{"name":"language","value":"sw"},"context":{"arguments":{"project":"App"}}}"#, result),
            .init("completion/complete", #"{"ref":{"type":"ref/resource","uri":"file:///{path}"},"argument":{"name":"path","value":""}}"#, second),
            .init("completion/complete", #"{"ref":{"type":"ref/prompt","name":"review"},"argument":{"name":"language","value":"a"}}"#, third)
        ])
        let client = Client(transport: script)
        let first: Completion = try await client.complete(.prompt(name: "review"), argument: "language", value: "sw", previousArguments: ["project":"App"])
        #expect(first.values == ["swift","swiftui"] && first.total == 7 && first.hasMore == true)
        #expect(first.raw == (try consumerJSON(result)))
        let next = try await client.complete(.resourceTemplate(uri: "file:///{path}"), argument: "path", value: "")
        #expect(next.values.isEmpty && next.total == nil && next.hasMore == false)
        let optional = try await client.complete(.prompt(name: "review"), argument: "language", value: "a")
        #expect(optional.values == ["a"] && optional.total == nil && optional.hasMore == nil && script.count == 3)
    }

    @Test func completionAccepts100ValuesAndRejects101() async throws {
        let params = #"{"ref":{"type":"ref/prompt","name":"p"},"argument":{"name":"x","value":""}}"#
        func result(_ n: Int) -> String {
            let items = (0..<n).map { "\"v\($0)\"" }.joined(separator: ",")
            return #"{"resultType":"complete","completion":{"values":[\#(items)]}}"#
        }
        let script = ConsumerScript([.init("completion/complete", params, result(100)),
                                     .init("completion/complete", params, result(101))])
        let client = Client(transport: script)
        let page = try await client.complete(.prompt(name: "p"), argument: "x", value: "")
        #expect(page.values == (0..<100).map { "v\($0)" })
        await expectInvalidConsumerResult { _ = try await client.complete(.prompt(name: "p"), argument: "x", value: "") }
        #expect(script.count == 2)
    }

    @Test func discoveryAndToolResultsKeepPublicRawViews() async throws {
        let discover = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"extensions":{"example.org/extension":{"value":7}}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"sdk","version":"1","title":"SDK","description":"Consumer fixture"}}}"#
        let tool = #"{"resultType":"complete","content":[{"type":"text","text":"A"},{"type":"image","data":"AAEC","mimeType":"image/png"},{"type":"text","text":"B"}],"structuredContent":{"value":1},"isError":true,"_meta":{"example.org/marker":true}}"#
        let script = ConsumerScript([.init("server/discover", "{}", discover),
                                     .init("tools/call", #"{"name":"x"}"#, tool, name: "x")])
        let client = Client(transport: script)
        let description: ServerDescription = try await client.discover()
        let info = try #require(description.serverInfo)
        #expect(info.name == "sdk" && info.version == "1" && info.title == "SDK")
        #expect(info.raw.objectValue?["description"]?.stringValue == "Consumer fixture")
        #expect(description.raw == (try consumerJSON(discover)))
        #expect(description.extensionSettings("example.org/extension") == (try consumerJSON(#"{"value":7}"#)))
        let result: ToolResult = try await client.callTool("x")
        #expect(result.resultType == "complete" && result.isError && result.text == "AB")
        #expect(result.content == [.text("A"), .image(data: Data([0,1,2]), mimeType: "image/png"), .text("B")])
        #expect(result.structuredContent == (try consumerJSON(#"{"value":1}"#)))
        #expect(result.raw == (try consumerJSON(tool)) && script.count == 2)
    }

    @Test func publicViewsHandlersAndTypedErrorsNeedNoTestableImport() throws {
        func acceptsSendable<T: Sendable>(_ type: T.Type) {}
        acceptsSendable(Client.self)
        acceptsSendable(ClientConfiguration.self)
        acceptsSendable(ResourceContents.self)
        acceptsSendable(Content.self)
        acceptsSendable(PromptMessage.self)
        acceptsSendable(PromptResult.self)
        acceptsSendable(Completion.self)
        acceptsSendable(CompletionReference.self)
        acceptsSendable(Page<Resource>.self)
        acceptsSendable(Page<ResourceTemplate>.self)
        acceptsSendable(Page<Prompt>.self)
        acceptsSendable(Implementation.self)
        acceptsSendable(RejectedTool.self)
        acceptsSendable(LoggingLevel.self)
        acceptsSendable(SubscriptionFilter.self)
        acceptsSendable(ClientError.self)
        acceptsSendable(ElicitationRequest.self)
        acceptsSendable(ElicitationResponse.self)
        acceptsSendable(SamplingRequest.self)
        acceptsSendable(SamplingResponse.self)
        acceptsSendable(Root.self)

        // Compile public handler signatures without executing handlers here.
        let config = ClientConfiguration(elicitation: .init { _ in .decline },
            sampling: { _ in try .text("fixture", model: "local") }, roots: { [] },
            additionalInputHandlers: ["example.org/input": { _ in .object(try JSONObject()) }],
            logLevel: .notice)
        #expect(config.logLevel == .notice && LoggingLevel.allCases.count == 8)
        let filter = SubscriptionFilter(resourcesListChanged: true, resourceSubscriptions: ["file:///x"],
            extensions: ["taskIds": .array([.string("t")])])
        #expect(filter.resourcesListChanged && !filter.toolsListChanged && filter.resourceSubscriptions == ["file:///x"])
        #expect(filter.extensions["taskIds"] == .array([.string("t")]))

        let details = try consumerJSON(#"{"requiredCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}"#)
        let error = ClientError.server(code: ClientError.Code.missingRequiredCapabilities, message: "missing", data: details)
        #expect(error == .server(code: -32021, message: "missing", data: details))
        #expect(error.serverCode == -32021 && error.requiredExtensions == ["io.modelcontextprotocol/tasks"])

        // This is the explicitly non-validating public raw view initializer.
        // It does not assert that the frozen standard wire schema accepts new types.
        let block = try consumerJSON(#"{"type":"hologram","depth":3}"#)
        let raw = try consumerJSON(#"{"resultType":"complete","content":[{"type":"hologram","depth":3}]}"#)
        let result = ToolResult(raw)
        #expect(result.raw == raw && result.content == [.unknown(block)])
    }
}
