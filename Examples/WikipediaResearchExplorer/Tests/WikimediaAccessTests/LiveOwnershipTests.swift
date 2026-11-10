// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerDomain
@testable import WikimediaAccess

private actor HeldLiveTransport: LiveTransport {
    private(set) var entered = 0, joined = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func waitForTwo() async {
        if entered >= 2 { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func get(_ url: URL, deadline: ContinuousClock.Instant) async throws -> LiveHTTPResponse {
        entered += 1
        if entered == 2 { enteredWaiter?.resume(); enteredWaiter = nil }
        await withCheckedContinuation { pending.append($0) }
        defer { joined += 1 }
        try Task.checkCancellation()
        return .init(status: 200, body: Data(#"{"pages":[]}"#.utf8), headers: ["Content-Type": "application/json"])
    }
    func release() { let p = pending; pending = []; for c in p { c.resume() } }
}
@Suite struct LiveOwnershipTests {
    @Test func cancelledNoncooperativeOwnersKeepPermitsUntilJoin() async throws {
        let transport = HeldLiveTransport(), provider = WikipediaProvider(transport: transport)
        let first = Task { try await provider.search(query: "one", project: "enwiki", limit: 1) }
        let second = Task { try await provider.search(query: "two", project: "enwiki", limit: 1) }
        await transport.waitForTwo()
        let entered = await transport.entered
        first.cancel(); second.cancel()
        var denied = false
        do { _ = try await provider.search(query: "three", project: "enwiki", limit: 1) }
        catch let p as ExplorerProblem { denied = p.code == .budgetExceeded }
        let earlyJoined = await transport.joined
        // Release before assertions so an assertion failure cannot leak owners.
        await transport.release()
        for task in [first, second] { do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Wrong typed outcome") } }
        #expect(entered == 2 && denied && earlyJoined == 0)
        #expect(await transport.joined == 2)
    }
    @Test func serviceRejectsForeignProfileBeforeProviderEntry() async throws {
        let transport = HeldLiveTransport(), provider = WikipediaProvider(transport: transport)
        let service = ExplorerService(provider: provider, limits: try ExplorerLimits())
        do { _ = try await service.search(.init(query: "x", project: "fixture-enwiki", limit: 1)); Issue.record("Must reject foreign project") }
        catch let p as ExplorerProblem { #expect(p.code == .projectNotAllowed) }
        #expect(await transport.entered == 0)
    }
}
