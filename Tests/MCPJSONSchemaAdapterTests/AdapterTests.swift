// SPDX-License-Identifier: Apache-2.0
import Testing
import JSON
import JSONSchema
import MCPJSONSchemaAdapter

@Test func adapterRetainsBooleanVerdictsAndOperationalErrors() throws {
    let falsePlan = try SchemaCompilerAdapter.compile(.boolean(false), limits: .conservative)
    #expect(try !SchemaValidatorAdapter.validate(.null, against: falsePlan.result, limits: .conservative).result.isValid)
    #expect(throws: JSONSchemaCompilationFailure.self) { try SchemaCompilerAdapter.compile(.null, limits: .conservative) }
    let ref = try JSONParser().parse(#"{"$ref":"https://unavailable.invalid/resource"}"#)
    #expect(throws: JSONSchemaCompilationFailure.self) { try SchemaCompilerAdapter.compile(ref, limits: .conservative) }
    var tiny = JSONLimits.conservative; tiny[.evaluationWorkUnits] = 0
    #expect(throws: JSONFailure.self) { try SchemaValidatorAdapter.validate(.null, against: falsePlan.result, limits: tiny) }
}
@Test func rawInspectionPreservesUnknownMetadataWithoutEffectiveInference() throws {
    let raw = try JSONParser().parse(#"{"type":"object","properties":{"x":{"type":"string","x-mcp-header":"X","org.example/note":null}},"default":{"x":"default"}}"#)
    let document = try JSONSchemaDocument(raw)
    let view = try SchemaInspectionAdapter.inspect(document, at: JSONPointer(tokens: ["properties", "x"]), limits: .conservative)
    #expect(view.result.declaredAnnotations.presence(of: "x-mcp-header") == .value("X"))
    #expect(view.result.declaredAnnotations.presence(of: "org.example/note") == .null)
    #expect(view.statistics.accountingVersion == 1 && view.statistics[.workUnits] > 0)
    #expect(view.result.referenceTargets == nil)
}
@Test func dynamicReferenceAndUnevaluatedStateRemainUpstreamOwned() throws {
    let raw = try JSONParser().parse(##"{"$dynamicAnchor":"node","type":"object","properties":{"child":{"$dynamicRef":"#node"}},"unevaluatedProperties":false}"##)
    let plan = try SchemaCompilerAdapter.compile(raw, limits: .balanced).result
    let valid = try JSONParser().parse(#"{"child":{"child":{}}}"#)
    let invalid = try JSONParser().parse(#"{"child":{"extra":1}}"#)
    #expect(try SchemaValidatorAdapter.validate(valid, against: plan, limits: .balanced).result.isValid)
    #expect(try !SchemaValidatorAdapter.validate(invalid, against: plan, limits: .balanced).result.isValid)
}
