// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

/// Registration-owned immutable wire plans. No compilation occurs in dispatch.
public struct PreparedWire: Sendable {
    let plans: [FrozenWireDefinition: WireDefinitionPlan]
    let logicalRetainedUpperBound: UInt64
    public static func prepare(_ definitions: Set<FrozenWireDefinition>, budget: RequestBudget) async throws -> Self {
        do {
            return try await FrozenWirePlanCache.shared.get().prepare(definitions, budget: budget)
        } catch {
            await budget.terminate()
            throw error
        }
    }
    // Kept as a cold, account-owned path when the bounded cache cannot retain
    // another plan. It performs actual upstream compilation, never skips validation.
    static func compile(_ definition: FrozenWireDefinition, document: FrozenWireDocument,
                        budget: RequestBudget) async throws -> (WireDefinitionPlan, UInt64) {
        try await budget.consume(65_536)
        let root = try await budget.performJSON { try document.root(at: definition, limits: $0) }
        return try await budget.performJSON {
            let report = try WireDefinitionPlan.compile(root, limits: $0)
            return JSONOperationReport(result: (report.result, report.statistics.peakLogicalRetainedBytes), statistics: report.statistics)
        }
    }
    func validate(_ value: JSON, as definition: FrozenWireDefinition, budget: RequestBudget) async throws -> Bool {
        guard let plan = plans[definition] else { throw CoreFailure.unpreparedDefinition }
        return try await budget.performJSON { try plan.validate(value, limits: $0) }
    }
}

/// Only immutable plans for the single hash-verified frozen protocol can enter
/// this process-lifetime cache. Application schemas, identities and request data
/// never enter it. Upstream mutable evaluation state remains invocation-owned.
/// One admitted preparation prevents simultaneous cold compiler work from
/// monopolizing the cooperative executor. Queue, definition and retained-byte
/// ceilings are independent; callers own and await every preparation.
actor FrozenWirePlanCache {
    static let shared: Result<FrozenWirePlanCache, any Error> = Result { try .init() }
    let admission: AdmissionController
    private let maximumDefinitions: Int, maximumRetainedBytes: UInt64
    private var document: FrozenWireDocument?
    private var entries: [FrozenWireDefinition: (WireDefinitionPlan, UInt64)] = [:]
    private var retainedBytes: UInt64 = 0, compilations: UInt64 = 0, hits: UInt64 = 0
    struct Snapshot: Sendable { let definitions: Int; let retainedBytes, compilations, hits: UInt64 }
    var snapshot: Snapshot { .init(definitions: entries.count, retainedBytes: retainedBytes, compilations: compilations, hits: hits) }
    init(maximumDefinitions: Int = 48, maximumRetainedBytes: UInt64 = 33_554_432,
         maximumWaiters: Int = 256) throws {
        guard (1...48).contains(maximumDefinitions), (1...33_554_432).contains(maximumRetainedBytes),
              (1...256).contains(maximumWaiters) else { throw CoreFailure.invalidPolicy }
        self.maximumDefinitions = maximumDefinitions; self.maximumRetainedBytes = maximumRetainedBytes
        admission = try AdmissionController(activeLimit: 1, queueLimit: maximumWaiters)
    }
    func prepare(_ definitions: Set<FrozenWireDefinition>, budget: RequestBudget) async throws -> PreparedWire {
        guard !definitions.isEmpty, definitions.count <= 48 else { throw CoreFailure.limit }
        do {
            let permit = try await admission.acquire()
            let result: PreparedWire
            do { result = try await prepareAdmitted(definitions, budget: budget) }
            catch {
                await budget.terminate()
                try await admission.release(permit)
                throw error
            }
            try await admission.release(permit)
            return result
        } catch {
            await budget.terminate()
            throw error
        }
    }
    private func prepareAdmitted(_ definitions: Set<FrozenWireDefinition>, budget: RequestBudget) async throws -> PreparedWire {
        try Task.checkCancellation()
        let document: FrozenWireDocument
        if let cached = self.document {
            try await budget.consume(256)
            document = cached
        } else {
        // Fixed resource I/O, two bounded digests and declaration selection are
        // server work, independent of the upstream parser/compiler reports.
        try await budget.consume(UInt64(FrozenWireSchema.byteCount) * 4)
        let bytes = try FrozenWireSchema.read(maximumBytes: 262_144)
            let parsed = try await budget.performJSON {
                let report = try FrozenWireSchema.parse(bytes, limits: $0)
                return JSONOperationReport(result: (report.result, report.statistics.peakLogicalRetainedBytes), statistics: report.statistics)
            }
            document = parsed.0
            if parsed.1 <= maximumRetainedBytes { self.document = document; retainedBytes = parsed.1 }
        }
        var plans: [FrozenWireDefinition: WireDefinitionPlan] = [:]
        var retained: UInt64 = 0
        for definition in definitions.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            try await budget.consume(256)
            let prepared: (WireDefinitionPlan, UInt64)
            if let cached = entries[definition] {
                // A conservative server-owned reference/copy reservation. There
                // is no compilation and no reused or manufactured library report.
                try await budget.consume(cached.1)
                prepared = cached
                if hits < UInt64.max { hits += 1 }
            } else {
                prepared = try await PreparedWire.compile(definition, document: document, budget: budget)
                if compilations < UInt64.max { compilations += 1 }
                let sum = retainedBytes.addingReportingOverflow(prepared.1)
                if self.document != nil, entries.count < maximumDefinitions, !sum.overflow, sum.partialValue <= maximumRetainedBytes {
                    entries[definition] = prepared; retainedBytes = sum.partialValue
                }
            }
            let sum = retained.addingReportingOverflow(prepared.1)
            guard !sum.overflow, sum.partialValue <= 33_554_432 else { throw CoreFailure.limit }
            retained = sum.partialValue; plans[definition] = prepared.0
        }
        return .init(plans: plans, logicalRetainedUpperBound: retained)
    }
}
