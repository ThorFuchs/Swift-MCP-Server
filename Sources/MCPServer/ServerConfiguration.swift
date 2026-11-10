// SPDX-License-Identifier: Apache-2.0
import MCPProtocol

public enum CoreFailure: Error, Sendable, Equatable {
    case invalidPolicy, limit, invalidInput, invalidOutput, unknownMethod, unknownProvider
    case insufficientScopes, missingCapability, duplicate, staleGeneration, invalidCursor
    case deadline, disconnected, unpreparedDefinition, invalidState, eventsUnavailable, eventOverflow
}
/// One cumulative, finite account per initial catalog or catalog replacement.
/// Subsystem ceilings remain independent and every helper settles on that same
/// account. Larger trusted catalogs may select an explicit host profile without
/// replenishing work or changing the per-operation JSON limits.
public struct ServerPreparationPolicy: Sendable {
    public let work, numeric, compilation, evaluation, regexCompilation, regexAggregate: UInt64
    // Defaults keep about 2x headroom over a cold preparation of every frozen definition a
    // server needs (measured: work 112M, compilation 107M, evaluation 31M units).
    // ColdPreparationBudgetTests fails once a subsystem would use more than 75%.
    public init(work: UInt64 = 512_000_000, numeric: UInt64 = 8_000_000,
        compilation: UInt64 = 256_000_000, evaluation: UInt64 = 64_000_000,
        regexCompilation: UInt64 = 8_000_000, regexAggregate: UInt64 = 8_000_000) throws {
        guard work > 0, work <= 1_000_000_000,
              [numeric, compilation, evaluation, regexCompilation, regexAggregate].allSatisfy({ $0 > 0 && $0 <= work }) else { throw CoreFailure.invalidPolicy }
        self.work = work; self.numeric = numeric; self.compilation = compilation; self.evaluation = evaluation
        self.regexCompilation = regexCompilation; self.regexAggregate = regexAggregate
    }
    func budget() throws -> RequestBudget {
        try .init(workUnits: work, subsystemLimits: [.numeric: numeric, .compilation: compilation,
            .evaluation: evaluation, .regexCompilation: regexCompilation, .regexAggregate: regexAggregate])
    }
}
public struct ServerConfiguration: Sendable {
    public let activeRequests: Int
    public let queuedRequests: Int
    public let requestsPerPrincipal: Int
    public let requestWork: UInt64
    public let terminalWork: UInt64
    public let messageBytes: Int
    public let resultBytes: Int
    public let catalogEntries: Int
    public let pageEntries: Int
    public let deadlineMilliseconds: Int64
    public let bufferedBytes: Int
    public let preparation: ServerPreparationPolicy
    public init(activeRequests: Int = 32, queuedRequests: Int = 64, requestsPerPrincipal: Int = 8,
        requestWork: UInt64 = 64_000_000, terminalWork: UInt64 = 262_144,
        messageBytes: Int = 1_048_576, resultBytes: Int = 4_194_304,
        catalogEntries: Int = 10_000, pageEntries: Int = 100,
        deadlineMilliseconds: Int64 = 120_000, bufferedBytes: Int = 16_777_216,
        preparation: ServerPreparationPolicy? = nil) throws {
        guard activeRequests > 0, activeRequests <= 1024, queuedRequests > 0, queuedRequests <= 4096,
              requestsPerPrincipal > 0, requestsPerPrincipal <= activeRequests,
              requestWork > terminalWork, terminalWork >= 4096, terminalWork <= 1_000_000,
              messageBytes > 0, messageBytes <= 8_388_608, resultBytes > 0, resultBytes <= 16_777_216,
              catalogEntries > 0, catalogEntries <= 100_000, pageEntries > 0, pageEntries <= 1000,
              deadlineMilliseconds > 0, deadlineMilliseconds <= 3_600_000,
              bufferedBytes > resultBytes, bufferedBytes <= 268_435_456 else { throw CoreFailure.invalidPolicy }
        self.activeRequests = activeRequests; self.queuedRequests = queuedRequests
        self.requestsPerPrincipal = requestsPerPrincipal; self.requestWork = requestWork
        self.terminalWork = terminalWork; self.messageBytes = messageBytes; self.resultBytes = resultBytes
        self.catalogEntries = catalogEntries; self.pageEntries = pageEntries
        self.deadlineMilliseconds = deadlineMilliseconds
        self.bufferedBytes = bufferedBytes
        self.preparation = try preparation ?? ServerPreparationPolicy()
    }
}
