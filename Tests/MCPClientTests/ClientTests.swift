// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol
import MCPServer
import MCPServerTesting

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let user = VerifiedPrincipal(subject: ScalarText("user"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private func text(_ value: String) throws -> JSON {
    .object(try JSONObject(members: [JSONMember("resultType", value: .string("complete")),
        JSONMember("content", value: .array([.object(try JSONObject(members: [JSONMember("type", value: .string("text")), JSONMember("text", value: .string(value))]))]))]))
}

private func makeServer() async throws -> Server {
    let echo = ToolRegistration(definition: try json(#"{"name":"echo","description":"Echo","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"$defs":{"keep":{"type":"string"}}}}"#)) { input, _ in
        guard case .value(let arguments) = input else { return try text("") }
        return try text(arguments.objectValue?["text"]?.stringValue ?? "")
    }
    let name = InputDescriptor(identifier: ScalarText("name"), request: try json(#"""
        {"method":"elicitation/create","params":{"mode":"form","message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}
        """#))
    let greet = ToolRegistration(definition: try json(#"{"name":"greet","inputSchema":{"type":"object"}}"#),
        rounds: MultiRoundProvider(version: ScalarText("v1"), inputs: [name], replay: .integrityOnly) { _, round, _ in
            guard let reply = round.responses["name"] else { return .inputRequired(.init(inputs: [name.identifier], state: .null)) }
            return .complete(try text("Hello, \(reply.objectValue?["content"]?.objectValue?["name"]?.stringValue ?? "?")!"))
        })
    let roots = InputDescriptor(identifier: ScalarText("roots"), request: try json(#"{"method":"roots/list","params":{}}"#))
    let rooted = ToolRegistration(definition: try json(#"{"name":"rooted","inputSchema":{"type":"object"}}"#),
        rounds: MultiRoundProvider(version: ScalarText("v1"), inputs: [roots], replay: .integrityOnly) { _, round, _ in
            guard let reply = round.responses["roots"] else { return .inputRequired(.init(inputs: [roots.identifier], state: .null)) }
            return .complete(try text("\(reply.objectValue?["roots"]?.arrayValue?.count ?? 0) roots"))
        })
    let slow = ToolRegistration(definition: try json(#"{"name":"slow","inputSchema":{"type":"object"}}"#)) { _, context in
        try await context.progress(JSONNumber(integer: 1), total: JSONNumber(integer: 2), message: "half")
        return try text("done")
    }
    let readme = ResourceProvider(definition: try json(#"{"uri":"file:///readme","name":"readme","mimeType":"text/plain"}"#)) { _, _ in
        try json(#"{"resultType":"complete","contents":[{"uri":"file:///readme","mimeType":"text/plain","text":"Read me"}]}"#)
    }
    return try await Server.make(info: json(#"{"name":"client-tests","version":"1"}"#),
        catalog: ServerCatalog(tools: [echo, greet, rooted, slow], resources: [readme], listChanged: [.listTools]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }),
        continuations: RequestStateProtector(keys: [.init(identifier: ScalarText("state"), material: Data(repeating: 3, count: 32))], active: ScalarText("state"),
            namespace: ScalarText("client-tests"), epoch: ScalarText("v1"), clock: { 1000 }))
}

private func client(_ server: Server, _ configuration: ClientConfiguration = .init()) -> Client {
    Client(transport: LoopbackTransport(server: server, principal: user), configuration: configuration)
}

/// Answers every request with an InputRequiredResult asking for sampling.
private struct InputRequiringTransport: ClientTransport {
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let id = try #require(try json(String(decoding: request.body, as: UTF8.self)).objectValue?["id"])
        let reply = try json(#"""
            {"jsonrpc":"2.0","id":0,"result":{"resultType":"input_required","inputRequests":{"s":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":1}}}}}
            """#)
        let members = Array(try #require(reply.objectValue)).map { $0.key.string == "id" ? JSONMember("id", value: id) : $0 }
        try await receive(try WireCodec.write(.object(try JSONObject(members: members)), limits: .balanced).result)
    }
}

@Suite(.serialized) struct ClientCases {
    @Test func discoverListAndCallPreserveWhatTheServerSent() async throws {
        let server = try await makeServer()
        let client = client(server, .init(info: try json(#"{"name":"tests","version":"1.0"}"#)))
        let description = try await client.discover()
        #expect(description.supportedVersions.contains("2026-07-28") && description.capabilities["tools"] != nil)
        let tools = try await client.listTools()
        #expect(tools.items.map(\.name).sorted() == ["echo", "greet", "rooted", "slow"])
        // Schemas pass through untouched, including keywords the SDK does not model.
        let echo = try #require(tools.items.first { $0.name == "echo" })
        #expect(echo.inputSchema.objectValue?["$defs"]?.objectValue?["keep"] != nil && echo.description == "Echo")
        let result = try await client.callTool("echo", arguments: try json(#"{"text":"hi"}"#))
        #expect(result.text == "hi" && !result.isError && result.resultType == "complete")
        let resources = try await client.listResources()
        #expect(resources.items.map(\.uri) == ["file:///readme"])
        #expect(try await client.readResource("file:///readme").first?.objectValue?["text"]?.stringValue == "Read me")
    }

    @Test func inputRoundsAreAnsweredByTheConfiguredHandlers() async throws {
        let server = try await makeServer()
        let asked = Mutex<[String]>([])
        let configuration = ClientConfiguration(
            elicitation: .init { params in
                asked.withLock { $0.append(params.objectValue?["message"]?.stringValue ?? "") }
                return try json(#"{"action":"accept","content":{"name":"Ada"}}"#)
            },
            roots: { _ in try json(#"{"roots":[{"uri":"file:///a"},{"uri":"file:///b"}]}"#) })
        let client = client(server, configuration)
        #expect(try await client.callTool("greet").text == "Hello, Ada!")
        #expect(asked.withLock { $0 } == ["Your name?"])
        #expect(try await client.callTool("rooted").text == "2 roots")
    }

    @Test func missingHandlersAndServerErrorsSurfaceAsTypedErrors() async throws {
        let server = try await makeServer()
        let client = client(server)
        // No elicitation handler means no declared capability: the server refuses with -32021.
        do { _ = try await client.callTool("greet"); Issue.record("expected -32021") }
        catch let error as ClientError {
            guard case .server(-32021, _, let data?) = error else { Issue.record("unexpected \(error)"); return }
            #expect(data.objectValue?["requiredCapabilities"]?.objectValue?["elicitation"] != nil)
        }
        // A server that asks anyway for input no handler answers: the client does not guess.
        let asking = Client(transport: InputRequiringTransport())
        do { _ = try await asking.callTool("anything"); Issue.record("expected unsupportedInput") }
        catch ClientError.unsupportedInput(let method) { #expect(method == "sampling/createMessage") }
        do { _ = try await client.callTool("missing"); Issue.record("expected a server error") }
        catch ClientError.server(let code, _, _) { #expect(code == -32602) }
        // A handler that answers with an invalid result is rejected before it is sent.
        let broken = Client(transport: LoopbackTransport(server: server, principal: user),
                            configuration: .init(elicitation: .init { _ in try json(#"{"action":"maybe"}"#) }))
        await #expect(throws: ClientError.self) { _ = try await broken.callTool("greet") }
    }

    @Test func progressReachesThePerCallHandler() async throws {
        let server = try await makeServer()
        let seen = Mutex<[Double]>([])
        let result = try await client(server).callTool("slow", onProgress: { progress in
            seen.withLock { $0.append(progress.progress) }
            #expect(progress.total == 2 && progress.message == "half")
        })
        #expect(result.text == "done" && seen.withLock { $0 } == [1])
    }

    @Test func listenStreamsAcknowledgementThenEventsUntilTheServerCloses() async throws {
        let server = try await makeServer()
        let client = client(server)
        let events = Mutex<[String]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.listen(try json(#"{"toolsListChanged":true,"promptsListChanged":true}"#)) { event in
                    switch event {
                    case .acknowledged(let agreed):
                        events.withLock { $0.append("ack:\(agreed.objectValue?["toolsListChanged"]?.booleanValue == true)") }
                    case .toolsChanged: events.withLock { $0.append("tools") }
                    default: events.withLock { $0.append("other") }
                    }
                }
            }
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while events.withLock({ $0.isEmpty }) {
                guard ContinuousClock.now < end else { Issue.record("no acknowledgement"); break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await server.publish(.toolsChanged, audience: .principal(user))
            while !events.withLock({ $0.contains("tools") }) {
                guard ContinuousClock.now < end else { Issue.record("no event"); break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await server.closeSubscriptions()
            try await group.waitForAll()
        }
        #expect(events.withLock { $0 } == ["ack:true", "tools"])
    }

    @Test func cancellingACallEndsItsExchange() async throws {
        let server = try await makeServer()
        let client = client(server, .init(elicitation: .init { _ in
            try await Task.sleep(for: .seconds(60)); return try json(#"{"action":"cancel"}"#)
        }))
        let call = Task { try await client.callTool("greet") }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        await #expect(throws: (any Error).self) { _ = try await call.value }
    }
}

/// Replays canned responses in order, each with the request's own id.
private final class ScriptedTransport: ClientTransport, Sendable {
    private let replies: [String]
    private let calls = Mutex(0)
    init(_ replies: [String]) { self.replies = replies }
    var requests: Int { calls.withLock { $0 } }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let index = calls.withLock { value -> Int in defer { value += 1 }; return value }
        let id = try #require(try json(String(decoding: request.body, as: UTF8.self)).objectValue?["id"])
        let reply = try #require(try json(replies[min(index, replies.count - 1)]).objectValue)
        let members = Array(reply).map { $0.key.string == "id" ? JSONMember("id", value: id) : $0 }
        try await receive(try WireCodec.write(.object(try JSONObject(members: members)), limits: .balanced).result)
    }
}

@Suite struct ClientCompatibilityCases {
    @Test func resultsWithoutResultTypeAreComplete() async throws {
        let transport = ScriptedTransport([#"{"jsonrpc":"2.0","id":0,"result":{"content":[{"type":"text","text":"legacy"}]}}"#])
        let result = try await Client(transport: transport).callTool("any")
        #expect(result.text == "legacy" && result.resultType == "complete" && transport.requests == 1)
    }

    @Test func unsupportedVersionIsRetriedOnceOnlyWhenOurVersionIsListed() async throws {
        let rejected = #"{"jsonrpc":"2.0","id":0,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28"]}}}"#
        let tools = #"{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","tools":[],"ttlMs":0,"cacheScope":"private"}}"#
        let retried = ScriptedTransport([rejected, tools])
        #expect(try await Client(transport: retried).listTools().items.isEmpty && retried.requests == 2)
        let foreign = ScriptedTransport([#"{"jsonrpc":"2.0","id":0,"error":{"code":-32022,"message":"no","data":{"supported":["2099-01-01"]}}}"#])
        do { _ = try await Client(transport: foreign).listTools(); Issue.record("expected unsupportedProtocol") }
        catch ClientError.unsupportedProtocol(let supported) { #expect(supported == ["2099-01-01"] && foreign.requests == 1) }
        // A server that keeps rejecting is not retried forever.
        let stubborn = ScriptedTransport([rejected])
        await #expect(throws: ClientError.self) { _ = try await Client(transport: stubborn).listTools() }
        #expect(stubborn.requests == 2)
    }
}
