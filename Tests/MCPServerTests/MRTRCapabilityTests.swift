// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import Testing
import MCPProtocol
import MCPServer

@Test func frozenEmptyElicitationCapabilityMeansFormAndURLOnlyDoesNot() async throws {
    func parse(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
    let descriptor = InputDescriptor(identifier: ScalarText("answer"), request: try parse(#"{"method":"elicitation/create","params":{"message":"test","requestedSchema":{"type":"object","properties":{}}}}"#))
    let rounds = MultiRoundProvider(version: ScalarText("1"), inputs: [descriptor], inputOnlyReconstruction: [descriptor.identifier], replay: .integrityOnly) { _, _, _ in
        .inputRequired(.init(inputs: [descriptor.identifier], inputOnly: true))
    }
    let tool = ToolRegistration(definition: try parse(#"{"name":"elicit","inputSchema":{"type":"object"}}"#), rounds: rounds)
    let server = try await Server.make(info: parse(#"{"name":"capability-test","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 1, count: 32))], active: ScalarText("test"), clock: { 1000 }))
    let principal = VerifiedPrincipal(subject: ScalarText("test"), issuer: ScalarText("test"), resource: ScalarText("mcp"), scopes: [])
    for (caps, supported) in [(#"{"elicitation":{}}"#, true), (#"{"elicitation":{"form":{}}}"#, true), (#"{"elicitation":{"url":{}}}"#, false), ("{}", false)] {
        let bytes = Data("""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"elicit","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":\(caps)}}}
        """.utf8)
        let response = try await server.handle(bytes, principal: principal, origin: ScalarText("test"))
        let value = try WireCodec.parse(Array(try #require(response)), limits: .balanced).result
        if supported { #expect(value.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?["answer"] != nil) }
        else { #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32021) }
    }
    #expect(await server.activity.active == 0)
}
