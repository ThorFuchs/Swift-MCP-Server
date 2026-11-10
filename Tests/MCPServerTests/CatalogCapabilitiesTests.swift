// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import Testing
import MCPProtocol
import MCPServer

@Test func catalogListChangeAdvertisementIsExplicitAndGenerationCoherent() async throws {
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerCatalog(listChanged: [.callTool]) }
    func parse(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
    let server = try await Server.make(info: parse(#"{"name":"capabilities","version":"1"}"#), catalog: ServerCatalog(),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 1, count: 32))], active: ScalarText("test"), clock: { 1000 }))
    let principal = VerifiedPrincipal(subject: ScalarText("test"), issuer: ScalarText("test"), resource: ScalarText("mcp"), scopes: [])
    let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
    func capabilities() async throws -> JSONObject {
        let response = try await server.handle(bytes, principal: principal, origin: ScalarText("test"))
        let value = try WireCodec.parse(Array(try #require(response)), limits: .balanced).result
        return try #require(value.objectValue?["result"]?.objectValue?["capabilities"]?.objectValue)
    }
    #expect(try await capabilities()["tools"]?.objectValue?["listChanged"] == nil)
    let previous = await server.activity.generation
    try await server.replaceCatalog(ServerCatalog(listChanged: [.listTools, .listPrompts]))
    let announced = try await capabilities()
    #expect(announced["tools"]?.objectValue?["listChanged"]?.booleanValue == true)
    #expect(announced["prompts"]?.objectValue?["listChanged"]?.booleanValue == true)
    #expect(announced["resources"]?.objectValue?["listChanged"] == nil)
    #expect(await server.activity.generation == previous + 1)
    let activity = await server.activity
    #expect(activity.active == 0 && activity.leases == 0)
}
