// SPDX-License-Identifier: Apache-2.0
import MCPProtocol
@testable import MCPServer
import Testing

/// A new process starts with an empty frozen-plan cache, so `Server.make` compiles every
/// prepared definition under the default preparation policy. Tests elsewhere usually run
/// with a warm process-wide cache and cannot see this cost.
@Suite struct ColdPreparationBudget {
    @Test func defaultPolicyPreparesEveryServerDefinitionFromAColdCacheWithHeadroom() async throws {
        let policy = try ServerPreparationPolicy()
        let budget = try policy.budget()
        let cache = try FrozenWirePlanCache()
        _ = try await cache.prepare(Server.preparedDefinitions, budget: budget)
        #expect(await cache.snapshot.compilations == UInt64(Server.preparedDefinitions.count))
        #expect(await !budget.snapshot.isTerminal)
        let limits: [(RequestBudget.Subsystem, UInt64)] = [(.numeric, policy.numeric), (.compilation, policy.compilation),
            (.evaluation, policy.evaluation), (.regexCompilation, policy.regexCompilation), (.regexAggregate, policy.regexAggregate)]
        for (subsystem, limit) in limits {
            let used = limit - (await budget.remaining(subsystem))
            #expect(used * 4 <= limit * 3, "\(subsystem) uses \(used) of \(limit) default units")
        }
        let work = policy.work - (await budget.remaining)
        #expect(work * 4 <= policy.work * 3, "preparation uses \(work) of \(policy.work) default work units")
    }

    @Test func exhaustedEvaluationBudgetFailsClosedAndTerminatesTheAccount() async throws {
        let budget = try ServerPreparationPolicy(evaluation: 1_000_000).budget()
        let cache = try FrozenWirePlanCache()
        await #expect(throws: (any Error).self) { _ = try await cache.prepare(Server.preparedDefinitions, budget: budget) }
        #expect(await budget.snapshot.isTerminal)
        #expect(await budget.snapshot.activeReservations == 0)
    }
}
