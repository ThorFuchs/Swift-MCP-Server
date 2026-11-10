// SPDX-License-Identifier: Apache-2.0
import Testing
import JSON
import MCPProtocol

@Suite struct S07WireDirection {
    @Test(arguments: ["roots/list", "elicitation/create", "sampling/createMessage"])
    func MRTRInputMethodsCannotEnterAsStandaloneClientRequests(method: String) throws {
        let bytes = Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}".utf8)
        let raw = try WireCodec.parse(bytes, limits: .balanced).result
        #expect(WireMethod(rawValue: method)?.leg == .inputRequest)
        #expect(throws: WireFailure.forbiddenDirection) { try EnvelopeProjection.decode(raw) }
        #expect(!EnvelopeProjection.isNotification(raw))
    }

    @Test(arguments: [#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"failure"}}"#,
        #"[{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}]"#])
    func responseLikeEnvelopesAndBatchesAreInvalidRatherThanSilentNotifications(text: String) throws {
        let raw = try WireCodec.parse(Array(text.utf8), limits: .balanced).result
        #expect(!EnvelopeProjection.isNotification(raw))
        #expect(throws: WireFailure.invalidRequest) { try EnvelopeProjection.decode(raw) }
        // Typed projection only. D01 reply election and recognizable malformed
        // notification silence retain their separate existing core tests.
    }
}
