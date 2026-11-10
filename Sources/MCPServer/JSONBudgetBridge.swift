// SPDX-License-Identifier: Apache-2.0
import JSON

extension RequestBudget {
    /// Synchronous owned library operation on this actor. No actor reentrancy can
    /// share its allowance. Parallel owners may reserve disjoint finite tickets.
    public func performJSON<Result: Sendable>(limits: JSONLimits = .balanced,
        _ operation: @Sendable (JSONLimits) throws -> JSONOperationReport<Result>) throws -> Result {
        do {
            try Task.checkCancellation()
            let ticket = try reserve(remaining, library: true)
            do {
                let report = try operation(Self.limits(limits, for: ticket))
                try Task.checkCancellation()
                try settle(ticket, report: .init(version: report.statistics.accountingVersion,
                    workUnits: report.statistics[.workUnits], subsystems: [
                        .numeric: report.statistics[.numericWorkUnits],
                        .compilation: report.statistics[.compileWorkUnits],
                        .evaluation: report.statistics[.evaluationWorkUnits],
                        .regexCompilation: report.statistics[.regexCompileWorkUnits],
                        .regexAggregate: report.statistics[.aggregateRegexWorkUnits]]))
                return report.result
            } catch {
                // Invalid settlement has already consumed its ticket; do not settle twice.
                failOperation(ticket); throw error
            }
        } catch { terminate(); throw error }
    }
    /// APIs without a report receive a finite reservation and conservatively
    /// consume that entire allowance on success. No inferred accounting report.
    public func performUnreported<Result: Sendable>(workUnits: UInt64, limits: JSONLimits = .balanced,
        _ operation: @Sendable (JSONLimits) throws -> Result) throws -> Result {
        do {
            try Task.checkCancellation()
            let ticket = try reserve(workUnits, library: true)
            do {
                let supplied = Self.limits(limits, for: ticket)
                let result = try operation(supplied)
                try Task.checkCancellation()
                // The full subsystem reservations are conservatively consumed as well.
                try settle(ticket, report: .init(version: 1, workUnits: ticket.allowance, subsystems: Self.counters(supplied)))
                return result
            } catch { failOperation(ticket); throw error }
        } catch { terminate(); throw error }
    }
    private static func counters(_ limits: JSONLimits) -> [Subsystem: UInt64] {
        [.numeric: limits[.numericWorkUnits], .compilation: limits[.compileWorkUnits],
         .evaluation: limits[.evaluationWorkUnits], .regexCompilation: limits[.regexCompileWorkUnits],
         .regexAggregate: limits[.aggregateRegexWorkUnits]]
    }
    private static func limits(_ base: JSONLimits, for ticket: Reservation) -> JSONLimits {
        var value = base
        value[.workUnits] = min(base[.workUnits], ticket.allowance)
        for (subsystem, metric) in [(Subsystem.numeric, JSONResourceMetric.numericWorkUnits),
            (.compilation, .compileWorkUnits), (.evaluation, .evaluationWorkUnits),
            (.regexCompilation, .regexCompileWorkUnits), (.regexAggregate, .aggregateRegexWorkUnits)] {
            value[metric] = min(base[metric], ticket.subsystems[subsystem] ?? 0)
        }
        // Per-search, shape/live capacity and logical retention remain stage ceilings.
        return value
    }
}
