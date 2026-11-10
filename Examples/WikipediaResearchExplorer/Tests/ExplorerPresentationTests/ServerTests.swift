// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerPresentation

private actor ControlledHost: ExplorerHTTPHost {
    var runs = 0, joined = 0, concurrent = 0, maximum = 0
    var failRun = false, denyStop = false, lateReady = false
    private var stopSignal: AsyncStream<Void>.Continuation?
    private var didReady = false
    private var readiness: CheckedContinuation<Void, Never>?
    private var callback: (@Sendable (ServerEndpoint) async -> Void)?
    func configure(fail: Bool = false, deny: Bool = false, late: Bool = false) { failRun = fail; denyStop = deny; lateReady = late }
    func waitReady() async { if didReady { return }; await withCheckedContinuation { readiness = $0 } }
    func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws {
        runs += 1; concurrent += 1; maximum = max(maximum, concurrent)
        defer { concurrent -= 1; joined += 1 }
        if failRun { throw HostFailure.startFailed }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stopSignal = pair.continuation; callback = ready
        if !lateReady { await ready(try ServerEndpoint(host: "127.0.0.1", port: 12345)) }
        didReady = true; readiness?.resume(); readiness = nil
        for await _ in pair.stream { break }
    }
    func stop() async throws {
        if denyStop { throw HostFailure.stopFailed }
        if lateReady { await callback?(try ServerEndpoint(host: "127.0.0.1", port: 12345)) }
        stopSignal?.yield(()); stopSignal?.finish(); didReady = false
    }
}
struct ServerTests {
    @Test @MainActor func T05_repeatedStartAndRestartNeverOverlap() async {
        let host = ControlledHost(), activity = ActivityStore()
        let controller = ServerController(activity: activity, factory: { _ in host })
        controller.start(); controller.start(); await host.waitReady()
        #expect(controller.phase == .running); #expect(await host.runs == 1)
        controller.restart(); await controller.awaitTransition(); await host.waitReady()
        #expect(await host.runs == 2); #expect(await host.joined == 1); #expect(await host.maximum == 1)
        let joined = await controller.stopAndJoin()
        #expect(joined && controller.phase == .stopped); #expect(await host.joined == 2)
    }
    @Test @MainActor func T06_stopFailureRetainsDebtAndLateReadyCannotResurrect() async {
        let host = ControlledHost(); await host.configure(deny: true, late: true)
        let controller = ServerController(activity: ActivityStore(), factory: { _ in host })
        controller.start(); await host.waitReady()
        controller.stop(); await controller.awaitTransition()
        #expect(controller.phase == .failed && controller.cleanupDebt && !controller.canStart)
        await host.configure(late: true)
        let joined = await controller.stopAndJoin()
        #expect(joined && controller.phase == .stopped && controller.endpoint == nil)
    }
    @Test @MainActor func T06_failedStartIsNotRunning() async {
        let activity = ActivityStore()
        let controller = ServerController(activity: activity, factory: { _ in throw HostFailure.startFailed })
        controller.start()
        #expect(controller.phase == .failed && controller.endpoint == nil && !controller.cleanupDebt)
        #expect(await controller.stopAndJoin())
    }
    @Test @MainActor func T07_presentationReadsDoNotStopServerAndQuitJoins() async {
        let host = ControlledHost(), activity = ActivityStore()
        let controller = ServerController(activity: activity, factory: { _ in host })
        controller.start(); await host.waitReady()
        _ = await activity.snapshot(); _ = ActivityFilter(search: "nothing")
        #expect(controller.phase == .running); #expect(await host.joined == 0)
        let joined = await controller.stopAndJoin()
        #expect(joined); #expect(await host.joined == 1)
    }
}

private actor DelayedStopHost: ExplorerHTTPHost {
    var started = false
    var join: CheckedContinuation<Void, Never>?, readyWaiter: CheckedContinuation<Void, Never>?
    func run(ready: @escaping @Sendable (ServerEndpoint) async -> Void) async throws {
        await ready(try ServerEndpoint(host: "127.0.0.1", port: 12345))
        await withCheckedContinuation { join = $0; started = true; readyWaiter?.resume(); readyWaiter = nil }
    }
    func waitReady() async { if started { return }; await withCheckedContinuation { readyWaiter = $0 } }
    func stop() async throws { /* deliberately incomplete; owner must remain retained */ }
    func finish() { join?.resume(); join = nil }
}
struct ShutdownDebtTests {
    @Test @MainActor func T07_deadlineDeclinesQuitAndLaterJoinSettlesDebt() async {
        let host = DelayedStopHost()
        let controller = ServerController(activity: ActivityStore(), factory: { _ in host })
        controller.start(); await host.waitReady()
        let early = await controller.stopAndJoin(waitMilliseconds: 10)
        #expect(!early && controller.cleanupDebt && !controller.canStart && controller.phase == .failed)
        await host.finish(); await controller.awaitTransition()
        #expect(await controller.stopAndJoin())
        #expect(!controller.cleanupDebt && controller.phase == .stopped)
    }
}
