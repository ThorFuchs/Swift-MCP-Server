// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
@testable import MCPClient
import Testing

@Suite(.serialized) struct ClientDynamicSchemaRetentionCases {
    @Test func schemaChurnAcrossCountCeilingNeverBypassesValidation() async throws {
        let frozen = ClientFrozenWirePlanCache()
        let validator = WireValidator(frozenPlans: frozen)
        let invalid = try JSONParser().parse(#"{"value":-1}"#)
        // 257 distinct small valid schemas cross the source's 256-entry ceiling.
        // Observe correctness, not private dictionary size or process memory.
        for i in 0...256 {
            let schema = try JSONParser().parse(#"{"type":"object","required":["value"],"properties":{"value":{"type":"integer","const":\#(i)}},"additionalProperties":false}"#)
            let valid = try JSONParser().parse(#"{"value":\#(i)}"#)
            let accepted = try await validator.conforms(valid, to: schema)
            let rejected = try await validator.conforms(invalid, to: schema)
            #expect(accepted, "schema \(i)")
            #expect(!rejected, "schema \(i)")
        }
        let first = try JSONParser().parse(#"{"type":"object","required":["value"],"properties":{"value":{"type":"integer","const":0}},"additionalProperties":false}"#)
        let zero = try JSONParser().parse(#"{"value":0}"#)
        #expect(try await validator.conforms(zero, to: first))
        #expect(try await !validator.conforms(invalid, to: first))
        let snapshot = await frozen.snapshot
        #expect(!snapshot.documentCached && snapshot.definitions == 0 && snapshot.compilations == 0 && snapshot.hits == 0)
    }

    @Test func failedDynamicPreparationDoesNotPoisonWarmValidSchema() async throws {
        let validator = WireValidator(frozenPlans: ClientFrozenWirePlanCache())
        let schema = try JSONParser().parse(#"{"type":"object","required":["value"],"properties":{"value":{"type":"integer"}}}"#)
        let remote = try JSONParser().parse(#"{"$ref":"https://schemas.example.invalid/probe.json"}"#)
        let valid = try JSONParser().parse(#"{"value":1}"#)
        let invalid = try JSONParser().parse(#"{"value":"wrong"}"#)
        #expect(try await validator.conforms(valid, to: schema))
        for _ in 0..<2 {
            do {
                _ = try await validator.conforms(valid, to: remote)
                Issue.record("offline compilation failure was bypassed")
            } catch ClientError.invalidResponse(_) {
            } catch { Issue.record("unexpected error: \(error)") }
            #expect(try await validator.conforms(valid, to: schema))
            #expect(try await !validator.conforms(invalid, to: schema))
        }
    }
}
