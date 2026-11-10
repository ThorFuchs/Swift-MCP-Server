// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
import JSON
import MCPProtocol

@Test func frozenDefinitionWitnessesAndNegativeTypes() throws {
    let bytes = try FrozenWireSchema.read(maximumBytes: 262_144)
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == FrozenWireSchema.sha256)
    let document = try FrozenWireSchema.parse(bytes, limits: .balanced).result
    let url = try #require(Bundle.module.url(forResource: "wire-witnesses", withExtension: "json", subdirectory: "Resources"))
    let witnesses = try JSONParser().parse(Data(contentsOf: url)).arrayValue!
    #expect(witnesses.count == 155)
    for witness in witnesses {
        let row = witness.objectValue!
        let definition = FrozenWireDefinition(rawValue: row["definition"]!.stringValue!)!
        let root = try document.root(at: definition, limits: .balanced).result
        let plan = try WireDefinitionPlan.compile(root, limits: .balanced).result
        #expect(try checkedWitness(plan, row["positive"]!), "positive \(definition)")
        #expect(try !checkedWitness(plan, row["negative"]!), "negative \(definition)")
    }
}

@Test func registryDefinitionAndResultDirections() {
    #expect(WireMethod.allCases.count == 21)
    #expect(WireMethod.allCases.filter { $0.leg == .clientRequest }.count == 10)
    #expect(WireMethod.allCases.filter { $0.leg == .inputRequest }.count == 3)
    #expect(WireMethod.allCases.filter { $0.leg == .serverNotification }.count == 8)
    for method in WireMethod.allCases {
        #expect(method.definition.rawValue.hasSuffix(method.leg == .serverNotification ? "Notification" : "Request"))
        #expect((method.resultDefinition == nil) == (method.leg == .serverNotification))
    }
}

@Test func wrongProjectionAndUntrustedSchemaCannotEnterCheckedModel() throws {
    #expect(throws: WireFailure.invalidRequest) { try FrozenWireSchema.parse(Data("{}".utf8), limits: .balanced) }
    let document = try FrozenWireSchema.parse(FrozenWireSchema.read(maximumBytes: 262_144), limits: .balanced).result
    let plan = try WireDefinitionPlan.compile(document.root(at: .TextContent, limits: .balanced).result, limits: .balanced).result
    let value = try JSONParser().parse(#"{"type":"text","text":"hello","_meta":{"com.example/details":{"é":1,"e\u0301":2}}}"#)
    let projected = try #require(plan.project(value, as: MCPWire.TextContent.self, limits: .balanced).result)
    #expect(try JSONComparison.equals(value, JSONParser().parse(projected.write(limits: .balanced).result), limits: .balanced))
    #expect(throws: WireFailure.invalidParams) { try plan.project(value, as: MCPWire.AudioContent.self, limits: .balanced) }
    var tiny = JSONLimits.balanced; tiny[.workUnits] = 1
    #expect(throws: (any Error).self) { try plan.validate(value, limits: tiny) }
}
