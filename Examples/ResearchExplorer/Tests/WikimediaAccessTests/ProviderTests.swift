// SPDX-License-Identifier: Apache-2.0
// WRE1 test SOURCE. Native execution: NOT_RUN.
import Foundation
import Synchronization
import Testing
import ExplorerDomain
import WikimediaAccess

private func expectProblem(_ code: ExplorerProblem.Code, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(code)") }
    catch let problem as ExplorerProblem { #expect(problem.code == code) }
    catch { Issue.record("Unexpected error: \(error)") }
}
private final class Clock: Sendable {
    let time = Mutex(Date(timeIntervalSince1970: 0))
    func now() -> Date { time.withLock { $0 } }
    func set(_ value: TimeInterval) { time.withLock { $0 = Date(timeIntervalSince1970: value) } }
}
private final class ParkedProvider: ExplorerProvider {
    enum GateFailure: Error { case deadline }
    let source: FixtureProvider
    private let state = Mutex((entered: 0, released: false))
    init(_ source: FixtureProvider) { self.source = source }
    func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        state.withLock { $0.entered += 1 }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !state.withLock({ $0.released }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < end else { throw GateFailure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return try await source.search(query: query, project: project, limit: limit)
    }
    func resolve(candidateID: String, project: String) async throws -> CandidateResolution {
        try await source.resolve(candidateID: candidateID, project: project)
    }
    var count: Int { state.withLock { $0.entered } }
    func release() { state.withLock { $0.released = true } }
}
struct ProviderTests {
    @Test func blockedProviderCancellationCompletesBeforeRelease_R05() async throws {
        let p = ParkedProvider(try FixtureProvider.load())
        let service = ExplorerService(provider: p, limits: try ExplorerLimits())
        let task = Task { try await service.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10)) }
        do {
            let until = ContinuousClock.now.advanced(by: .seconds(1))
            while p.count == 0, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
            #expect(p.count == 1)
            let start = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled parked operation must not return") }
            catch is CancellationError { }
            // Deliberately before release. The seam has its own 2-second fallback.
            #expect(start.duration(to: .now) < .milliseconds(500))
        } catch {
            task.cancel(); p.release(); _ = await task.result; throw error
        }
        p.release(); _ = await task.result
    }
    @Test func noResultsRateLimitTimeoutAndAbsentPageStayDistinct() async throws {
        let p = try FixtureProvider.load()
        let s = ExplorerService(provider: p, limits: try ExplorerLimits())
        #expect(try await s.search(.init(query: "no-match", project: "fixture-enwiki", limit: nil)).candidates.isEmpty)
        await p.setFault(.rateLimited)
        await expectProblem(.upstreamRateLimited) { _ = try await s.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: nil)) }
        await p.setFault(.timedOut)
        await expectProblem(.upstreamTimedOut) { _ = try await s.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: nil)) }
        await p.setFault(.none)
        await expectProblem(.absentPage) { _ = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-expedition")) }
        await expectProblem(.unknownCandidate) { _ = try await s.outline(.init(project: "fixture-enwiki", candidateID: "missing")) }
        await expectProblem(.projectNotAllowed) { _ = try await s.search(.init(query: "Riverglass", project: "enwiki", limit: nil)) }
    }
    @Test func revisionDriftNeverRebindsOldPartLocator() async throws {
        let p = try FixtureProvider.load(), clock = Clock()
        let s = ExplorerService(provider: p, limits: try ExplorerLimits(), clock: { clock.now() })
        let a = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        await p.select(.r2)
        let b = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        let locA = try #require(a.sections.first(where: { $0.location.partID == "p2" })?.location)
        let locB = try #require(b.sections.first(where: { $0.location.partID == "p2" })?.location)
        #expect(try await s.section(.init(snapshot: a.snapshot, part: locA, maxTextBytes: nil)).text.contains("2-metre"))
        #expect(try await s.section(.init(snapshot: b.snapshot, part: locB, maxTextBytes: nil)).text.contains("2.1-metre"))
        await expectProblem(.revisionMismatch) { _ = try await s.section(.init(snapshot: b.snapshot, part: locA, maxTextBytes: nil)) }
    }
    @Test func expiryAndEvictionDemandNewOutlineInsteadOfFetchingLatest() async throws {
        let p = try FixtureProvider.load(), clock = Clock()
        let s = ExplorerService(provider: p, limits: try ExplorerLimits(cacheEntries: 1, snapshotTTL: 5), clock: { clock.now() })
        let a = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        let loc = try #require(a.sections.first?.location)
        clock.set(6)
        await expectProblem(.absentSnapshot) { _ = try await s.section(.init(snapshot: a.snapshot, part: loc, maxTextBytes: nil)) }
        clock.set(7)
        let fresh = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        await p.select(.r2)
        _ = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        await expectProblem(.absentSnapshot) { _ = try await s.section(.init(snapshot: fresh.snapshot, part: loc, maxTextBytes: nil)) }
    }
    @Test func cancellationAndTwoOperationAdmissionReleaseTheirOwnership() async throws {
        let p = ParkedProvider(try FixtureProvider.load())
        let s = ExplorerService(provider: p, limits: try ExplorerLimits())
        let query = SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: nil)
        let a = Task { try await s.search(query) }, b = Task { try await s.search(query) }
        do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while p.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if p.count != 2 {
            a.cancel(); b.cancel(); p.release(); _ = await a.result; _ = await b.result
            Issue.record("Both operations must enter the owned test seam"); return
        }
        await expectProblem(.budgetExceeded) { _ = try await s.search(query) }
        a.cancel(); p.release()
        do { _ = try await a.value; Issue.record("Cancelled provider result must not escape") } catch is CancellationError { }
        #expect(try await b.value.candidates.count == 2)
        // Join completed above; a new call is independently admitted.
        #expect(try await s.search(query).candidates.count == 2)
        } catch {
            a.cancel(); b.cancel(); p.release(); _ = await a.result; _ = await b.result
            throw error
        }
        a.cancel(); b.cancel(); p.release(); _ = await a.result; _ = await b.result

    }
}
