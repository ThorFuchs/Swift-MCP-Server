// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPTasks
import Synchronization

/// One behavior suite every `TaskStore` backend must pass (ADR-0004).
///
/// Each check gets a fresh store from `makeStore`. Backends that keep state across
/// instances also pass `reopen`, which must return a new store instance over the
/// same storage as the given one; the `durableAcrossReopen` check is skipped otherwise.
///
/// Timestamps in the checks are whole milliseconds, so stores may keep millisecond
/// precision. Payloads must round-trip exactly.
///
/// ```swift
/// let kit = TaskStoreConformanceKit { InMemoryTaskStore() }
/// let results = await kit.runAll()
/// #expect(results.allSatisfy { $0.outcome == .passed || $0.check == .durableAcrossReopen })
/// ```
public struct TaskStoreConformanceKit: Sendable {
    public enum Check: String, Sendable, Hashable, CaseIterable {
        /// `create` stores version 1; a second `create` with the same ID throws `duplicate`.
        case createAndLoad
        /// Every stored field, including JSON payloads and input requests, round-trips.
        case payloadRoundTrip
        /// Other owners' tasks are invisible to `load`, `count` and `update`.
        case ownerIsolation
        /// `update` is compare-and-set: stale versions conflict, and of many concurrent
        /// updates of one version exactly one wins.
        case compareAndSet
        /// Terminal records never change again.
        case terminalImmutability
        /// Expired records are invisible before `expire` removes them, and `expire`
        /// removes at most `limit` per call.
        case expiry
        /// `unfinished` pages through non-terminal, unexpired records in ID order.
        case unfinishedPaging
        /// A record written through one instance is unchanged after reopening the storage.
        case durableAcrossReopen
    }

    public enum Outcome: Sendable, Hashable {
        case passed
        case failed(String)
        case skipped(String)
    }

    public struct Result: Sendable, Hashable {
        public let check: Check
        public let outcome: Outcome
    }

    private let makeStore: @Sendable () async throws -> any TaskStore
    private let reopen: (@Sendable (any TaskStore) async throws -> any TaskStore)?

    public init(makeStore: @escaping @Sendable () async throws -> any TaskStore,
                reopen: (@Sendable (any TaskStore) async throws -> any TaskStore)? = nil) {
        self.makeStore = makeStore; self.reopen = reopen
    }

    /// Runs every check, one after another.
    public func runAll() async -> [Result] {
        var results: [Result] = []
        for check in Check.allCases { results.append(await run(check)) }
        return results
    }

    /// Runs one check.
    public func run(_ check: Check) async -> Result {
        do {
            if check == .durableAcrossReopen, reopen == nil {
                return Result(check: check, outcome: .skipped("no reopen closure: the store is not durable"))
            }
            let store = try await makeStore()
            try await body(check)(store)
            return Result(check: check, outcome: .passed)
        } catch let failure as Failure {
            return Result(check: check, outcome: .failed(failure.message))
        } catch {
            return Result(check: check, outcome: .failed("unexpected error: \(error)"))
        }
    }

    private func body(_ check: Check) -> @Sendable (any TaskStore) async throws -> Void {
        switch check {
        case .createAndLoad: Self.createAndLoad
        case .payloadRoundTrip: Self.payloadRoundTrip
        case .ownerIsolation: Self.ownerIsolation
        case .compareAndSet: Self.compareAndSet
        case .terminalImmutability: Self.terminalImmutability
        case .expiry: Self.expiry
        case .unfinishedPaging: Self.unfinishedPaging
        case .durableAcrossReopen: { [reopen] store in try await Self.durable(store, reopen: reopen!) }
        }
    }

