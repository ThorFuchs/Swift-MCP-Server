// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }

/// A server scripted per method (and tool name); records request bodies.
private final class ScriptedServer: ClientTransport, Sendable {
    let script: @Sendable (_ method: String, _ name: String?, _ params: JSONObject?) -> String
    private let bodies = Mutex<[JSON]>([])
    init(_ script: @escaping @Sendable (String, String?, JSONObject?) -> String) { self.script = script }
    var requests: [JSON] { bodies.withLock { $0 } }

    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try json(String(decoding: request.body, as: UTF8.self))
        bodies.withLock { $0.append(body) }
        let id = try body.objectValue?["id"]?.numberValue?.integer(as: Int.self) ?? 0
        let result = script(request.method, request.name, body.objectValue?["params"]?.objectValue)
        try await receive(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
    }
}

private let tools = #"""
{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[
 {"name":"weather","inputSchema":{"type":"object"},
  "outputSchema":{"type":"object","required":["temperature"],"properties":{"temperature":{"type":"number"}},"additionalProperties":false}},
 {"name":"remote","inputSchema":{"type":"object"},"outputSchema":{"$ref":"https://schemas.example/weather.json"}},
 {"name":"plain","inputSchema":{"type":"object"}}]}
"""#

private func call(_ structured: String?, isError: Bool = false) -> String {
    let content = #""content":[{"type":"text","text":"x"}]"#
    return "{\"resultType\":\"complete\",\(content)\(structured.map { ",\"structuredContent\":\($0)" } ?? "")\(isError ? ",\"isError\":true" : "")}"
}

@Suite struct SchemaValidationCases {
    @Test func structuredContentIsCheckedAgainstTheToolsOutputSchema() async throws {
        let answers = Mutex<[String: String]>([:])
        let server = ScriptedServer { method, name, _ in
            method == "tools/list" ? tools : answers.withLock { $0[name ?? ""] ?? call(nil) }
        }
        let client = Client(transport: server)
        _ = try await client.listTools()

        answers.withLock { $0["weather"] = call(#"{"temperature":21.5}"#) }
        #expect(try await client.callTool("weather").structuredContent != nil)
        // Wrong type, extra property, missing structuredContent: all rejected.
        for wrong in [call(#"{"temperature":"warm"}"#), call(#"{"temperature":1,"wind":3}"#), call(nil)] {
            answers.withLock { $0["weather"] = wrong }
            await #expect(throws: ClientError.self) { _ = try await client.callTool("weather") }
        }
        // Tool errors carry no structured output obligation.
        answers.withLock { $0["weather"] = call(nil, isError: true) }
        #expect(try await client.callTool("weather").isError)
        // Tools without an outputSchema are not checked.
        answers.withLock { $0["plain"] = call(#"{"anything":true}"#) }
        #expect(try await client.callTool("plain").structuredContent != nil)
        // A schema that needs a remote document is an error, not a skipped check.
        answers.withLock { $0["remote"] = call(#"{"temperature":1}"#) }
        await #expect(throws: ClientError.self) { _ = try await client.callTool("remote") }

        // The check can be turned off.
        var configuration = ClientConfiguration()
        configuration.validatesStructuredContent = false
        let lenient = Client(transport: server, configuration: configuration)
        _ = try await lenient.listTools()
        answers.withLock { $0["weather"] = call(#"{"temperature":"warm"}"#) }
        #expect(try await lenient.callTool("weather").structuredContent != nil)
    }

    @Test func acceptedElicitationContentMustMatchTheRequestedSchema() async throws {
        let inputRequired = #"""
        {"resultType":"input_required","inputRequests":{"name":{"method":"elicitation/create","params":{"mode":"form","message":"Your name?",
         "requestedSchema":{"type":"object","required":["name"],"properties":{"name":{"type":"string","minLength":1}}}}}}}
        """#
        let server = ScriptedServer { _, _, params in
            params?["inputResponses"] == nil ? inputRequired : call(nil)
        }
        let content = Mutex(#"{"name":""}"#)
        let client = Client(transport: server, configuration: .init(elicitation: .init { _ in
            .accept(content: try json(content.withLock { $0 }).objectValue)
        }))
        await #expect(throws: ClientError.self) { _ = try await client.callTool("ask") }
        #expect(server.requests.count == 1)   // the invalid answer was never sent

        content.withLock { $0 = #"{"name":"Ada"}"# }
        _ = try await client.callTool("ask")
        let sent = server.requests.last?.objectValue?["params"]?.objectValue?["inputResponses"]?.objectValue?["name"]
        #expect(sent?.objectValue?["content"]?.objectValue?["name"]?.stringValue == "Ada")

        // Declined elicitations carry no content to check.
        let declining = Client(transport: server, configuration: .init(elicitation: .init { _ in .decline }))
        _ = try await declining.callTool("ask")
    }
}
