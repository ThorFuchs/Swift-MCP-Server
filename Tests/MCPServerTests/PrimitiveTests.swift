// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import MCPServer

@Test func cumulativeWorkAndDisjointReservations() async throws {
    let budget = try RequestBudget(workUnits: 10)
    try await budget.consume(2)
    let a = try await budget.reserve(5)
    let b = try await budget.reserve(3)
    #expect(await budget.remaining == 0)
    try await budget.settle(a, consumed: 4)
    #expect(await budget.remaining == 1)
    try await budget.settle(b, consumed: 3)
    #expect(await budget.remaining == 1)
    await #expect(throws: RequestBudget.Failure.invalidReservation) {
        try await budget.settle(a, consumed: 0)
    }
    await #expect(throws: RequestBudget.Failure.exhausted) { try await budget.consume(2) }
    await #expect(throws: RequestBudget.Failure.exhausted) { try await budget.consume(0) }
}

@Test func failureWithoutReportCannotStartAnotherStage() async throws {
    let budget = try RequestBudget(workUnits: 10)
    let ticket = try await budget.reserve(1)
    try await budget.settle(ticket, consumed: nil)
    #expect(await budget.remaining == 0)
    await #expect(throws: RequestBudget.Failure.exhausted) { try await budget.consume(1) }
}

@Test func invalidReportPoisonsOtherSettlements() async throws {
    let budget = try RequestBudget(workUnits: UInt64.max)
    let a = try await budget.reserve(1)
    let b = try await budget.reserve(UInt64.max - 1)
    await #expect(throws: RequestBudget.Failure.invalidReport) {
        try await budget.settle(a, consumed: 2)
    }
    try await budget.settle(b, consumed: 0)
    #expect(await budget.remaining == 0)
}

@Test func workAccountsRejectForeignTicketsAndBoundRetention() async throws {
    let a = try RequestBudget(workUnits: 5, maximumReservations: 1)
    let b = try RequestBudget(workUnits: 5)
    let ticket = try await a.reserve(1)
    await #expect(throws: RequestBudget.Failure.invalidReservation) {
        try await b.settle(ticket, consumed: 0)
    }
    await #expect(throws: RequestBudget.Failure.exhausted) { _ = try await a.reserve(1) }
    try await a.settle(ticket, consumed: 0)
    #expect(await a.remaining == 0)
    #expect(throws: RequestBudget.Failure.invalidLimit) { _ = try RequestBudget(workUnits: 0) }
}

@Test func concurrentWorkCannotOverspend() async throws {
    let budget = try RequestBudget(workUnits: 10)
    let accepted = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<100 {
            group.addTask { do { try await budget.consume(1); return true } catch { return false } }
        }
        var count = 0
        for await success in group { if success { count += 1 } }
        return count
    }
    #expect(accepted == 10)
    #expect(await budget.remaining == 0)
}

// Scheduler-independent synchronization: state is awaited, never a fixed sleep.
private func waitForQueue(_ admission: AdmissionController, count: Int) async {
    while await admission.queuedCount != count { await Task.yield() }
}

@Test func queuedCancellationDoesNotLeakAdmission() async throws {
    let admission = try AdmissionController(activeLimit: 1, queueLimit: 1)
    let first = try await admission.acquire()
    let queued = Task { try await admission.acquire() }
    await waitForQueue(admission, count: 1)
    await #expect(throws: AdmissionController.Failure.saturated) { _ = try await admission.acquire() }
    queued.cancel()
    await #expect(throws: CancellationError.self) { _ = try await queued.value }
    #expect(await admission.queuedCount == 0)
    try await admission.release(first)
    #expect(await admission.activeCount == 0)
    await #expect(throws: AdmissionController.Failure.invalidPermit) { try await admission.release(first) }
}

@Test func admissionIsFIFOAndStopRejectsWaiters() async throws {
    let admission = try AdmissionController(activeLimit: 1, queueLimit: 2)
    let first = try await admission.acquire()
    let second = Task { try await admission.acquire() }
    await waitForQueue(admission, count: 1)
    let third = Task { try await admission.acquire() }
    await waitForQueue(admission, count: 2)
    try await admission.release(first)
    let permit = try await second.value
    #expect(await admission.activeCount == 1)
    #expect(await admission.queuedCount == 1)
    await admission.stop()
    await admission.stop()
    await #expect(throws: AdmissionController.Failure.stopped) { _ = try await third.value }
    await #expect(throws: AdmissionController.Failure.stopped) { _ = try await admission.acquire() }
    try await admission.release(permit)
    #expect(await admission.activeCount == 0)
}

@Test func admissionCancellationRacesPermitTransfer() async throws {
    for _ in 0..<50 {
        let admission = try AdmissionController(activeLimit: 1, queueLimit: 1)
        let permit = try await admission.acquire()
        let queued = Task { try await admission.acquire() }
        await waitForQueue(admission, count: 1)
        queued.cancel()
        try await admission.release(permit)
        do { let granted = try await queued.value; try await admission.release(granted) }
        catch is CancellationError {}
        #expect(await admission.activeCount == 0)
        #expect(await admission.queuedCount == 0)
    }
}

@Test func terminalRaceHasOneOwner() async {
    let terminal = TerminalCoordinator()
    let winners = await withTaskGroup(of: Bool.self) { group in
        for outcome in [TerminalCoordinator.Outcome.complete, .failure, .cancelled, .disconnected] {
            group.addTask { await terminal.claim(outcome) }
        }
        var count = 0
        for await won in group { if won { count += 1 } }
        return count
    }
    #expect(winners == 1)
    #expect(await terminal.outcome != nil)
    #expect(await terminal.claim(.complete) == false)
}

@Test func replayClaimsAreAtomicAndBounded() async throws {
    let clock = Mutex<Int64>(100)
    let store = try StateConsumptionStore(maximumEntries: 1, maximumBytes: 100,
        maximumKeyBytes: 4, now: { clock.withLock { $0 } })
    let first = try await store.claim(key: [1], expiresAt: 110)
    await #expect(throws: StateConsumptionStore.Failure.alreadyClaimed) {
        _ = try await store.claim(key: [1], expiresAt: 110)
    }
    await #expect(throws: StateConsumptionStore.Failure.full) {
        _ = try await store.claim(key: [2], expiresAt: 110)
    }
    try await store.release(first)
    let retry = try await store.claim(key: [1], expiresAt: 110)
    await #expect(throws: StateConsumptionStore.Failure.invalidClaim) { try await store.commit(first) }
    try await store.commit(retry)
    await #expect(throws: StateConsumptionStore.Failure.invalidClaim) { try await store.release(retry) }
    clock.withLock { $0 = 110 }
    let next = try await store.claim(key: [2], expiresAt: 120)
    #expect(await store.count == 1)
    #expect(await store.retainedBytes == 97)
    try await store.release(next)
    #expect(await store.retainedBytes == 0)
}

@Test func concurrentReplayClaimHasOneWinner() async throws {
    let store = try StateConsumptionStore(now: { 100 })
    let winners = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<100 {
            group.addTask {
                do { _ = try await store.claim(key: [1], expiresAt: 200); return true }
                catch { return false }
            }
        }
        var count = 0
        for await won in group { if won { count += 1 } }
        return count
    }
    #expect(winners == 1)
    await #expect(throws: StateConsumptionStore.Failure.expired) {
        _ = try await store.claim(key: [2], expiresAt: 100)
    }
}
