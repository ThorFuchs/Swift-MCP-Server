// SPDX-License-Identifier: Apache-2.0
import Synchronization
import Testing
import JSON
import JSONSchema
import MCPJSONSchemaAdapter

private func s07SchemaJSON(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private func s07DeclaredHeaders(_ raw: JSON) async throws -> [String] {
    let document = try JSONSchemaDocument(raw), charged = Mutex(UInt64(0))
    let declarations = try await HeaderDeclarations.scan(document, charge: { amount in
        try charged.withLock { value in
            guard amount <= 8_000_000 - value else { throw HeaderDeclarationFailure.traversalLimit }
            value += amount
        }
    }, inspect: { path in
        try SchemaInspectionAdapter.inspect(document, at: JSONPointer(tokens: path), limits: .balanced).result
    })
    return declarations.map(\.name).sorted()
}

@Suite struct S07SchemaBoundaries {
    @Test func ordinaryInvalidAndOperationalFailureDoNotMutateTheImmutablePlan() throws {
        let raw = try s07SchemaJSON(#"{"type":"integer"}"#)
        let report = try SchemaCompilerAdapter.compile(raw, limits: .balanced)
        #expect(report.result.document.raw == raw)
        let invalid = try SchemaValidatorAdapter.validate(.string("wrong"), against: report.result, limits: .balanced)
        #expect(!invalid.result.isValid && invalid.statistics[.workUnits] > 0)
        var noEvaluation = JSONLimits.balanced; noEvaluation[.evaluationWorkUnits] = 0
        #expect(throws: JSONFailure.self) {
            try SchemaValidatorAdapter.validate(.number(JSONNumber(integer: 1)), against: report.result, limits: noEvaluation)
        }
        // A separate admitted invocation may use the same immutable plan. This
        // does NOT reset a RequestBudget or authorize retry after its failure.
        #expect(try SchemaValidatorAdapter.validate(.number(JSONNumber(integer: 1)), against: report.result, limits: .balanced).result.isValid)
        #expect(report.result.document.raw == raw)
    }

    @Test func unsupportedDialectIsAnOperationalRegistrationFailure() throws {
        let schema = try s07SchemaJSON(#"{"$schema":"https://unavailable.invalid/dialect","type":"integer"}"#)
        #expect(throws: JSONSchemaCompilationFailure.self) {
            try SchemaCompilerAdapter.compile(schema, limits: .balanced)
        }
    }

    @Test func vocabularyInAnOrdinarySchemaDoesNotDeclareADialect() throws {
        // Draft 2020-12 only uses $vocabulary when processing a meta-schema.
        let raw = try s07SchemaJSON(#"{"$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://unavailable.invalid/vocab":true},"type":"integer"}"#)
        let plan = try SchemaCompilerAdapter.compile(raw, limits: .balanced).result
        #expect(try SchemaValidatorAdapter.validate(.number(JSONNumber(integer: 1)), against: plan, limits: .balanced).result.isValid)
        #expect(!(try SchemaValidatorAdapter.validate(.string("wrong"), against: plan, limits: .balanced).result.isValid))
    }

    @Test func selectedMetaSchemaWithUnsupportedRequiredVocabularyFailsOffline() throws {
        let dialect = "https://unavailable.invalid/dialect"
        let rawMeta = try s07SchemaJSON(#"{"$id":"https://unavailable.invalid/dialect","$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://unavailable.invalid/vocab":true}}"#)
        let meta = try JSONSchemaDocument(rawMeta, retrievalURI: JSONSchemaURI(dialect))
        let registry = try JSONSchemaRegistry(documents: [meta])
        let schema = try s07SchemaJSON(#"{"$schema":"https://unavailable.invalid/dialect","type":"integer"}"#)
        do {
            _ = try SchemaCompilerAdapter.compile(schema, limits: .balanced, registry: registry)
            Issue.record("An unsupported required vocabulary must fail compilation")
        } catch let error as JSONSchemaCompilationFailure {
            #expect(error.category == .vocabulary)
        }
    }

    @Test(arguments: [#"{"$ref":"https://unavailable.invalid/schema"}"#, #"{"$ref":"file:///not-an-admitted-schema.json"}"#])
    func offlineRegistryDoesNotResolveUnregisteredNetworkOrFileReferences(schema: String) throws {
        // Empty means explicitly empty; no URL/file resolver callback is given.
        #expect(throws: JSONSchemaCompilationFailure.self) {
            try SchemaCompilerAdapter.compile(s07SchemaJSON(schema), limits: .balanced)
        }
    }

    @Test func nestedPropertiesPreserveExactPathsAndIgnoreOrdinaryMetadata() async throws {
        let raw = try s07SchemaJSON(#"{"type":"object","properties":{"a/b~c":{"type":"object","properties":{"é":{"type":"string","x-mcp-header":"Composed"},"e\u0301":{"type":"string","x-mcp-header":"Decomposed"}}}},"org.example/note":{"x-mcp-header":"not a declaration"},"default":{"x-mcp-header":"also ordinary data"}}"#)
        let document = try JSONSchemaDocument(raw), charged = Mutex(UInt64(0))
        let declarations = try await HeaderDeclarations.scan(document,
            charge: { amount in charged.withLock { $0 += amount } }, inspect: { path in
                try SchemaInspectionAdapter.inspect(document, at: JSONPointer(tokens: path), limits: .balanced).result
            })
        #expect(declarations.count == 2 && charged.withLock { $0 } > 0)
        for declaration in declarations {
            #expect(declaration.path.count == 2)
            #expect(declaration.path[0].description.utf8.elementsEqual("a/b~c".utf8))
            let expected = declaration.name == "Mcp-Param-Composed" ? "é" : "e\u{301}"
            #expect(declaration.path[1].description.utf8.elementsEqual(expected.utf8))
        }
        #expect(declarations.map(\.name).sorted() == ["Mcp-Param-Composed", "Mcp-Param-Decomposed"])
    }

    @Test(arguments: [
        #"{"type":"string","x-mcp-header":"X"}"#,
        ##"{"$defs":{"x":{"type":"string","x-mcp-header":"X"}},"$ref":"#/$defs/x"}"##,
        #"{"type":"array","items":{"type":"string","x-mcp-header":"X"}}"#,
        #"{"type":"array","prefixItems":[{"type":"string","x-mcp-header":"X"}]}"#,
        #"{"allOf":[{"properties":{"x":{"type":"string","x-mcp-header":"X"}}}]}"#,
        #"{"anyOf":[{"properties":{"x":{"type":"string","x-mcp-header":"X"}}}]}"#,
        #"{"oneOf":[{"properties":{"x":{"type":"string","x-mcp-header":"X"}}}]}"#,
        #"{"if":{"properties":{"x":{"type":"string","x-mcp-header":"X"}}}}"#,
        #"{"additionalProperties":{"type":"string","x-mcp-header":"X"}}"#])
    func declarationsOutsidePropertiesOnlyChainsAreRejected(schema: String) async throws {
        await #expect(throws: HeaderDeclarationFailure.invalidLocation) {
            _ = try await s07DeclaredHeaders(s07SchemaJSON(schema))
        }
    }

    @Test func headerNameTypeAndCaseFoldedCollisionFailuresAreDistinct() async throws {
        let cases: [(String, HeaderDeclarationFailure)] = [
            (#"{"properties":{"x":{"type":"number","x-mcp-header":"X"}}}"#, .invalidType),
            (#"{"properties":{"x":{"type":["string","null"],"x-mcp-header":"X"}}}"#, .invalidType),
            (#"{"properties":{"x":{"x-mcp-header":"X"}}}"#, .invalidType),
            (#"{"properties":{"x":{"type":"string","x-mcp-header":""}}}"#, .invalidName),
            (#"{"properties":{"x":{"type":"string","x-mcp-header":null}}}"#, .invalidName),
            (#"{"properties":{"x":{"type":"string","x-mcp-header":"bad name"}}}"#, .invalidName),
            (#"{"properties":{"x":{"type":"string","x-mcp-header":"Region"},"nested":{"properties":{"y":{"type":"string","x-mcp-header":"region"}}}}}"#, .collision)
        ]
        for (schema, expected) in cases {
            await #expect(throws: expected) { _ = try await s07DeclaredHeaders(s07SchemaJSON(schema)) }
        }
    }
}
