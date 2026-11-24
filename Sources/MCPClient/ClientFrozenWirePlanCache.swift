// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

/// Process-local preparation of the one hash-verified, frozen MCP wire schema.
/// Only immutable documents/plans for FrozenWireDefinition can enter this cache;
/// request values, application schemas and authorization never enter it.
///
/// Cold preparation is synchronous within this actor: there is no suspension
/// between a miss and publication, so an admitted miss cannot race another
/// miss. The caller owns the work; no detached task, continuation registry,
/// or application-owned waiter queue is created. Evaluation happens outside
/// this actor with a fresh upstream validator and the existing operation limits.
actor ClientFrozenWirePlanCache {
    static let shared = ClientFrozenWirePlanCache()

    static let compileLimits: JSONLimits = {
        var limits = JSONLimits.balanced
        for key: JSONResourceMetric in [.workUnits, .compileWorkUnits, .evaluationWorkUnits, .numericWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] {
            limits[key] = 256_000_000
        }
        return limits
    }()

    private let maximumDefinitions: Int
    private let maximumRetainedBytes: UInt64
    private let limits: JSONLimits
    private var document: FrozenWireDocument?
    private var plans: [FrozenWireDefinition: WireDefinitionPlan] = [:]
    private var retainedBytes: UInt64 = 0
    private var parses: UInt64 = 0
    private var compilations: UInt64 = 0
    private var hits: UInt64 = 0

    struct Snapshot: Sendable {
        let documentCached: Bool
        let definitions: Int
        let retainedBytes: UInt64
        let parses: UInt64
        let compilations: UInt64
        let hits: UInt64
    }

    var snapshot: Snapshot {
        .init(documentCached: document != nil, definitions: plans.count,
              retainedBytes: retainedBytes, parses: parses, compilations: compilations, hits: hits)
    }

    /// Internal, independently instantiable policy for tests. All production
    /// validators use the fixed shared instance and the unchanged limits.
    init(maximumDefinitions: Int = 48, maximumRetainedBytes: UInt64 = 33_554_432,
         limits: JSONLimits = ClientFrozenWirePlanCache.compileLimits) {
        precondition((1...48).contains(maximumDefinitions))
        precondition((1...33_554_432).contains(maximumRetainedBytes))
        self.maximumDefinitions = maximumDefinitions
        self.maximumRetainedBytes = maximumRetainedBytes
        self.limits = limits
    }

    func plan(for definition: FrozenWireDefinition) throws -> WireDefinitionPlan {
        try Task.checkCancellation()
        if let cached = plans[definition] {
            if hits < UInt64.max { hits += 1 }
            return cached
        }

        let source: FrozenWireDocument
        if let cached = document {
            source = cached
        } else {
            let bytes = try FrozenWireSchema.read(maximumBytes: FrozenWireSchema.byteCount)
            let report = try FrozenWireSchema.parse(bytes, limits: limits)
            source = report.result
            if parses < UInt64.max { parses += 1 }

            // As in server-side preparation, retain against the upstream peak
            // logical-byte report, not an invented heap/RSS measurement.
            let weight = report.statistics.peakLogicalRetainedBytes
            if weight <= maximumRetainedBytes - retainedBytes {
                document = source
                retainedBytes += weight
            }
        }

        try Task.checkCancellation()
        let root = try source.root(at: definition, limits: limits).result
        try Task.checkCancellation()
        let report = try WireDefinitionPlan.compile(root, limits: limits)
        if compilations < UInt64.max { compilations += 1 }

        let weight = report.statistics.peakLogicalRetainedBytes
        if plans.count < maximumDefinitions, weight <= maximumRetainedBytes - retainedBytes {
            plans[definition] = report.result
            retainedBytes += weight
        }
        // Bounded retention is not a validation budget. When full, return
        // the freshly compiled plan without retaining it or evicting warm
        // entries. The caller still evaluates the actual response.
        // A completed immutable artifact is safe to publish even when its
        // original caller was cancelled; that caller must not return success.
        try Task.checkCancellation()
        return report.result
    }
}
