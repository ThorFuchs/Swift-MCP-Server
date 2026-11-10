// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Request-owned cumulative work. Reservations cover in-flight unreported work;
/// successful reports settle once. A failed account never regains allowance.
public actor RequestBudget {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, exhausted, invalidReservation, invalidReport, unsupportedAccountingVersion
    }
    public enum Subsystem: String, CaseIterable, Sendable {
        case numeric, compilation, evaluation, regexCompilation, regexAggregate
    }
    public struct Report: Sendable {
        public let version: UInt32
        public let workUnits: UInt64
        public let subsystems: [Subsystem: UInt64]
        public init(version: UInt32, workUnits: UInt64, subsystems: [Subsystem: UInt64] = [:]) {
            self.version = version; self.workUnits = workUnits; self.subsystems = subsystems
        }
    }
    public struct Reservation: Sendable {
        fileprivate let id: UUID
        public let allowance: UInt64
        public let subsystems: [Subsystem: UInt64]
    }
    public struct Snapshot: Sendable {
        public let remaining: UInt64
        public let settledWork: UInt64
        public let activeReservations: Int
        public let isTerminal: Bool
        public let terminalTransitions: UInt64
    }
    public static let defaultSubsystemLimits: [Subsystem: UInt64] = [
        .numeric: 1_000_000, .compilation: 32_000_000, .evaluation: 16_000_000,
        .regexCompilation: 2_000_000, .regexAggregate: 2_000_000]
    private var available: UInt64
    private var subsystemAvailable: [Subsystem: UInt64]
    private var reservations: [UUID: Reservation] = [:]
    private var failed = false
    private var settled: UInt64 = 0
    private var terminalTransitions: UInt64 = 0
    private let reservationLimit: Int

    public init(workUnits: UInt64, maximumReservations: Int = 32,
                subsystemLimits: [Subsystem: UInt64] = defaultSubsystemLimits) throws {
        guard workUnits > 0, maximumReservations > 0,
              Subsystem.allCases.allSatisfy({ (subsystemLimits[$0] ?? 0) > 0 }) else { throw Failure.invalidLimit }
        available = workUnits; subsystemAvailable = subsystemLimits; reservationLimit = maximumReservations
    }
    public var remaining: UInt64 { failed ? 0 : available }
    public var snapshot: Snapshot {
        .init(remaining: remaining, settledWork: settled, activeReservations: reservations.count,
              isTerminal: failed, terminalTransitions: terminalTransitions)
    }
    /// Idempotent terminal transition. Owned reservations still settle/release once.
    public func terminate() {
        if !failed { terminalTransitions += 1 }
        failed = true; available = 0
    }
    public func consume(_ units: UInt64) throws {
        guard !failed, units <= available else { terminate(); throw Failure.exhausted }
        available -= units
        settled += units // bounded by the original total, never a wrapping counter
    }
    public func reserve(_ units: UInt64, library: Bool = false) throws -> Reservation {
        guard units > 0 else { terminate(); throw Failure.invalidLimit }
        guard !failed, reservations.count < reservationLimit, units <= available else {
            terminate(); throw Failure.exhausted
        }
        var caps: [Subsystem: UInt64] = [:]
        if library {
            for key in Subsystem.allCases {
                let amount = min(units, subsystemAvailable[key]!)
                caps[key] = amount; subsystemAvailable[key]! -= amount
            }
        }
        available -= units
        let ticket = Reservation(id: UUID(), allowance: units, subsystems: caps)
        reservations[ticket.id] = ticket
        return ticket
    }
    /// Internal operation cleanup: a malformed settlement may already have removed
    /// its ticket. Removing any still-owned ticket is idempotent; no allowance returns.
    func failOperation(_ ticket: Reservation) {
        reservations.removeValue(forKey: ticket.id)
        terminate()
    }
    public func settle(_ ticket: Reservation, consumed: UInt64?) throws {
        try settle(ticket, report: consumed.map { Report(version: 1, workUnits: $0) })
    }
    public func settle(_ ticket: Reservation, report: Report?) throws {
        guard let owned = reservations.removeValue(forKey: ticket.id) else {
            terminate(); throw Failure.invalidReservation
        }
        guard let report else { terminate(); return }
        guard report.version == 1 else { terminate(); throw Failure.unsupportedAccountingVersion }
        guard report.workUnits <= owned.allowance,
              report.subsystems.allSatisfy({ key, count in
                  count <= report.workUnits && count <= (owned.subsystems[key] ?? 0)
              }) else { terminate(); throw Failure.invalidReport }
        let (sum, overflow) = settled.addingReportingOverflow(report.workUnits)
        guard !overflow else { terminate(); throw Failure.invalidReport }
        settled = sum
        if !failed {
            available += owned.allowance - report.workUnits
            for (key, cap) in owned.subsystems { subsystemAvailable[key]! += cap - (report.subsystems[key] ?? 0) }
        }
    }
}
