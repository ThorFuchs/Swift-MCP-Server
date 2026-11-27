// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private func retainedJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

private enum RetainedScriptError: Error { case unexpectedRequest }

private struct RetainedStep: Sendable {
    let method: String
    var name: String? = nil
    var cursor: String? = nil
    let result: String
    var notifications: [String] = []
}

// Strict finite scripted exchange, independent of the physical transports.
private actor RetainedTransport: ClientTransport {
    nonisolated let mirrorsToolParameters = true
    private var steps: [RetainedStep]
    private(set) var requests: [OutgoingRequest] = []
    init(_ steps: [RetainedStep]) { self.steps = steps }
    var remaining: Int { steps.count }

    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let params = try retainedJSON(String(decoding: request.body, as: UTF8.self)).objectValue?["params"]?.objectValue
        let cursor = params?["cursor"]?.stringValue
        guard let step = steps.first, step.method == request.method,
              step.name.map(ScalarText.init) == request.name.map(ScalarText.init),
              step.cursor.map(ScalarText.init) == cursor.map(ScalarText.init) else {
            throw RetainedScriptError.unexpectedRequest
        }
        steps.removeFirst()
        requests.append(request)
        let id = String(decoding: try WireCodec.write(request.id.value, limits: .balanced).result, as: UTF8.self)
        for frame in step.notifications {
            try await receive(Data(frame.replacingOccurrences(of: #""$id""#, with: id).utf8))
        }
        let result = step.result.replacingOccurrences(of: #""$id""#, with: id)
        try await receive(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
    }

    var callHeaders: [[String]] {
        requests.filter { $0.method == "tools/call" }.map {
            $0.parameterHeaders.map { "\($0.name): \($0.value)" }.sorted()
        }
    }
}

// All interpolated strings are controlled synthetic fixtures.
private func retainedTool(_ name: String, header: String, type: String) -> String {
    #"{"name":"\#(name)","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"\#(header)"}}},"outputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"\#(type)"}},"additionalProperties":false}}"#
}
private func retainedList(_ tools: [String], cursor: String? = nil) -> RetainedStep {
    .init(method: "tools/list", cursor: cursor,
          result: #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[\#(tools.joined(separator: ","))]}"#)
}
private func retainedCall(_ name: String, value: String) -> RetainedStep {
    .init(method: "tools/call", name: name,
          result: #"{"resultType":"complete","content":[{"type":"text","text":"ok"}],"structuredContent":{"value":\#(value)}}"#)
}
private let retainedClose = #"{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":"$id"}}"#
private func retainedACK(_ filter: String) -> String {
    #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"$id"},"notifications":\#(filter)}}"#
}

@Suite(.serialized) struct ClientRetainedStateCases {
    @Test func distinctAcceptedToolNamesDoNotShareRoutingOrOutputSchemas() async throws {
        // The protocol recommends ASCII names, but the frozen Tool.name schema
        // accepts these distinct scalar sequences. Do not alias admitted names.
        let first = "caf\u{00E9}", second = "cafe\u{0301}"
        #expect(first == second) // Swift String canonical equivalence is the hazard.
        #expect(ScalarText(first) != ScalarText(second))
        let transport = RetainedTransport([
            retainedList([retainedTool(first, header: "First", type: "number"),
                          retainedTool(second, header: "Second", type: "string")]),
            retainedCall(first, value: "1"), retainedCall(second, value: #""ok""#)
        ])
        let client = Client(transport: transport)
        let page = try await client.listTools()
        #expect(page.items.map { ScalarText($0.name) } == [ScalarText(first), ScalarText(second)])
        let arguments = try retainedJSON(#"{"region":"west"}"#)
        // Record both calls even if the first is rejected using the wrong schema.
        for name in [first, second] {
            do { #expect(try await client.callTool(name, arguments: arguments).text == "ok") }
            catch { Issue.record("admitted name used another definition: \(error)") }
        }
        #expect(await transport.callHeaders == [["Mcp-Param-First: west"], ["Mcp-Param-Second: west"]])
        #expect(await transport.remaining == 0)
    }

    @Test func separateClientsKeepPrivateCatalogMetadataIsolated() async throws {
        let left = RetainedTransport([retainedList([retainedTool("probe", header: "Left", type: "number")]),
            retainedCall("probe", value: "1"), retainedCall("probe", value: #""wrong""#)])
        let right = RetainedTransport([retainedList([retainedTool("probe", header: "Right", type: "string")]),
            retainedCall("probe", value: #""ok""#), retainedCall("probe", value: "1")])
        let fresh = RetainedTransport([retainedCall("probe", value: "true")])
        let a = Client(transport: left), b = Client(transport: right), c = Client(transport: fresh)
        _ = try await a.listTools()
        _ = try await b.listTools()
        let args = try retainedJSON(#"{"region":"west"}"#)
        #expect(try await a.callTool("probe", arguments: args).text == "ok")
        #expect(try await b.callTool("probe", arguments: args).text == "ok")
        #expect(try await c.callTool("probe", arguments: args).text == "ok")
        for client in [a, b] {
            await #expect(throws: ClientError.invalidResponse("structuredContent of probe does not match its outputSchema")) {
                _ = try await client.callTool("probe", arguments: args)
            }
        }
        #expect(await left.callHeaders == [["Mcp-Param-Left: west"], ["Mcp-Param-Left: west"]])
        #expect(await right.callHeaders == [["Mcp-Param-Right: west"], ["Mcp-Param-Right: west"]])
        #expect(await fresh.callHeaders == [[]])
        #expect(await left.remaining == 0)
        #expect(await right.remaining == 0)
        #expect(await fresh.remaining == 0)
    }

    @Test func independentPagesCharacterizeRetentionUntilCompleteRefresh() async throws {
        // Characterization of current documented policy, NOT a proposed cap.
        // Small pages each contain a unique rejected annotation. Public
        // diagnostics witness growth, then an authoritative empty refresh retires it.
        let count = 32
        let steps = (0..<count).map { i in
            retainedList([retainedTool("tool-\(i)", header: "Invalid Header", type: "number")], cursor: "independent-\(i)")
        } + [retainedList([])]
        let transport = RetainedTransport(steps)
        let client = Client(transport: transport)
        for i in 0..<count {
            #expect(try await client.listTools(cursor: "independent-\(i)").items.isEmpty)
            #expect(await client.rejectedTools.count == i + 1)
        }
        print("A22D_CATALOG independent_pages=\(count) retained_rejections=\(await client.rejectedTools.count)")
        #expect(try await client.listTools().items.isEmpty)
        #expect(await client.rejectedTools.isEmpty)
        #expect(await transport.remaining == 0)
    }

    @Test func unknownExtensionPayloadStaysExchangeLocalAndRaw() async throws {
        let filter = #"{"x-example":{"ids":["A","B"],"flag":false}}"#
        let payload = #"{"nested":[null,{"x":17}],"tag":"future"}"#
        let notice = #"{"jsonrpc":"2.0","method":"notifications/x-example","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"$id"},"payload":\#(payload)}}"#
        let transport = RetainedTransport([
            .init(method: "subscriptions/listen", result: retainedClose, notifications: [retainedACK(filter), notice]),
            .init(method: "subscriptions/listen", result: retainedClose, notifications: [retainedACK(#"{"toolsListChanged":true}"#)])
        ])
        let client = Client(transport: transport)
        let expected = try retainedJSON(filter)
        let expectedPayload = try retainedJSON(payload)
        let seen = Mutex<[String]>([])
        try await client.listen(.init(extensions: ["x-example": try #require(expected.objectValue?["x-example"])])) { event in
            switch event {
            case .acknowledged(let raw):
                #expect(raw == expected)
                seen.withLock { $0.append("ack") }
            case .notification(let method, let raw):
                #expect(method == "notifications/x-example")
                #expect(raw.objectValue?["payload"] == expectedPayload)
                seen.withLock { $0.append("extension") }
            default: Issue.record("unexpected extension event")
            }
        }
        try await client.listen(.init(toolsListChanged: true)) { event in
            if case .acknowledged(let raw) = event {
                #expect(raw.objectValue?["x-example"] == nil)
                seen.withLock { $0.append("next-ack") }
            } else { Issue.record("previous exchange state leaked") }
        }
        #expect(seen.withLock { $0 } == ["ack", "extension", "next-ack"])
        let sent = await transport.requests
        #expect(sent.count == 2)
        #expect(try retainedJSON(String(decoding: sent[0].body, as: UTF8.self)).objectValue?["params"]?.objectValue?["notifications"] == expected)
        #expect(await transport.remaining == 0)
    }

    @Test func resourceSubscriptionDoesNotNormalizeDistinctURIStrings() async throws {
        let requested = "file:///a%2Fb", other = "file:///a/b"
        let ack = retainedACK(#"{"resourceSubscriptions":["\#(requested)"]}"#)
        func event(_ uri: String) -> String {
            #"{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"$id"},"uri":"\#(uri)"}}"#
        }
        let transport = RetainedTransport([
            .init(method: "subscriptions/listen", result: retainedClose, notifications: [ack, event(requested)]),
            .init(method: "subscriptions/listen", result: retainedClose, notifications: [ack, event(other)])
        ])
        let client = Client(transport: transport)
        let seen = Mutex<[ScalarText]>([])
        try await client.listen(.init(resourceSubscriptions: [requested])) { event in
            if case .resourceUpdated(let uri) = event { seen.withLock { $0.append(ScalarText(uri)) } }
        }
        await #expect(throws: ClientError.invalidResponse("event outside acknowledged filter")) {
            try await client.listen(.init(resourceSubscriptions: [requested])) { event in
                if case .resourceUpdated(let uri) = event { seen.withLock { $0.append(ScalarText(uri)) } }
            }
        }
        #expect(seen.withLock { $0 } == [ScalarText(requested)])
        #expect(await transport.remaining == 0)
    }
}
