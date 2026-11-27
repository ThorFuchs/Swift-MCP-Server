// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPClient
import MCPProtocol

private enum IdentityScriptError: Error { case unexpectedRequest }

private struct IdentityStep: Sendable {
    let method: String
    var name: String? = nil
    var cursor: String? = nil
    let result: String
}

// Preserve original D1.1 test bytes. This independent finite script checks
// both routing metadata and the actual decoded request name/cursor.
private actor IdentityTransport: ClientTransport {
    nonisolated let mirrorsToolParameters = true
    private var steps: [IdentityStep]
    private(set) var callHeaders: [[String]] = []
    init(_ steps: [IdentityStep]) { self.steps = steps }
    var remaining: Int { steps.count }

    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let params = try WireCodec.parse(Array(request.body), limits: .balanced).result.objectValue?["params"]?.objectValue
        guard let step = steps.first, request.method == step.method,
              request.name.map(ScalarText.init) == step.name.map(ScalarText.init),
              params?["name"]?.stringValue.map(ScalarText.init) == step.name.map(ScalarText.init),
              params?["cursor"]?.stringValue.map(ScalarText.init) == step.cursor.map(ScalarText.init) else {
            throw IdentityScriptError.unexpectedRequest
        }
        steps.removeFirst()
        if request.method == "tools/call" {
            let headers = request.parameterHeaders.map { "\($0.name): \($0.value)" }.sorted()
            callHeaders.append(headers)
            print("A22D_D12_CALL name_utf8=\(Array((request.name ?? "").utf8)) headers=\(headers)")
        }
        let id = String(decoding: try WireCodec.write(request.id.value, limits: .balanced).result, as: UTF8.self)
        try await receive(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(step.result)}"#.utf8))
    }
}

// All interpolations are controlled synthetic strings, not arbitrary input.
private func identityTool(_ name: String, header: String, outputType: String = "number", inputType: String = "string") -> String {
    #"{"name":"\#(name)","inputSchema":{"type":"object","properties":{"region":{"type":"\#(inputType)","x-mcp-header":"\#(header)"}}},"outputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"\#(outputType)"}},"additionalProperties":false}}"#
}
private func identityList(_ tools: [String], cursor: String? = nil, next: String? = nil) -> IdentityStep {
    let tail = next.map { ",\"nextCursor\":\"\($0)\"" } ?? ""
    return .init(method: "tools/list", cursor: cursor,
        result: #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[\#(tools.joined(separator: ","))]\#(tail)}"#)
}
private func identityCall(_ name: String, value: String) -> IdentityStep {
    .init(method: "tools/call", name: name,
        result: #"{"resultType":"complete","content":[{"type":"text","text":"ok"}],"structuredContent":{"value":\#(value)}}"#)
}
private func identityArguments() throws -> JSON {
    try WireCodec.parse(Array(#"{"region":"west"}"#.utf8), limits: .balanced).result
}
private let composed = "caf\u{00E9}"
private let decomposed = "cafe\u{0301}"

@Suite(.serialized) struct ClientCatalogIdentityBoundaryCases {
    @Test func partialListingRetainsDistinctPeerAndCompletionRetiresOnlyUnseenIdentity() async throws {
        #expect(composed == decomposed && ScalarText(composed) != ScalarText(decomposed))
        let transport = IdentityTransport([
            identityList([identityTool(composed, header: "First"), identityTool(decomposed, header: "Second", outputType: "string")]),
            identityList([identityTool(composed, header: "Fresh")], next: "next"),
            identityCall(decomposed, value: #""still-listed""#),
            identityList([], cursor: "next"),
            identityCall(decomposed, value: "true"),
            identityCall(composed, value: "1"),
            identityCall(composed, value: #""invalid""#)
        ])
        let client = Client(transport: transport)
        let args = try identityArguments()
        let initial = try await client.listTools()
        #expect(initial.items.map { ScalarText($0.name) } == [ScalarText(composed), ScalarText(decomposed)])
        let head = try await client.listTools()
        #expect(head.items.map { ScalarText($0.name) } == [ScalarText(composed)])
        #expect(head.nextCursor == "next")
        // During the incomplete chain, the unvisited distinct name still
        // has its previous string schema and its own routing declaration.
        do { #expect(try await client.callTool(decomposed, arguments: args).text == "ok") }
        catch { Issue.record("unvisited identity lost during partial listing: \(error)") }
        let terminal = try await client.listTools(cursor: "next")
        #expect(terminal.items.isEmpty && terminal.nextCursor == nil)
        // On completion the unseen name is retired. A direct call remains
        // supported and must not inherit either old schema or surviving header.
        do { #expect(try await client.callTool(decomposed, arguments: args).text == "ok") }
        catch { Issue.record("retired identity still uses a schema: \(error)") }
        #expect(try await client.callTool(composed, arguments: args).text == "ok")
        await #expect(throws: ClientError.invalidResponse("structuredContent of \(composed) does not match its outputSchema")) {
            _ = try await client.callTool(composed, arguments: args)
        }
        let headers = await transport.callHeaders
        #expect(headers == [["Mcp-Param-Second: west"], [], ["Mcp-Param-Fresh: west"], ["Mcp-Param-Fresh: west"]])
        #expect(await transport.remaining == 0)
    }

    @Test func rejectionDiagnosticsRemainDistinctAcrossReorderRepairAndRetirement() async throws {
        let badA = identityTool(composed, header: "Invalid Header")
        let badB = identityTool(decomposed, header: "Second", inputType: "number")
        let repairedA = identityTool(composed, header: "Fresh")
        let transport = IdentityTransport([
            identityList([badA, badB]), identityList([badB, badA]),
            identityList([repairedA], cursor: "independent"), identityList([repairedA])
        ])
        let client = Client(transport: transport)
        // UTF-8 tie-break for names equal under Swift String comparison.
        // The established String ordering of non-equivalent names is unchanged.
        let expectedNames = [ScalarText(decomposed), ScalarText(composed)]
        for _ in 0..<2 {
            #expect(try await client.listTools().items.isEmpty)
            let rejected = await client.rejectedTools
            print("A22D_D12_REJECTIONS names_utf8=\(rejected.map { Array($0.name.utf8) }) reasons=\(rejected.map(\.reason))")
            #expect(rejected.map { ScalarText($0.name) } == expectedNames)
            #expect(rejected.first { ScalarText($0.name) == ScalarText(composed) }?.reason == "x-mcp-header is not an HTTP token")
            #expect(rejected.first { ScalarText($0.name) == ScalarText(decomposed) }?.reason == "x-mcp-header on a non-primitive property")
        }
        let partial = try await client.listTools(cursor: "independent")
        #expect(partial.items.map { ScalarText($0.name) } == [ScalarText(composed)])
        let afterRepair = await client.rejectedTools
        print("A22D_D12_REPAIR names_utf8=\(afterRepair.map { Array($0.name.utf8) })")
        #expect(afterRepair.map { ScalarText($0.name) } == [ScalarText(decomposed)])
        #expect(afterRepair.first?.reason == "x-mcp-header on a non-primitive property")
        let complete = try await client.listTools()
        #expect(complete.items.map { ScalarText($0.name) } == [ScalarText(composed)])
        #expect(await client.rejectedTools.isEmpty)
        #expect(await transport.remaining == 0)
    }
}
