// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerPresentation

@MainActor private final class HeldTerminationOwner {
    var waiter: CheckedContinuation<Void, Never>?
    var entered = false, joined = false
    func settle() async -> Bool {
        entered = true
        await withCheckedContinuation { waiter = $0 }
        joined = true; return true
    }
    func release() { let w = waiter; waiter = nil; w?.resume() }
}
@Suite @MainActor struct TerminationTests {
    @Test func heldOwnerDeclinesBoundedlyAndJoinsBeforeRecovery() async throws {
        let owner = HeldTerminationOwner(), controller = AppTerminationController()
        var recovered = false
        let start = ContinuousClock.now
        let result = await controller.request(waitMilliseconds: 20, settle: { await owner.settle() }, recover: { recovered = true })
        #expect(!result && controller.unsettled && !owner.joined && !recovered)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await controller.request(waitMilliseconds: 20, settle: { true }, recover: {}) == false)
        owner.release()
        for _ in 0..<100 where !recovered { await Task.yield() }
        #expect(owner.joined && recovered && !controller.unsettled)
    }
    @Test func declinedQuitRecreatesResearchAfterActualOldJoin() async throws {
        let service = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let controller = AppTerminationController(), old = ResearchController(client: service)
        var replacement: ResearchController?
        let result = await controller.request(settle: { await old.shutdown(); return false }, recover: { replacement = ResearchController(client: service) })
        #expect(!result)
        let fresh = try #require(replacement); fresh.query = "Riverglass"; fresh.search(); await fresh.waitUntilIdle()
        #expect(fresh.page?.candidates.isEmpty == false)
        await fresh.shutdown()
    }
    @Test func cleanTerminationCommitsOnceWhileFailedSettlementRetainsDecline() async {
        let controller = AppTerminationController()
        #expect(await controller.request(settle: { true }, recover: { Issue.record("Must not recover committed Quit") }))
        #expect(controller.state == .committed)
        #expect(await controller.request(settle: { true }, recover: {}) == false)
        let failed = AppTerminationController()
        #expect(await failed.request(settle: { false }, recover: {}) == false)
        #expect(failed.state == .declined && !failed.unsettled)
    }
}
