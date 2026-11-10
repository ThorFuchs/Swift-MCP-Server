// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer

@Test func profileCouplingIsFiniteAndClaimSettlementFitsItsIndependentReserve() async throws {
    for profile in ResourceProfile.allCases {
        let c = try profile.serverConfiguration(), e = try profile.eventPolicy(), p = try profile.continuationPolicy()
        #expect(c.requestWork > c.terminalWork && c.bufferedBytes > c.resultBytes)
        #expect(c.pageEntries <= 1000 && e.subscriptionLifetimeMilliseconds <= 3600000)
        #expect(p.maximumChainWork >= c.requestWork && p.maximumStateBytes <= p.maximumTokenBytes/2)
        let store = try profile.consumptionStore(now: { 1000 })
        #expect(store.maximumSettlementWork > 0 && store.maximumSettlementWork <= 16777216)
        let budget = try RequestBudget(workUnits: store.maximumSettlementWork + 32)
        let claim = try await store.claim(key: [UInt8](repeating: 1, count: 32), expiresAt: 1100, budget: budget)
        let cleanup = try RequestBudget(workUnits: store.maximumSettlementWork)
        try await store.release(claim, budget: cleanup)
        #expect(await store.count == 0)
    }
}
@Test func constructorBoundaryTriplesRejectZeroAndOvershootWithoutUnlimitedFallback() throws {
    for bytes in [8388607,8388608] { _ = try ServerConfiguration(messageBytes: bytes) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerConfiguration(messageBytes: 8388609) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerConfiguration(messageBytes: 0) }
    for pages in [999,1000] { _ = try ServerConfiguration(pageEntries: pages) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerConfiguration(pageEntries: 1001) }
    for attempts in [63,64] { _ = try ContinuationPolicy(maximumAttempts: attempts) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ContinuationPolicy(maximumAttempts: 65) }
    for count in [1023,1024] { _ = try EventPolicy(queuedEvents: count) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try EventPolicy(queuedEvents: 1025) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ServerConfiguration(resultBytes: Int.max) }
    #expect(throws: CoreFailure.invalidPolicy) { _ = try ContinuationPolicy(maximumTokenBytes: Int.max) }
}

