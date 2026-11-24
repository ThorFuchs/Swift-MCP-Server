// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
@testable import MCPServer
import Testing

@Suite struct CatalogReplacementReuse {
    private func json(_ text: String) throws -> JSON {
        try WireCodec.parse(Array(text.utf8), limits: .balanced).result
    }

    @Test func exactSchemaReuseChargesWorkAndRebindsGeneration() async throws {
        let raw = try json(#"{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}},"required":["region"]}"#)
        let original = try await SchemaPreparation.prepare(raw, identifier: 7, budget: ServerPreparationPolicy().budget())
        let budget = try ServerPreparationPolicy().budget()
        let compilationBefore = await budget.remaining(.compilation)
        let replacement = try await SchemaPreparation.prepareReplacement(raw, previous: original, identifier: 8, budget: budget)
        #expect(replacement.identifier == 8 && original.identifier == 7)
        #expect(replacement.raw == raw && replacement.logicalRetainedUpperBound == original.logicalRetainedUpperBound)
        #expect(await budget.remaining(.compilation) == compilationBefore)
        #expect(await budget.snapshot.settledWork >= original.logicalRetainedUpperBound)
        #expect(await budget.snapshot.activeReservations == 0)
        #expect(try await SchemaPreparation.validate(json(#"{"region":"Berlin"}"#), against: replacement, budget: budget))
        #expect(try await !SchemaPreparation.validate(json(#"{"region":4}"#), against: replacement, budget: budget))
        #expect(try await SchemaPreparation.headers(for: replacement, budget: budget).count == 1)
    }

    @Test func changedSchemaCompilesAndDoesNotUseOldValidation() async throws {
        let old = try json(#"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}"#)
        let new = try json(#"{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}"#)
        let original = try await SchemaPreparation.prepare(old, identifier: 1, budget: ServerPreparationPolicy().budget())
        let budget = try ServerPreparationPolicy().budget()
        let before = await budget.remaining(.compilation)
        let updated = try await SchemaPreparation.prepareReplacement(new, previous: original, identifier: 2, budget: budget)
        #expect(await budget.remaining(.compilation) < before)
        #expect(updated.raw == new && updated.identifier == 2)
        #expect(try await SchemaPreparation.validate(json(#"{"value":4}"#), against: updated, budget: budget))
        #expect(try await !SchemaPreparation.validate(json(#"{"value":"old"}"#), against: updated, budget: budget))
        #expect(try await SchemaPreparation.validate(json(#"{"value":"old"}"#), against: original, budget: budget))
    }

    @Test func replacementCannotReuseAcrossExhaustedPreparationAccount() async throws {
        let raw = try json(#"{"type":"object"}"#)
        let original = try await SchemaPreparation.prepare(raw, identifier: 1, budget: ServerPreparationPolicy().budget())
        let tiny = try RequestBudget(workUnits: 1)
        await #expect(throws: (any Error).self) {
            _ = try await SchemaPreparation.prepareReplacement(raw, previous: original, identifier: 2, budget: tiny)
        }
        let settled = await tiny.snapshot
        #expect(settled.isTerminal && settled.activeReservations == 0)
    }

    @Test func replacingToolWithSameSchemaUsesNewProviderAndScope() async throws {
        let definition = try json(#"{"name":"replaceable","inputSchema":{"type":"object"}}"#)
        let old = try json(#"{"resultType":"complete","content":[{"type":"text","text":"old"}]}"#)
        let new = try json(#"{"resultType":"complete","content":[{"type":"text","text":"new"}]}"#)
        let original = ToolRegistration(definition: definition) { _, _ in old }
        let next = ToolRegistration(definition: definition, requiredScopes: [ScalarText("new-scope")]) { _, _ in new }
        let server = try await StateFixture.make(ServerCatalog(tools: [original]))
        let request = StateFixture.request("tools/call", fields: #", "name":"replaceable","arguments":{}"#)
        let first = try await StateFixture.response(server, request)
        #expect(first.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "old")
        let generation = await server.activity.generation
        try await server.replaceCatalog(ServerCatalog(tools: [next]))
        #expect(await server.activity.generation == generation + 1)
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await StateFixture.response(server, request)
        }
        let p = StateFixture.principal
        let authorized = VerifiedPrincipal(subject: p.subject, issuer: p.issuer, resource: p.resource, scopes: [ScalarText("new-scope")])
        let second = try await StateFixture.response(server, request, principal: authorized)
        #expect(second.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "new")
        await StateFixture.clean(server)
    }
}
