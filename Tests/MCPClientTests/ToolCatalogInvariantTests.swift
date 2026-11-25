// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

// Consumer-level tests: only public Client, ClientTransport, wire data, and
// observable request headers. No access to the client's private dictionaries.
private func parseCatalogJSON(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

private func catalogTool(_ name: String, header: String? = nil, outputSchema: String? = nil) -> String {
    // All interpolated values are controlled, synthetic test fixtures.
    let input = header.map { #"{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"\#($0)"}}}"# }
        ?? #"{"type":"object"}"#
    let output = outputSchema.map { ",\"outputSchema\":\($0)" } ?? ""
    return "{\"name\":\"\(name)\",\"inputSchema\":\(input)\(output)}"
}

private func catalogResult(_ tools: [String], next: String? = nil) -> String {
    let cursor = next.map { ",\"nextCursor\":\"\($0)\"" } ?? ""
    return "{\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"tools\":[\(tools.joined(separator: ","))]\(cursor)}"
}

private func toolResult(_ structured: String? = nil) -> String {
    let extra = structured.map { ",\"structuredContent\":\($0)" } ?? ""
    return "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]\(extra)}"
}

private let numericOutput = #"{"type":"object","required":["value"],"properties":{"value":{"type":"number"}},"additionalProperties":false}"#
private let stringOutput = #"{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}"#

private enum CatalogScriptError: Error {
    case unexpectedRequest
    case rendezvousDeadline
}

/// A single-use rendezvous: the transport admits the request, then waits
/// until the test explicitly releases its response. The timer is a failure
/// bound for a missing rendezvous, never a sequencing or performance threshold.
private final class CatalogGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func pause() async throws {
        entered.continuation.yield(())
        entered.continuation.finish()
        var iterator = released.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.entered.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CatalogScriptError.rendezvousDeadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func open() {
        released.continuation.yield(())
        released.continuation.finish()
    }
}

private struct CatalogStep: Sendable {
    enum Payload: Sendable {
        case result(String)
        case error(String)
    }
    let method: String
    let name: String?
    let cursor: String?
    let payload: Payload
    let notifications: [String]
    let gate: CatalogGate?

    init(method: String, name: String? = nil, cursor: String? = nil,
         payload: Payload, notifications: [String] = [], gate: CatalogGate? = nil) {
        self.method = method; self.name = name; self.cursor = cursor
        self.payload = payload; self.notifications = notifications; self.gate = gate
    }

    static func list(_ tools: [String], cursor: String? = nil, next: String? = nil, gate: CatalogGate? = nil) -> Self {
        .init(method: "tools/list", cursor: cursor, payload: .result(catalogResult(tools, next: next)), gate: gate)
    }

    static func call(_ name: String, structured: String? = nil, gate: CatalogGate? = nil) -> Self {
        .init(method: "tools/call", name: name, payload: .result(toolResult(structured)), gate: gate)
    }

    static func removed(_ name: String) -> Self {
        .init(method: "tools/call", name: name,
              payload: .error(#"{"code":-32602,"message":"unknown tool"}"#))
    }
}

/// A strict script: unexpected methods, names, cursors, or extra requests throw.
/// The transport mirrors HTTP tool parameters but does not start a network server.
private actor CatalogTransport: ClientTransport {
    nonisolated let mirrorsToolParameters: Bool
    private var steps: [CatalogStep]
    private var requests: [OutgoingRequest] = []

    init(_ steps: [CatalogStep], mirrors: Bool = true) {
        self.steps = steps; self.mirrorsToolParameters = mirrors
    }

    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try parseCatalogJSON(String(decoding: request.body, as: UTF8.self))
        let cursor = body.objectValue?["params"]?.objectValue?["cursor"]?.stringValue
        guard let step = steps.first, request.method == step.method,
              request.name == step.name, cursor.map(ScalarText.init) == step.cursor.map(ScalarText.init) else {
            throw CatalogScriptError.unexpectedRequest
        }
        steps.removeFirst()
        requests.append(request)
        if let gate = step.gate { try await gate.pause() }
        let key: String, payload: String
        switch step.payload {
        case .result(let result): key = "result"; payload = result
        case .error(let error): key = "error"; payload = error
        }
        let reply = JSON.object(try JSONObject(members: [
            JSONMember("jsonrpc", value: .string("2.0")),
            JSONMember("id", value: request.id.value),
            JSONMember(key, value: try parseCatalogJSON(payload))
        ]))
        for notification in step.notifications {
            try await receive(Data(notification.utf8))
        }
        try await receive(try WireCodec.write(reply, limits: .balanced).result)
    }

    func headers(for name: String) -> [[String]] {
        requests.filter { $0.method == "tools/call" && $0.name == name }.map {
            $0.parameterHeaders.map { "\($0.name): \($0.value)" }.sorted()
        }
    }

    func remaining() -> Int { steps.count }
}

// This NEW suite is internally serialized to limit added schema-compilation
// pressure. Existing suites and the Core #53 reproduction are not serialized
// or otherwise changed by these tests.
@Suite(.serialized) struct ToolCatalogInvariantCases {
    @Test func completeRefreshDropsRemovedToolHeaders() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Region")]),
            .call("weather"),
            .list([]),
            .removed("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        #expect(try await client.listTools().items.map(\.name) == ["weather"])
        #expect(try await client.callTool("weather", arguments: arguments).text == "ok")
        #expect(try await client.listTools().items.isEmpty)
        await #expect(throws: ClientError.server(code: -32602, message: "unknown tool", data: nil)) {
            _ = try await client.callTool("weather", arguments: arguments)
        }
        // Server remains authoritative for the call, but a retired annotation
        // must not leak an obsolete routing header into that request.
        let headers = await transport.headers(for: "weather")
        #expect(headers == [["Mcp-Param-Region: west"], []])
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func completeRefreshDropsRemovedToolOutputSchema() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("weather", outputSchema: numericOutput)]),
            .call("weather", structured: #"{"value":1}"#),
            .list([]),
            .call("weather")
        ], mirrors: false)
        let client = Client(transport: transport)
        #expect(try await client.listTools().items.map(\.name) == ["weather"])
        #expect(try await client.callTool("weather").structuredContent != nil)
        #expect(try await client.listTools().items.isEmpty)
        // Direct invocation is supported without prior listing. The server may
        // change its catalog between requests; do not apply retired schemas.
        let response = try await client.callTool("weather")
        #expect(response.text == "ok" && response.structuredContent == nil)
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func repeatedRefreshDoesNotAccumulateRejectedTools() async throws {
        let bad = catalogTool("weather", header: "Bad Name")
        let other = catalogTool("other")
        let transport = CatalogTransport([
            .list([bad, other]),
            .list([bad, other]),
            .list([catalogTool("weather", header: "Region"), other])
        ])
        let client = Client(transport: transport)
        #expect(try await client.listTools().items.map(\.name) == ["other"])
        let first = await client.rejectedTools
        #expect(first.map(\.name) == ["weather"])
        #expect(try await client.listTools().items.map(\.name) == ["other"])
        let repeated = await client.rejectedTools
        #expect(repeated.map(\.name) == ["weather"])
        #expect(try await client.listTools().items.map(\.name) == ["weather", "other"])
        let repaired = await client.rejectedTools
        #expect(repaired.isEmpty)
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func redefinedToolUsesNewHeaderAndSchemaAndStillRejectsInvalidOutput() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "OldRegion", outputSchema: numericOutput)]),
            .call("weather", structured: #"{"value":1}"#),
            .list([catalogTool("weather", header: "Region", outputSchema: stringOutput)]),
            .call("weather", structured: #"{"value":"warm"}"#),
            .call("weather", structured: #"{"value":1}"#),
            .list([catalogTool("weather")]),
            .call("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        #expect(try await client.callTool("weather", arguments: arguments).structuredContent != nil)
        _ = try await client.listTools()
        #expect(try await client.callTool("weather", arguments: arguments).structuredContent != nil)
        await #expect(throws: ClientError.invalidResponse("structuredContent of weather does not match its outputSchema")) {
            _ = try await client.callTool("weather", arguments: arguments)
        }
        _ = try await client.listTools()
        #expect(try await client.callTool("weather", arguments: arguments).text == "ok")
        let headers = await transport.headers(for: "weather")
        #expect(headers == [["Mcp-Param-OldRegion: west"], ["Mcp-Param-Region: west"],
                            ["Mcp-Param-Region: west"], []])
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func stablePaginationRetainsVisitedPagesAndRetiresOldCatalog() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("legacy", header: "Legacy")]),
            .list([catalogTool("weather", header: "Region")], next: ""),
            .list([catalogTool("other", header: "Zone")], cursor: ""),
            .call("weather"),
            .call("other"),
            .removed("legacy")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        let head = try await client.listTools()
        #expect(head.items.map(\.name) == ["weather"])
        let cursor = try #require(head.nextCursor)
        #expect(cursor == "") // empty is an opaque valid cursor, not end-of-list
        let tail = try await client.listTools(cursor: cursor)
        #expect(tail.items.map(\.name) == ["other"] && tail.nextCursor == nil)
        _ = try await client.callTool("weather", arguments: arguments)
        _ = try await client.callTool("other", arguments: arguments)
        await #expect(throws: ClientError.server(code: -32602, message: "unknown tool", data: nil)) {
            _ = try await client.callTool("legacy", arguments: arguments)
        }
        let headHeaders = await transport.headers(for: "weather")
        let tailHeaders = await transport.headers(for: "other")
        let retiredHeaders = await transport.headers(for: "legacy")
        #expect(headHeaders == [["Mcp-Param-Region: west"]])
        #expect(tailHeaders == [["Mcp-Param-Zone: west"]])
        #expect(retiredHeaders == [[]])
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func malformedRefreshDoesNotCommitUnvalidatedMetadata() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Region")]),
            .init(method: "tools/list", payload: .result(
                #"{"resultType":"complete","tools":[{"name":"weather","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Unvalidated"}}}}]}"#)),
            .call("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        // A failed refresh (no required cache fields) is not a new valid catalog.
        await #expect(throws: ClientError.self) { _ = try await client.listTools() }
        #expect(try await client.callTool("weather", arguments: arguments).text == "ok")
        let headers = await transport.headers(for: "weather")
        #expect(headers == [["Mcp-Param-Region: west"]])
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }

    @Test func toolsChangedCallbackCanRefreshWithoutRetainingRetiredHeaders() async throws {
        let acknowledged = #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"},"notifications":{"toolsListChanged":true}}}"#
        let changed = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"}}}"#
        let closed = #"{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"}}"#
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Region")]),
            .init(method: "subscriptions/listen", payload: .result(closed), notifications: [acknowledged, changed]),
            .list([]),
            .removed("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        let events = Mutex<[String]>([])
        try await client.listen(SubscriptionFilter(toolsListChanged: true)) { event in
            switch event {
            case .acknowledged:
                events.withLock { $0.append("acknowledged") }
            case .toolsChanged:
                events.withLock { $0.append("toolsChanged") }
                // Explicit refresh through the documented consumer callback.
                // Do not assume automatic network I/O or invalidate-by-dropping
                // validation of still-advertised tools.
                let refreshed = try await client.listTools()
                #expect(refreshed.items.isEmpty)
            default:
                Issue.record("unexpected listen event")
            }
        }
        #expect(events.withLock { $0 } == ["acknowledged", "toolsChanged"])
        await #expect(throws: ClientError.server(code: -32602, message: "unknown tool", data: nil)) {
            _ = try await client.callTool("weather", arguments: arguments)
        }
        let headers = await transport.headers(for: "weather")
        #expect(headers == [[]])
        let remaining = await transport.remaining()
        #expect(remaining == 0)
    }
}


extension ToolCatalogInvariantCases {
    @Test func partialRefreshRetiresMetadataOnlyAfterSuccessfulTerminalPage() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("legacy", header: "Legacy", outputSchema: numericOutput)]),
            .list([catalogTool("weather", header: "Region")], next: "tail"),
            .call("legacy", structured: #"{"value":"wrong"}"#),
            .init(method: "tools/list", cursor: "tail", payload: .result(
                #"{"resultType":"complete","tools":[]}"#)),
            .call("legacy", structured: #"{"value":1}"#),
            .list([catalogTool("other", header: "Zone")], cursor: "tail"),
            .call("legacy")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        let head = try await client.listTools()
        #expect(head.nextCursor == "tail")
        await #expect(throws: ClientError.invalidResponse("structuredContent of legacy does not match its outputSchema")) {
            _ = try await client.callTool("legacy", arguments: arguments)
        }
        await #expect(throws: ClientError.self) { _ = try await client.listTools(cursor: "tail") }
        #expect(try await client.callTool("legacy", arguments: arguments).structuredContent != nil)
        let tail = try await client.listTools(cursor: "tail")
        #expect(tail.nextCursor == nil && tail.items.map(\.name) == ["other"])
        #expect(try await client.callTool("legacy", arguments: arguments).text == "ok")
        #expect(await transport.headers(for: "legacy") == [["Mcp-Param-Legacy: west"], ["Mcp-Param-Legacy: west"], []])
        #expect(await transport.remaining() == 0)
    }

    @Test func repairedToolOnLaterPageReplacesRejection() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Bad Name")], next: "next"),
            .list([catalogTool("weather", header: "Region")], cursor: "next"),
            .call("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        #expect(try await client.listTools().items.isEmpty)
        let rejected = await client.rejectedTools
        #expect(rejected.map(\.name) == ["weather"])
        #expect(try await client.listTools(cursor: "next").items.map(\.name) == ["weather"])
        #expect(await client.rejectedTools.isEmpty)
        _ = try await client.callTool("weather", arguments: arguments)
        #expect(await transport.headers(for: "weather") == [["Mcp-Param-Region: west"]])
        #expect(await transport.remaining() == 0)
    }

    @Test func lateContinuationCannotRestoreRetiredMetadata() async throws {
        let gate = CatalogGate()
        defer { gate.open() }
        let transport = CatalogTransport([
            .list([catalogTool("head")], next: "old"),
            .list([catalogTool("retired", header: "OldRegion", outputSchema: numericOutput)], cursor: "old", gate: gate),
            .list([]),
            .call("retired")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        async let delayed = client.listTools(cursor: "old")
        try await gate.waitUntilEntered()
        #expect(try await client.listTools().items.isEmpty)
        gate.open()
        let page = try await delayed
        // The old caller still receives its validated page, not fabricated data.
        #expect(page.items.map(\.name) == ["retired"])
        #expect(try await client.callTool("retired", arguments: arguments).text == "ok")
        #expect(await transport.headers(for: "retired") == [[]])
        #expect(await transport.remaining() == 0)
    }

    @Test func earlierHeadCannotOverwriteLaterStartedSuccessfulRefresh() async throws {
        let gate = CatalogGate()
        defer { gate.open() }
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "OldRegion", outputSchema: numericOutput)], gate: gate),
            .list([catalogTool("weather", header: "Region", outputSchema: stringOutput)]),
            .call("weather", structured: #"{"value":"warm"}"#)
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        async let earlier = client.listTools()
        try await gate.waitUntilEntered()
        #expect(try await client.listTools().items.map(\.name) == ["weather"])
        gate.open()
        let olderPage = try await earlier
        let oldSchema = try parseCatalogJSON(numericOutput)
        #expect(olderPage.items.first?.outputSchema == oldSchema)
        #expect(try await client.callTool("weather", arguments: arguments).structuredContent != nil)
        #expect(await transport.headers(for: "weather") == [["Mcp-Param-Region: west"]])
        #expect(await transport.remaining() == 0)
    }

    @Test func inFlightCallStillValidatesSchemaCapturedBeforeRefresh() async throws {
        let gate = CatalogGate()
        defer { gate.open() }
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Region", outputSchema: numericOutput)]),
            .call("weather", structured: #"{"value":"wrong"}"#, gate: gate),
            .list([]),
            .call("weather")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        async let pending = client.callTool("weather", arguments: arguments)
        try await gate.waitUntilEntered()
        #expect(try await client.listTools().items.isEmpty)
        gate.open()
        do {
            _ = try await pending
            Issue.record("The in-flight call lost its advertised output schema")
        } catch let error as ClientError {
            #expect(error == .invalidResponse("structuredContent of weather does not match its outputSchema"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try await client.callTool("weather", arguments: arguments).text == "ok")
        #expect(await transport.headers(for: "weather") == [["Mcp-Param-Region: west"], []])
        #expect(await transport.remaining() == 0)
    }

    @Test func standaloneCursorPageUpdatesObservedToolButDoesNotRetireOthers() async throws {
        let transport = CatalogTransport([
            .list([catalogTool("known", header: "Known")]),
            .list([catalogTool("other", header: "Zone", outputSchema: numericOutput)], cursor: "external"),
            .call("other", structured: #"{"value":"wrong"}"#),
            .call("known")
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        let page = try await client.listTools(cursor: "external")
        #expect(page.items.map(\.name) == ["other"])
        await #expect(throws: ClientError.invalidResponse("structuredContent of other does not match its outputSchema")) {
            _ = try await client.callTool("other", arguments: arguments)
        }
        _ = try await client.callTool("known", arguments: arguments)
        #expect(await transport.headers(for: "other") == [["Mcp-Param-Zone: west"]])
        #expect(await transport.headers(for: "known") == [["Mcp-Param-Known: west"]])
        #expect(await transport.remaining() == 0)
    }
}


extension ToolCatalogInvariantCases {
    @Test func byteDistinctCursorCannotCompleteActiveListing() async throws {
        let expected = "caf\u{00e9}"
        let external = "cafe\u{0301}"
        #expect(expected == external) // Swift String equality normalizes.
        #expect(ScalarText(expected) != ScalarText(external))
        let transport = CatalogTransport([
            .list([catalogTool("known", header: "Known", outputSchema: numericOutput)]),
            .list([catalogTool("head")], next: expected),
            .list([catalogTool("other")], cursor: external),
            .call("known", structured: #"{"value":"wrong"}"#)
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        let head = try await client.listTools()
        let next = try #require(head.nextCursor)
        #expect(ScalarText(next) == ScalarText(expected))
        _ = try await client.listTools(cursor: external)
        // A different opaque token cannot establish completion of the chain.
        await #expect(throws: ClientError.invalidResponse("structuredContent of known does not match its outputSchema")) {
            _ = try await client.callTool("known", arguments: arguments)
        }
        #expect(await transport.headers(for: "known") == [["Mcp-Param-Known: west"]])
        #expect(await transport.remaining() == 0)
    }

    @Test func failedNewerHeadPreservesLastValidatedMetadataAndSupersedesOlderHead() async throws {
        let gate = CatalogGate()
        defer { gate.open() }
        let transport = CatalogTransport([
            .list([catalogTool("weather", header: "Region", outputSchema: numericOutput)]),
            .list([catalogTool("weather", header: "OldRegion", outputSchema: stringOutput)], gate: gate),
            .init(method: "tools/list", payload: .result(#"{"resultType":"complete","tools":[]}"#)),
            .call("weather", structured: #"{"value":1}"#)
        ])
        let client = Client(transport: transport)
        let arguments = try parseCatalogJSON(#"{"region":"west"}"#)
        _ = try await client.listTools()
        async let older = client.listTools()
        try await gate.waitUntilEntered()
        await #expect(throws: ClientError.self) { _ = try await client.listTools() }
        gate.open()
        let page = try await older
        let oldSchema = try parseCatalogJSON(stringOutput)
        #expect(page.items.first?.outputSchema == oldSchema)
        #expect(try await client.callTool("weather", arguments: arguments).structuredContent != nil)
        #expect(await transport.headers(for: "weather") == [["Mcp-Param-Region: west"]])
        #expect(await transport.remaining() == 0)
    }
}
