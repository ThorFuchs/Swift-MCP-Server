// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPProtocol
import JSON

@Test func resourceNotFoundErrorKeepsExactURIAndIDWithoutChangingD01() throws {
    let uri = ScalarText("test://missing/世界?query=\"x\"")
    let id = RequestID.integer(JSONNumber(integer: Int64(9_007_199_254_740_993)))
    let value = try ErrorEnvelope.make(.resourceNotFound(uri: uri), id: id, limits: .balanced).result
    #expect(value.objectValue?["id"] == id.value)
    #expect(value.objectValue?["error"]?.objectValue?["data"]?.objectValue?["uri"]?.stringValue == uri.description)
    #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
    #expect(throws: WireFailure.limit) { _ = try ErrorEnvelope.make(.resourceNotFound(uri: ScalarText(String(repeating: "x", count: 4097))), id: id, limits: .balanced) }
    let unknown = try ErrorEnvelope.make(.standard(.invalidRequest), id: nil, limits: .balanced).result
    #expect(unknown.objectValue?["id"] == .null && unknown.objectValue?["error"]?.objectValue?["data"] == nil)
}
