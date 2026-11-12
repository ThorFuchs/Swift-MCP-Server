// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }

/// Answers every request with the same result body (the request's id is kept).
private struct FixedResultTransport: ClientTransport {
    let result: String
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let id = try #require(try json(String(decoding: request.body, as: UTF8.self)).objectValue?["id"])
        let reply = JSON.object(try JSONObject(members: [JSONMember("jsonrpc", value: .string("2.0")), JSONMember("id", value: id),
                                                         JSONMember("result", value: try json(result))]))
        try await receive(try WireCodec.write(reply, limits: .balanced).result)
    }
}
/// Sends a frame that is not a valid response for the request.
private struct RawTransport: ClientTransport {
    let frames: [String]
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        for frame in frames { try await receive(Data(frame.utf8)) }
    }
}

@Suite struct InvalidServerOutputCases {
    @Test(arguments: [
        ("tools/list", #"{"resultType":"complete","tools":[{"name":"x"}],"ttlMs":0,"cacheScope":"private"}"#),          // no inputSchema
        ("tools/list", #"{"resultType":"complete","tools":[]}"#),                                                       // no cache fields
        ("resources/list", #"{"resultType":"complete","resources":[{"uri":1}],"ttlMs":0,"cacheScope":"private"}"#),
        ("prompts/list", #"{"resultType":"complete","prompts":"no","ttlMs":0,"cacheScope":"private"}"#),
        ("server/discover", #"{"resultType":"complete","supportedVersions":["2026-07-28"]}"#),                            // no capabilities
        ("tools/call", #"{"resultType":"complete","content":"text"}"#),
        ("resources/read", #"{"resultType":"complete","contents":[{"text":"no uri"}]}"#),
        ("tools/call", #"{"resultType":"input_required","inputRequests":{"a":{"method":"unknown/method"}}}"#),
    ])
    func invalidResultsAreRejectedForEveryMethod(_ method: String, _ result: String) async throws {
        let client = Client(transport: FixedResultTransport(result: result), configuration: .init(
            elicitation: .init { _ in try json(#"{"action":"cancel"}"#) }))
        await #expect(throws: ClientError.self) {
            switch method {
            case "tools/list": _ = try await client.listTools()
            case "resources/list": _ = try await client.listResources()
            case "prompts/list": _ = try await client.listPrompts()
            case "server/discover": _ = try await client.discover()
            case "resources/read": _ = try await client.readResource("file:///a")
            default: _ = try await client.callTool("x")
            }
        }
    }

    @Test(arguments: [
        [#"not json"#],
        [#"{"jsonrpc":"2.0","id":999,"result":{}}"#],                                       // another request's response
        [#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":"x"}}"#],
        [],                                                                                    // no response at all
    ])
    func malformedFramesNeverReachTheCaller(_ frames: [String]) async throws {
        await #expect(throws: (any Error).self) { _ = try await Client(transport: RawTransport(frames: frames)).listTools() }
    }
}
