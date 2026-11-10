// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
@testable import MCPServer
import Testing

private func wireAccount(_ work: UInt64 = 256_000_000) throws -> RequestBudget {
    try RequestBudget(workUnits:work,subsystemLimits:[.numeric:8_000_000,.compilation:128_000_000,
        .evaluation:32_000_000,.regexCompilation:8_000_000,.regexAggregate:8_000_000])
}
private func waitForWireQueue(_ gate: AdmissionController, count: Int) async throws {
    let end = ContinuousClock.now.advanced(by:.seconds(4))
    while await gate.queuedCount != count {
        guard ContinuousClock.now < end else { throw CoreFailure.deadline }
        try await Task.sleep(for:.milliseconds(1))
    }
}

@Suite struct FrozenWirePreparationOwnership {
    @Test func warmPlansUseIndependentAccountsAndStillRunActualValidation() async throws {
        let cache = try FrozenWirePlanCache(), cold = try wireAccount(), warm = try wireAccount()
        let first = try await cache.prepare([.Implementation],budget:cold)
        let second = try await cache.prepare([.Implementation],budget:warm)
        let a = await cold.snapshot, b = await warm.snapshot
        #expect(a.settledWork > b.settledWork && b.settledWork > 0)
        #expect(a.activeReservations == 0 && b.activeReservations == 0)
        let value = try JSONParser().parse(#"{"name":"independent","version":"1"}"#)
        #expect(try await first.validate(value,as:.Implementation,budget:cold))
        #expect(try await second.validate(value,as:.Implementation,budget:warm))
        let invalid = try JSONParser().parse(#"{"name":false,"version":"1"}"#)
        #expect(try await !second.validate(invalid,as:.Implementation,budget:warm))
        #expect(await !warm.snapshot.isTerminal)
        let snapshot = await cache.snapshot
        #expect(snapshot.compilations == 1 && snapshot.hits == 1 && snapshot.definitions == 1)
    }
    @Test func concurrentColdPreparationIsSingleFlightAndAllCallersJoin() async throws {
        let cache = try FrozenWirePlanCache()
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let budget = try wireAccount()
                    _ = try await cache.prepare([.Implementation],budget:budget)
                    #expect(await budget.snapshot.activeReservations == 0)
                }
            }
            try await group.waitForAll()
        }
        let s = await cache.snapshot
        #expect(s.compilations == 1 && s.hits == 15)
        #expect(await cache.admission.activeCount == 0)
        #expect(await cache.admission.queuedCount == 0)
    }
    @Test func independentDefinitionAndByteCeilingsNeverSkipColdValidation() async throws {
        let byteBound = try FrozenWirePlanCache(maximumRetainedBytes:1)
        let budget = try wireAccount()
        let plan = try await byteBound.prepare([.Implementation],budget:budget)
        #expect(try await !plan.validate(.null,as:.Implementation,budget:budget))
        #expect(await byteBound.snapshot.retainedBytes == 0)
        #expect(await byteBound.snapshot.definitions == 0)
        let one = try FrozenWirePlanCache(maximumDefinitions:1)
        _ = try await one.prepare([.Implementation],budget:wireAccount())
        let tool = try await one.prepare([.Tool],budget:wireAccount())
        #expect(try await !tool.validate(.null,as:.Tool,budget:wireAccount()))
        #expect(await one.snapshot.definitions == 1)
        #expect(await one.snapshot.retainedBytes <= 33_554_432)
    }
    @Test func warmFailureIsTerminalAndCannotSpendOrCompileAgain() async throws {
        let cache = try FrozenWirePlanCache()
        _ = try await cache.prepare([.Implementation],budget:wireAccount())
        let depleted = try wireAccount(1)
        await #expect(throws:(any Error).self) { _ = try await cache.prepare([.Implementation],budget:depleted) }
        let before = await depleted.snapshot
        #expect(before.isTerminal && before.terminalTransitions == 1)
        await #expect(throws:(any Error).self) { _ = try await cache.prepare([.Implementation],budget:depleted) }
        #expect(await depleted.snapshot.terminalTransitions == 1)
        #expect(await cache.snapshot.compilations == 1)
        #expect(await cache.admission.activeCount == 0)
    }
    @Test func queuedCancellationOwnsItsAccountAndLeavesNoPreparationPermit() async throws {
        let cache = try FrozenWirePlanCache(), account = try wireAccount()
        let held = try await cache.admission.acquire()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                await #expect(throws:CancellationError.self) { _ = try await cache.prepare([.Implementation],budget:account) }
            }
            try await waitForWireQueue(cache.admission,count:1)
            group.cancelAll(); try await group.waitForAll()
        }
        #expect(await account.snapshot.isTerminal)
        #expect(await account.snapshot.activeReservations == 0)
        #expect(await cache.admission.queuedCount == 0)
        try await cache.admission.release(held)
        _ = try await cache.prepare([.Implementation],budget:wireAccount())
        #expect(await cache.admission.activeCount == 0)
    }
    @Test func saturatedPreparationRejectsIndependentlyAndDoesNotStealOwnerPermit() async throws {
        let cache = try FrozenWirePlanCache(maximumWaiters:1)
        let held = try await cache.admission.acquire(), rejected = try wireAccount()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { _ = try await cache.prepare([.Implementation],budget:wireAccount()) }
            try await waitForWireQueue(cache.admission,count:1)
            await #expect(throws:AdmissionController.Failure.saturated) { _ = try await cache.prepare([.Implementation],budget:rejected) }
            #expect(await rejected.snapshot.isTerminal)
            #expect(await cache.admission.activeCount == 1)
            try await cache.admission.release(held)
            try await group.waitForAll()
        }
        #expect(await cache.admission.activeCount == 0)
        #expect(await cache.admission.queuedCount == 0)
    }
    @Test func cachePoliciesRejectUnlimitedOrOversizedValues() throws {
        #expect(throws:CoreFailure.invalidPolicy) { try FrozenWirePlanCache(maximumDefinitions:0) }
        #expect(throws:CoreFailure.invalidPolicy) { try FrozenWirePlanCache(maximumDefinitions:49) }
        #expect(throws:CoreFailure.invalidPolicy) { try FrozenWirePlanCache(maximumRetainedBytes:UInt64.max) }
        #expect(throws:CoreFailure.invalidPolicy) { try FrozenWirePlanCache(maximumWaiters:257) }
    }
}