@Test(arguments: ["active", "queued", "terminal", "result", "buffer", "catalog", "deadline", "inputs", "token", "state", "stateTTL", "eventBytes", "eventGlobal", "eventCount", "subscriptions", "filters", "subscriptionTTL", "perPrincipal", "principalEventBytes", "notificationBytes", "perPrincipalSubscriptions", "chainWork", "claimEntries", "claimKeyBytes", "preparationWork", "preparationNumeric", "preparationCompilation", "preparationEvaluation", "preparationRegexCompilation", "preparationRegexAggregate"])
func effectivePolicyBoundaryTriples(_ field: String) throws {
    let limit: Int64, make: (Int64) throws -> Void
    switch field {
    case "active": limit = 1024; make = { n in _ = try ServerConfiguration(activeRequests: Int(n)) }
    case "queued": limit = 4096; make = { n in _ = try ServerConfiguration(queuedRequests: Int(n)) }
    case "terminal": limit = 1000000; make = { n in _ = try ServerConfiguration(terminalWork: UInt64(n)) }
    case "result": limit = 16777216; make = { n in _ = try ServerConfiguration(resultBytes: Int(n), bufferedBytes: 268435456) }
    case "buffer": limit = 268435456; make = { n in _ = try ServerConfiguration(bufferedBytes: Int(n)) }
    case "catalog": limit = 100000; make = { n in _ = try ServerConfiguration(catalogEntries: Int(n)) }
    case "deadline": limit = 3600000; make = { n in _ = try ServerConfiguration(deadlineMilliseconds: n) }
    case "inputs": limit = 64; make = { n in _ = try ContinuationPolicy(maximumInputs: Int(n)) }
    case "token": limit = 131072; make = { n in _ = try ContinuationPolicy(maximumTokenBytes: Int(n)) }
    case "state": limit = 65536; make = { n in _ = try ContinuationPolicy(maximumTokenBytes: 131072, maximumStateBytes: Int(n)) }
    case "stateTTL": limit = 3600000; make = { n in _ = try ContinuationPolicy(lifetimeMilliseconds: n) }
    case "eventBytes": limit = 16777216; make = { n in _ = try EventPolicy(queuedBytes: Int(n), globalBytes: 268435456, principalBytes: 268435456, notificationBytes: 65536) }
    case "eventGlobal": limit = 268435456; make = { n in _ = try EventPolicy(globalBytes: Int(n)) }
    case "eventCount": limit = 100000; make = { n in _ = try EventPolicy(maximumEvents: Int(n)) }
    case "subscriptions": limit = 1024; make = { n in _ = try EventPolicy(subscriptions: Int(n)) }
    case "filters": limit = 1024; make = { n in _ = try EventPolicy(filters: Int(n)) }
    case "subscriptionTTL": limit = 3600000; make = { n in _ = try EventPolicy(subscriptionLifetimeMilliseconds: n) }
    case "perPrincipal": limit = 1024; make = { n in _ = try ServerConfiguration(activeRequests: 1024, requestsPerPrincipal: Int(n)) }
    case "principalEventBytes": limit = 268435456; make = { n in _ = try EventPolicy(globalBytes: 268435456, principalBytes: Int(n)) }
    case "notificationBytes": limit = 16777216; make = { n in _ = try EventPolicy(queuedBytes: 16777216, globalBytes: 268435456, principalBytes: 268435456, notificationBytes: Int(n)) }
    case "perPrincipalSubscriptions": limit = 1024; make = { n in _ = try EventPolicy(subscriptions: 1024, subscriptionsPerPrincipal: Int(n)) }
    case "chainWork": limit = 32768000000; make = { n in _ = try ContinuationPolicy(maximumChainWork: UInt64(n)) }
    case "claimEntries": limit = 65536; make = { n in _ = try StateConsumptionStore(maximumEntries: Int(n), maximumKeyBytes: 32, now: { 1000 }) }
    case "claimKeyBytes": limit = 16384; make = { n in _ = try StateConsumptionStore(maximumKeyBytes: Int(n), now: { 1000 }) }
    case "preparationWork": limit = 1000000000; make = { n in _ = try ServerPreparationPolicy(work: UInt64(n)) }
    case "preparationNumeric": limit = 512000000; make = { n in _ = try ServerPreparationPolicy(numeric: UInt64(n)) }
    case "preparationCompilation": limit = 512000000; make = { n in _ = try ServerPreparationPolicy(compilation: UInt64(n)) }
    case "preparationEvaluation": limit = 512000000; make = { n in _ = try ServerPreparationPolicy(evaluation: UInt64(n)) }
    case "preparationRegexCompilation": limit = 512000000; make = { n in _ = try ServerPreparationPolicy(regexCompilation: UInt64(n)) }
    case "preparationRegexAggregate": limit = 512000000; make = { n in _ = try ServerPreparationPolicy(regexAggregate: UInt64(n)) }
    default: throw CoreFailure.invalidPolicy
    }
    try make(limit - 1); try make(limit)
    // StateConsumptionStore has its own explicit failure layer.
    if field.hasPrefix("claim") {
        #expect(throws: StateConsumptionStore.Failure.invalidLimit) { try make(limit + 1) }
        #expect(throws: StateConsumptionStore.Failure.invalidLimit) { try make(0) }
    } else {
        #expect(throws: CoreFailure.invalidPolicy) { try make(limit + 1) }
        #expect(throws: CoreFailure.invalidPolicy) { try make(0) }
    }
}

// Exercise the actual preset work values; no enormous payload allocation is
// needed to prove the cumulative account's equality/overshoot and terminal rule.
@Test func eachPresetWorkEqualityOvershootAndTypedOverflowRemainTerminal() async throws {
    for profile in ResourceProfile.allCases {
        let limit = try profile.serverConfiguration().requestWork
        let account = try RequestBudget(workUnits: limit)
        try await account.consume(limit - 1)
        #expect(await account.remaining == 1)
        try await account.consume(1)
        #expect(await account.remaining == 0)
        await #expect(throws: RequestBudget.Failure.exhausted) { try await account.consume(1) }
        await #expect(throws: RequestBudget.Failure.exhausted) { try await account.consume(0) }
        let rejected = try RequestBudget(workUnits: limit)
        await #expect(throws: RequestBudget.Failure.exhausted) { try await rejected.consume(limit + 1) }
        #expect(await rejected.snapshot.isTerminal)
        #expect(await rejected.snapshot.activeReservations == 0)
    }
    let top = UInt64.max.addingReportingOverflow(1)
    #expect(top.overflow)
    let account = try RequestBudget(workUnits: UInt64.max)
    let ticket = try await account.reserve(UInt64.max)
    #expect(await account.remaining == 0)
    try await account.settle(ticket, consumed: UInt64.max)
    await #expect(throws: RequestBudget.Failure.exhausted) { try await account.consume(1) }
}
