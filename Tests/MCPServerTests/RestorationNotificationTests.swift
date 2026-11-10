// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

enum StateFixture {
    static func json(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
    static let principal = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
    static let origin = ScalarText("origin")
    static func cursors() throws -> CursorProtector {
        try .init(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 7, count: 32))], active: ScalarText("test"), epoch: ScalarText("test"), clock: { 1000 })
    }
    static func make(_ catalog: ServerCatalog, configuration: ServerConfiguration? = nil) async throws -> Server {
        try await Server.make(info: json(#"{"name":"recovery-tests","version":"0.1"}"#), catalog: catalog, cursors: cursors(), configuration: configuration)
    }
    static func clean(_ server: Server) async {
        let s = await server.activity
        #expect(s.active == 0 && s.queued == 0 && s.requests == 0 && s.leases == 0 && s.bufferedBytes == 0)
    }
    static func request(_ method: String, fields: String = "", id: String = "1", capabilities: String = "{}", metadata: String = "") -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":\(capabilities)\(metadata)}\(fields)}}".utf8)
    }
    static func response(_ server: Server, _ request: Data, principal: VerifiedPrincipal = principal) async throws -> JSON {
        let data = try #require(await server.handle(request, principal: principal, origin: origin))
        return try JSONParser().parseWithReport(Array(data)).result
    }
}

@Suite(.serialized) struct NotificationSilenceCases {
    @Test func recognizableNotificationsNeverAttemptResponses() async throws {
        let calls = Mutex(0)
        let tool = ToolRegistration(definition: try StateFixture.json(#"{"name":"count","inputSchema":{"type":"object"}}"#)) { _, _ in
            calls.withLock { $0 += 1 }
            return try StateFixture.json(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await StateFixture.make(ServerCatalog(tools: [tool]))
        let cases = [
            #"{"jsonrpc":"2.0","method":"com.example/unsupported","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"count"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":[]}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"absent","reason":42}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"absent"}}"#,
        ]
        for text in cases {
            let attempts = Mutex(0)
            try await server.dispatch(Data(text.utf8), principal: StateFixture.principal, origin: StateFixture.origin) { _ in attempts.withLock { $0 += 1 } }
            #expect(attempts.withLock { $0 } == 0, "Notification must have zero response attempts: \(text)")
            await StateFixture.clean(server)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func invalidEnvelopesKeepD01ErrorAttempts() async throws {
        let server = try await StateFixture.make(ServerCatalog())
        for text in ["{}", "[]", "{bad", #"{"jsonrpc":"1.0","method":"unknown"}"#, #"{"jsonrpc":"2.0","method":"unknown","id":null}"#, #"{"jsonrpc":"2.0","method":7}"#, #"{"jsonrpc":"2.0","method":"unknown","result":{}}"#] {
            let data = try #require(await server.handle(Data(text.utf8), principal: StateFixture.principal, origin: StateFixture.origin))
            let value = try JSONParser().parseWithReport(Array(data)).result
            #expect(value.objectValue?["id"]?.isNull == true)
            #expect(value.objectValue?["error"] != nil)
            await StateFixture.clean(server)
        }
    }
}
