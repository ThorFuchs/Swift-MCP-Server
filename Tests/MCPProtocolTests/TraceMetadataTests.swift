// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import Testing

private let traceID = "0af7651916cd43dd8448eb211c80319c"
private let parentID = "00f067aa0ba902b7"
private let validParent = "00-" + traceID + "-" + parentID + "-01"
private func tracePlan(_ definition: FrozenWireDefinition = .MetaObject) throws -> WireDefinitionPlan {
    let document = try FrozenWireSchema.parse(FrozenWireSchema.read(maximumBytes: 262_144), limits: .balanced).result
    return try WireDefinitionPlan.compile(document.root(at: definition, limits: .balanced).result, limits: .balanced).result
}
private func traceObject(_ key: String, _ value: JSON) throws -> JSON {
    try JSONParser().parseWithReport(Array(("{\"" + key + "\":" + String(decoding: JSONWriter().writeWithReport(value).result, as: UTF8.self) + "}").utf8)).result
}

@Test func traceparentRejectsInvalidVersionIDsTypesAndTrailingControl() throws {
    let plan = try tracePlan()
    for text in ["", validParent.uppercased(), "ff-" + traceID + "-" + parentID + "-01",
        "00-" + String(repeating: "0", count: 32) + "-" + parentID + "-01",
        "00-" + traceID + "-" + String(repeating: "0", count: 16) + "-01",
        validParent + "-extra", validParent + "\n", " " + validParent, String(validParent.dropLast()), validParent + "g"] {
        #expect(try !plan.validate(traceObject("traceparent", .string(text)), limits: .balanced).result, "traceparent: \(text)")
    }
    for value in [JSON.null, .boolean(true), .number(JSONNumber(integer: 1)), .array([])] {
        #expect(try !plan.validate(traceObject("traceparent", value), limits: .balanced).result)
    }
}

@Test func traceValuesRetainFutureFieldsUnknownFlagsAndExactBytes() throws {
    let plan = try tracePlan()
    for text in [validParent, "00-" + traceID + "-" + parentID + "-fe",
        "01-" + traceID + "-" + parentID + "-ff",
        "fe-" + traceID + "-" + parentID + "-01-opaque-vendor"] {
        let input = try traceObject("traceparent", .string(text))
        let projected = try #require(plan.project(input, as: MCPWire.MetaObject.self, limits: .balanced).result)
        #expect(projected.value.objectValue?["traceparent"]?.stringValue?.utf8.elementsEqual(text.utf8) == true)
    }
    #expect(try plan.validate(traceObject("com.example/traceparent", .null), limits: .balanced).result)
}

@Test func tracestateHonorsKeyValueUniquenessAndListBoundaries() throws {
    let plan = try tracePlan()
    for text in ["", "\t ", ",", " , vendor=opaque\t, ", "0tenant@vendor=value", "vendor= a b ", "a/b=ASCII=invalid"] {
        let valid = text != "a/b=ASCII=invalid"
        #expect(try plan.validate(traceObject("tracestate", .string(text)), limits: .balanced).result == valid)
    }
    let atLimit = (0..<32).map { "v\($0)=x" }.joined(separator: ",")
    #expect(try plan.validate(traceObject("tracestate", .string(atLimit)), limits: .balanced).result)
    for text in [atLimit + ",v32=x", "a=x,a=y", "a=x,,b=y, a=z", "A=x", "0vendor=x", "a=", "a=x=y", "a=é", "a=x\n",
        String(repeating: "a", count: 257) + "=x", "a=" + String(repeating: "x", count: 257), "a@" + String(repeating: "b", count: 15) + "=x"] {
        #expect(try !plan.validate(traceObject("tracestate", .string(text)), limits: .balanced).result, "tracestate: \(text)")
    }
    #expect(try plan.validate(traceObject("tracestate", .string(String(repeating: "a", count: 256) + "=" + String(repeating: "x", count: 256))), limits: .balanced).result)
}

@Test func baggagePreservesDuplicatesPropertiesEscapesAndEquals() throws {
    let plan = try tracePlan()
    for text in ["key=", "key=a=b=c", " key = value ;p1;p2=two\t", "key=one,key=two", "key=Am%C3%A9lie;prop=%25", "key=%ff", "p%=value"] {
        let input = try traceObject("baggage", .string(text))
        let projected = try #require(plan.project(input, as: MCPWire.MetaObject.self, limits: .balanced).result)
        #expect(projected.value.objectValue?["baggage"]?.stringValue?.utf8.elementsEqual(text.utf8) == true)
    }
    for text in ["", "key", "=value", "key=two words", "key=é", "key=\"quoted\"", "key=%", "key=%2", "key=%xz", "key=x\\y", "key=x;", "key=x\n", "key=x,"] {
        #expect(try !plan.validate(traceObject("baggage", .string(text)), limits: .balanced).result, "baggage: \(text)")
    }
    let atLimit = Array(repeating: "a=x", count: 180).joined(separator: ",")
    #expect(try plan.validate(traceObject("baggage", .string(atLimit)), limits: .balanced).result)
    #expect(try !plan.validate(traceObject("baggage", .string(atLimit + ",a=x")), limits: .balanced).result)
}

@Test func allMetadataShapesEnforceReservedValueTypes() throws {
    for definition: FrozenWireDefinition in [.MetaObject, .RequestMetaObject, .ResultMetaObject, .NotificationMetaObject, .SubscriptionsListenResultMetaObject] {
        let plan = try tracePlan(definition)
        let extra: String
        if definition == .RequestMetaObject { extra = #", "io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}"# }
        else if definition == .SubscriptionsListenResultMetaObject { extra = #", "io.modelcontextprotocol/subscriptionId":0"# }
        else { extra = "" }
        for key in ["traceparent", "tracestate", "baggage"] {
            let input = try JSONParser().parse("{\"\(key)\":null\(extra)}")
            #expect(try !plan.validate(input, limits: .balanced).result)
        }
    }
}

@Test func traceValidationReportsMeteredRegexWorkAndDoesNotSwallowExhaustion() throws {
    let plan = try tracePlan()
    let value = try traceObject("tracestate", .string("a=x,b=y,a=z"))
    let report = try plan.validate(value, limits: .balanced)
    #expect(!report.result && report.statistics[.aggregateRegexWorkUnits] > 0)
    var limits = JSONLimits.balanced
    limits[.aggregateRegexWorkUnits] = 1
    #expect(throws: JSONFailure.self) { try plan.validate(value, limits: limits) }
}
