// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import Testing

private func plan(_ name: FrozenWireDefinition) throws -> WireDefinitionPlan {
    let document = try FrozenWireSchema.parse(FrozenWireSchema.read(maximumBytes: 262_144), limits: .balanced).result
    return try WireDefinitionPlan.compile(document.root(at: name, limits: .balanced).result, limits: .balanced).result
}

@Test func datedResultRequirementsBeyondGeneratedSchema() throws {
    let input = try plan(.InputRequiredResult)
    #expect(try input.validate(JSONParser().parse(#"{"resultType":"input_required","requestState":"x"}"#), limits: .balanced).result)
    #expect(try !input.validate(JSONParser().parse(#"{"resultType":"input_required"}"#), limits: .balanced).result)
    #expect(try !input.validate(JSONParser().parse(#"{"resultType":"complete","requestState":"x"}"#), limits: .balanced).result)
    let call = try plan(.CallToolResultResponse)
    #expect(try !call.validate(JSONParser().parse(#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required"}}"#), limits: .balanced).result)
    let completion = try plan(.CompleteResult)
    let invalid = "{\"resultType\":\"complete\",\"completion\":{\"values\":[" + Array(repeating: "\"x\"", count: 101).joined(separator: ",") + "]}}"
    #expect(try !completion.validate(JSONParser().parse(invalid), limits: .balanced).result)
}

@Test func modernErrorPayloadsHaveFrozenCodesAndData() throws {
    let unsupported = try ErrorEnvelope.make(.unsupportedVersion(requested: ScalarText("unsupported")), id: RequestID(.string("id")), limits: .balanced).result
    #expect(try plan(.UnsupportedProtocolVersionError).validate(unsupported, limits: .balanced).result)
    let capsPlan = try plan(.ClientCapabilities)
    let caps = try #require(capsPlan.project(JSONParser().parse(#"{"sampling":{}}"#), as: MCPWire.ClientCapabilities.self, limits: .balanced).result)
    let missing = try ErrorEnvelope.make(.missingCapability(required: caps), id: RequestID(.string("id")), limits: .balanced).result
    #expect(try plan(.MissingRequiredClientCapabilityError).validate(missing, limits: .balanced).result)
    let unknown = try ErrorEnvelope.make(code: .invalidRequest, id: nil, limits: .balanced).result
    #expect(unknown.objectValue?["id"] == .null)
    #expect(throws: WireFailure.invalidParams) { try ErrorEnvelope.make(code: .missingCapability, id: nil, limits: .balanced) }
}

@Test func metadataNamesAndMandatoryExtensionPrefixesFollowDatedAuthority() throws {
    let meta = try plan(.MetaObject)
    #expect(try meta.validate(JSONParser().parse(#"{"com.example/details":{"é":1,"e\u0301":2},"traceparent":"00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"}"#), limits: .balanced).result)
    for invalid in [#"{"é":1}"#, #"{"com..example/key":1}"#, #"{"bad_":1}"#, #"{"good\n":1}"#] {
        #expect(try !meta.validate(JSONParser().parse(invalid), limits: .balanced).result)
    }
    let caps = try plan(.ClientCapabilities)
    #expect(try caps.validate(JSONParser().parse(#"{"extensions":{"com.example/feature":{}}}"#), limits: .balanced).result)
    #expect(try !caps.validate(JSONParser().parse(#"{"extensions":{"unprefixed":{}}}"#), limits: .balanced).result)
}