    // MARK: Fixtures

    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message: message()) }
    }

    static let alice = TaskOwner(issuer: "https://issuer.example", subject: "alice", resource: "https://mcp.example")
    static let bob = TaskOwner(issuer: "https://issuer.example", subject: "bob", resource: "https://mcp.example")
    /// A whole-millisecond base time.
    static let start = Date(timeIntervalSince1970: 1_800_000_000.123)

    static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    static func record(_ id: String, owner: TaskOwner = alice, expiresAfter seconds: Double = 3600,
                       status: TaskStatus = .working) -> TaskRecord {
        TaskRecord(id: id, owner: owner, created: start, expires: at(seconds), updated: start, status: status)
    }

    static func parse(_ text: String) throws -> JSON {
        try JSONParser(options: .init(limits: .balanced)).parseWithReport(Array(text.utf8)).result
    }

    // MARK: Checks

    static func createAndLoad(_ store: any TaskStore) async throws {
        try await store.create(record("t1"))
        let loaded = try await store.load(id: "t1", owner: alice, now: start)
        try require(loaded == record("t1"), "load returned \(String(describing: loaded))")
        try require(loaded?.version == 1, "a new record must have version 1")
        do {
            try await store.create(record("t1"))
            throw Failure(message: "a duplicate create succeeded")
        } catch let error as TaskStoreError {
            try require(error == .duplicate, "a duplicate create threw \(error) instead of duplicate")
        }
        try require(try await store.load(id: "missing", owner: alice, now: start) == nil, "an unknown ID loaded")
    }

    static func payloadRoundTrip(_ store: any TaskStore) async throws {
        try await store.create(record("p1"))
        var changed = record("p1")
        changed.updated = at(1.5)
        changed.status = .inputRequired
        changed.statusMessage = "Wähle 🦊 \u{0}"
        changed.inputRequests = [
            TaskInputRequest(key: "1", request: try parse(#"{"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object"}}}"#)),
            TaskInputRequest(key: "2", request: try parse(#"{"method":"sampling/createMessage","params":{"maxTokens":1e2,"n":-0.50}}"#)),
        ]
        changed.nextInput = 3
        changed.cancellationRequested = true
        guard case .updated(let version) = try await store.update(changed, expectedVersion: 1, now: at(1.5)), version == 2 else {
            throw Failure(message: "the first update did not store version 2")
        }
        let loaded = try await store.load(id: "p1", owner: alice, now: at(2))
        var expected = changed; expected = TaskRecord(id: expected.id, owner: expected.owner, created: expected.created,
            expires: expected.expires, updated: expected.updated, status: expected.status, statusMessage: expected.statusMessage,
            result: nil, failure: nil, inputRequests: expected.inputRequests, nextInput: 3, cancellationRequested: true, version: 2)
        try require(loaded == expected, "input-required state did not round-trip: \(String(describing: loaded))")

        var completed = expected
        completed.status = .completed; completed.inputRequests = []
        completed.result = try parse(#"{"content":[{"type":"text","text":"done"}],"structuredContent":{"big":12345678901234567890,"x":[true,null,1.0]}}"#)
        guard case .updated = try await store.update(completed, expectedVersion: 2, now: at(2)) else {
            throw Failure(message: "completing the task failed")
        }
        try require(try await store.load(id: "p1", owner: alice, now: at(3))?.result == completed.result, "the result did not round-trip")

        try await store.create(record("p2"))
        var failed = record("p2")
        failed.status = .failed; failed.failure = TaskFailure(code: -32001, message: "boom")
        _ = try await store.update(failed, expectedVersion: 1, now: at(1))
        try require(try await store.load(id: "p2", owner: alice, now: at(2))?.failure == failed.failure, "the failure did not round-trip")
    }

    static func ownerIsolation(_ store: any TaskStore) async throws {
        try await store.create(record("a1"))
        try await store.create(record("a2"))
        try await store.create(record("b1", owner: bob))
        try require(try await store.load(id: "a1", owner: bob, now: start) == nil, "bob loaded alice's task")
        let partial = TaskOwner(issuer: alice.issuer, subject: alice.subject, resource: "https://other.example")
        try require(try await store.load(id: "a1", owner: partial, now: start) == nil, "another resource loaded alice's task")
        try require(try await store.count(owner: alice, now: start) == 2, "alice's count is wrong")
        try require(try await store.count(owner: bob, now: start) == 1, "bob's count is wrong")
        try require(try await store.count(owner: nil, now: start) == 3, "the total count is wrong")
        var stolen = record("a1", owner: bob); stolen.status = .cancelled
        try require(try await store.update(stolen, expectedVersion: 1, now: start) == .notFound, "bob updated alice's task")
        try require(try await store.load(id: "a1", owner: alice, now: start)?.status == .working, "alice's task changed")
    }

    static func compareAndSet(_ store: any TaskStore) async throws {
        try await store.create(record("c1"))
        var first = record("c1"); first.statusMessage = "first"
        try require(try await store.update(first, expectedVersion: 1, now: start) == .updated(version: 2), "a current update failed")
        var stale = record("c1"); stale.statusMessage = "stale"
        try require(try await store.update(stale, expectedVersion: 1, now: start) == .conflict(currentVersion: 2), "a stale update did not conflict")
        try require(try await store.load(id: "c1", owner: alice, now: start)?.statusMessage == "first", "a stale update changed the record")

        let winners = try await withThrowingTaskGroup(of: TaskUpdateResult.self) { group in
            for index in 0..<16 {
                group.addTask {
                    var attempt = record("c1"); attempt.statusMessage = "racer \(index)"
                    return try await store.update(attempt, expectedVersion: 2, now: start)
                }
            }
            var results: [TaskUpdateResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        let updated = winners.filter { $0 == .updated(version: 3) }.count
        let conflicts = winners.filter { $0 == .conflict(currentVersion: 3) }.count
        try require(updated == 1 && conflicts == 15, "16 racers gave \(updated) updates and \(conflicts) conflicts")
        try require(try await store.load(id: "c1", owner: alice, now: start)?.version == 3, "the race left the wrong version")
    }

    static func terminalImmutability(_ store: any TaskStore) async throws {
        for (index, status) in [TaskStatus.completed, .failed, .cancelled].enumerated() {
            let id = "x\(index)"
            try await store.create(record(id))
            var terminal = record(id); terminal.status = status
            try require(try await store.update(terminal, expectedVersion: 1, now: start) == .updated(version: 2), "\(status) was not stored")
            var revived = terminal; revived.status = .working
            try require(try await store.update(revived, expectedVersion: 2, now: start) == .terminal, "a \(status) task changed again")
            try require(try await store.update(revived, expectedVersion: 1, now: start) == .conflict(currentVersion: 2),
                        "a stale update of a \(status) task did not conflict")
            try require(try await store.load(id: id, owner: alice, now: start)?.status == status, "a \(status) task changed")
        }
    }

    static func expiry(_ store: any TaskStore) async throws {
        for index in 0..<5 { try await store.create(record("e\(index)", expiresAfter: 10)) }
        try await store.create(record("live", expiresAfter: 100))
        let later = at(10)
        try require(try await store.load(id: "e0", owner: alice, now: later) == nil, "an expired task loaded")
        try require(try await store.load(id: "e0", owner: alice, now: at(9.999)) != nil, "a task expired early")
        try require(try await store.count(owner: alice, now: later) == 1, "expired tasks were counted")
        try require(try await store.count(owner: nil, now: later) == 1, "expired tasks were counted in the total")
        try require(try await store.update(record("e1"), expectedVersion: 1, now: later) == .notFound, "an expired task was updated")
        try require(try await store.unfinished(after: nil, limit: 10, now: later).map(\.id) == ["live"], "unfinished listed expired tasks")
        let first = try await store.expire(now: later, limit: 3)
        try require(first.count == 3 && Set(first).isSubset(of: ["e0", "e1", "e2", "e3", "e4"]), "the first expire batch was \(first)")
        let second = try await store.expire(now: later, limit: 3)
        try require(Set(first + second) == ["e0", "e1", "e2", "e3", "e4"], "the second expire batch was \(second)")
        try require(try await store.expire(now: later, limit: 3).isEmpty, "expire removed more than the expired tasks")
        try require(try await store.load(id: "live", owner: alice, now: later) != nil, "expire removed a live task")
        // An expired ID is free again only after removal; a store may reuse it then.
    }

    static func unfinishedPaging(_ store: any TaskStore) async throws {
        let ids = (0..<7).map { String(format: "u%02d", $0) }
        for id in ids.reversed() { try await store.create(record(id, owner: id == "u03" ? bob : alice)) }
        var done = record("u02"); done.status = .completed
        _ = try await store.update(done, expectedVersion: 1, now: start)
        var seen: [String] = []
        var cursor: String?
        while true {
            let page = try await store.unfinished(after: cursor, limit: 2, now: start)
            try require(page.count <= 2, "a page exceeded its limit")
            seen += page.map(\.id)
            guard page.count == 2 else { break }
            cursor = page.last?.id
        }
        try require(seen == ["u00", "u01", "u03", "u04", "u05", "u06"], "unfinished paged \(seen)")
    }

    static func durable(_ store: any TaskStore, reopen: @Sendable (any TaskStore) async throws -> any TaskStore) async throws {
        try await store.create(record("d1"))
        var changed = record("d1")
        changed.status = .inputRequired; changed.nextInput = 1
        changed.inputRequests = [TaskInputRequest(key: "0", request: try parse(#"{"method":"roots/list","params":{}}"#))]
        _ = try await store.update(changed, expectedVersion: 1, now: start)
        let before = try await store.load(id: "d1", owner: alice, now: start)
        let reopened = try await reopen(store)
        let after = try await reopened.load(id: "d1", owner: alice, now: start)
        try require(before != nil && after == before, "the record changed across reopen: \(String(describing: after))")
        try require(try await reopened.update(changed, expectedVersion: 2, now: start) == .updated(version: 3),
                    "the reopened store did not continue the version sequence")
    }
}
