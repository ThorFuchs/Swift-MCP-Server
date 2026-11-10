// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema
import MCPProtocol
import MCPJSONSchemaAdapter

/// Opaque coherent snapshot. Raw discovery, validation and header inspection
/// share the same generation; the private adapter plan is not a public facade.
public struct PreparedSchema: Sendable {
    public let identifier: UInt64
    public let raw: JSON
    public let logicalRetainedUpperBound: UInt64
    let generation: SchemaGeneration
}
public enum SchemaPreparation {
    public static func prepare(_ raw: JSON, identifier: UInt64, budget: RequestBudget,
        limits: JSONLimits = .balanced, registry: JSONSchemaRegistry = .empty) async throws -> PreparedSchema {
        let compiled = try await budget.performJSON(limits: limits) {
            let report = try SchemaCompilerAdapter.compile(raw, limits: $0, registry: registry)
            return JSONOperationReport(result: (report.result, report.statistics.peakLogicalRetainedBytes), statistics: report.statistics)
        }
        // The public plan retains the document admitted on its compiler meter.
        // Reuse it for inspection: no second construction or admission allowance.
        return .init(identifier: identifier, raw: raw, logicalRetainedUpperBound: compiled.1,
            generation: .init(identifier: identifier, raw: raw, plan: compiled.0, document: compiled.0.document))
    }
    public static func validate(_ instance: JSON, against prepared: PreparedSchema,
                                budget: RequestBudget) async throws -> Bool {
        try await budget.performJSON { try SchemaValidatorAdapter.validate(instance, against: prepared.generation.plan, limits: $0) }.isValid
    }
    public static func headers(for prepared: PreparedSchema, budget: RequestBudget,
        maximumNodes: Int = 1024, maximumDepth: Int = 32) async throws -> [HeaderDeclaration] {
        do {
            return try await HeaderDeclarations.scan(prepared.generation.document, maximumNodes: maximumNodes, maximumDepth: maximumDepth,
                charge: { try await budget.consume($0) }, inspect: { path in
                    // Pointer construction has no report, so reserve a finite full allowance.
                    var pointerLimits = JSONLimits.balanced
                    for metric in [JSONResourceMetric.numericWorkUnits, .compileWorkUnits, .evaluationWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] { pointerLimits[metric] = 0 }
                    let pointer = try await budget.performUnreported(workUnits: 65_536, limits: pointerLimits) { try JSONPointer(tokens: path, limits: $0) }
                    return try await budget.performJSON { try SchemaInspectionAdapter.inspect(prepared.generation.document, at: pointer, limits: $0) }
                })
        } catch { await budget.terminate(); throw error }
    }
}
