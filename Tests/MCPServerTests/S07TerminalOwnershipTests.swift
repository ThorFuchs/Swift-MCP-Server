// SPDX-License-Identifier: Apache-2.0
import Synchronization
import Testing
import MCPServer

@Suite struct S07TerminalOwnership {
    @Test func existingTerminalElectionPreventsWorkAndStillReleasesAdmission() async throws {
        let admission = try AdmissionController(activeLimit: 1, queueLimit: 1)
        let budget = try RequestBudget(workUnits: 1000), terminal = TerminalCoordinator()
        let calls = Mutex(0)
        #expect(await terminal.claim(.disconnected))
        await #expect(throws: RequestBudget.Failure.exhausted) {
            _ = try await AdmittedOperation.run(admission: admission, budget: budget, terminal: terminal) { _ in
                calls.withLock { $0 += 1 }; return true
            }
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(await terminal.outcome == .disconnected)
        #expect(await terminal.claim(.complete) == false)
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
        #expect(await budget.snapshot.isTerminal)
    }

    @Test func unsettledReservationStaysOwnedUntilItsExplicitFailureSettlement() async throws {
        let admission = try AdmissionController(activeLimit: 1, queueLimit: 1)
        let budget = try RequestBudget(workUnits: 1000), terminal = TerminalCoordinator()
        let captured = Mutex<RequestBudget.Reservation?>(nil)
        await #expect(throws: RequestBudget.Failure.exhausted) {
            _ = try await AdmittedOperation.run(admission: admission, budget: budget, terminal: terminal) { account in
                let reservation = try await account.reserve(10)
                captured.withLock { $0 = reservation }
                return "provider tried to succeed without settling"
            }
        }
        let failed = await budget.snapshot
        #expect(failed.isTerminal && failed.activeReservations == 1 && failed.terminalTransitions == 1)
        #expect(await terminal.outcome == .failure)
        #expect(await admission.activeCount == 0)
        // Revoking work/returning admission is not a refund of outstanding debt.
        // The actual owner still has to settle its captured reservation once.
        let reservation = try #require(captured.withLock { $0 })
        try await budget.settle(reservation, consumed: nil)
        #expect(await budget.snapshot.activeReservations == 0)
        #expect(await budget.snapshot.remaining == 0)
        #expect(await budget.snapshot.terminalTransitions == 1)
        await #expect(throws: RequestBudget.Failure.invalidReservation) { try await budget.settle(reservation, consumed: nil) }
    }
}
