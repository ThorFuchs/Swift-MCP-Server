// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer

/// The status of a task (Tasks extension, 2026-07-28).
public enum TaskStatus: String, Sendable, Codable, CaseIterable {
    case working, inputRequired = "input_required", completed, cancelled, failed
    /// `completed`, `failed` and `cancelled` are final; a store never changes them again.
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// The principal a task belongs to. Only the same issuer, subject and resource can see it.
public struct TaskOwner: Hashable, Sendable, Codable {
    public let issuer: String, subject: String, resource: String
    public init(issuer: String, subject: String, resource: String) {
        self.issuer = issuer; self.subject = subject; self.resource = resource
    }
    public init(_ principal: VerifiedPrincipal) {
        self.init(issuer: principal.issuer.description, subject: principal.subject.description, resource: principal.resource.description)
    }
    /// The owner as a principal without scopes, for owner-scoped delivery.
    var principal: VerifiedPrincipal {
        VerifiedPrincipal(subject: ScalarText(subject), issuer: ScalarText(issuer), resource: ScalarText(resource), scopes: [])
    }
}

/// One outstanding input request of a task.
public struct TaskInputRequest: Sendable, Equatable {
    public let key: String
    /// The MRTR `InputRequest` (`{"method": …, "params": …}`).
    public let request: JSON
    public init(key: String, request: JSON) { self.key = key; self.request = request }
}

/// The complete stored state of one task. `version` increases with every stored change
/// and is the compare-and-set token for `TaskStore.update`.
public struct TaskRecord: Sendable, Equatable {
    public let id: String
    public let owner: TaskOwner
    public let created: Date
    public let expires: Date
    public var updated: Date
    public var status: TaskStatus
    public var statusMessage: String?
    /// The final `CallToolResult` of a `completed` task.
    public var result: JSON?
    /// The JSON-RPC error of a `failed` task.
    public var failure: TaskFailure?
    /// Unanswered input requests, oldest first.
    public var inputRequests: [TaskInputRequest]
    /// The next input key number; keys are never reused, so an answered key stays answered.
    public var nextInput: Int
    /// Set by `tasks/cancel`; an instance running the work observes it through the store.
    public var cancellationRequested: Bool
    public internal(set) var version: Int64

    public init(id: String, owner: TaskOwner, created: Date, expires: Date, updated: Date, status: TaskStatus = .working,
                statusMessage: String? = nil, result: JSON? = nil, failure: TaskFailure? = nil,
                inputRequests: [TaskInputRequest] = [], nextInput: Int = 0, cancellationRequested: Bool = false, version: Int64 = 1) {
        self.id = id; self.owner = owner; self.created = created; self.expires = expires; self.updated = updated
        self.status = status; self.statusMessage = statusMessage; self.result = result; self.failure = failure
        self.inputRequests = inputRequests; self.nextInput = nextInput; self.cancellationRequested = cancellationRequested
        self.version = version
    }
}

/// The outcome of a compare-and-set update.
public enum TaskUpdateResult: Sendable, Equatable {
    /// Stored; the record now has this version.
    case updated(version: Int64)
    /// Another change came first; reload and retry.
    case conflict(currentVersion: Int64)
    /// The stored task is already terminal and was not changed.
    case terminal
    /// No such task (unknown, foreign or expired).
    case notFound
}

public enum TaskStoreError: Error, Sendable, Equatable {
    /// `create` with an ID that already exists.
    case duplicate
    /// A stored payload exceeds the store's size limits.
    case payloadTooLarge
    /// The store could not tell whether a write was committed (for example an I/O error
    /// during commit). The runtime resolves it by reading the task back.
    case outcomeUnknown
    /// The stored data cannot be read as a task (corrupt or from a newer schema).
    case invalidRecord
}

/// Durable state of tasks, owned by `TaskRuntime` (ADR-0004). The runtime executes work;
/// the store keeps state. Every operation is bounded and owner-scoped.
///
/// Requirements every implementation must meet (checked by the store conformance kit):
/// - `create` returns only once the record is durable; the runtime replies after it.
/// - `load` returns nil for unknown, expired and other owners' tasks alike.
/// - `update` is compare-and-set on `version` and never changes a terminal record.
/// - Expired records are invisible to `load`, `count` and `update` before `expire` removes them.
public protocol TaskStore: Sendable {
    /// Stores a new record (`version` 1). Throws `duplicate` for an existing ID.
    func create(_ record: TaskRecord) async throws
    /// The record if `owner` owns it and it has not expired at `now`.
    func load(id: String, owner: TaskOwner, now: Date) async throws -> TaskRecord?
    /// Replaces the record if its stored version equals `expectedVersion` and it is not
    /// terminal. The stored version becomes `expectedVersion + 1`.
    func update(_ record: TaskRecord, expectedVersion: Int64, now: Date) async throws -> TaskUpdateResult
    /// The number of unexpired tasks, of one owner or of all owners.
    func count(owner: TaskOwner?, now: Date) async throws -> Int
    /// Removes up to `limit` records that expired at `now` and returns their IDs.
    func expire(now: Date, limit: Int) async throws -> [String]
    /// Up to `limit` unexpired non-terminal records with IDs after `cursor`, in ID order,
    /// for the restart policy.
    func unfinished(after cursor: String?, limit: Int, now: Date) async throws -> [TaskRecord]
}

/// The default store: process memory only, so tasks do not survive a restart.
public actor InMemoryTaskStore: TaskStore {
    private var records: [String: TaskRecord] = [:]
    public init() {}

    public func create(_ record: TaskRecord) throws {
        guard records[record.id] == nil else { throw TaskStoreError.duplicate }
        var stored = record; stored.version = 1
        records[record.id] = stored
    }
    public func load(id: String, owner: TaskOwner, now: Date) -> TaskRecord? {
        guard let record = records[id], record.owner == owner, record.expires > now else { return nil }
        return record
    }
    public func update(_ record: TaskRecord, expectedVersion: Int64, now: Date) -> TaskUpdateResult {
        guard let stored = records[record.id], stored.owner == record.owner, stored.expires > now else { return .notFound }
        guard stored.version == expectedVersion else { return .conflict(currentVersion: stored.version) }
        guard !stored.status.isTerminal else { return .terminal }
        var next = record; next.version = expectedVersion + 1
        records[record.id] = next
        return .updated(version: next.version)
    }
    public func count(owner: TaskOwner?, now: Date) -> Int {
        records.values.reduce(0) { $0 + ($1.expires > now && (owner == nil || $1.owner == owner) ? 1 : 0) }
    }
    public func expire(now: Date, limit: Int) -> [String] {
        let expired = records.values.filter { $0.expires <= now }.map(\.id).sorted().prefix(max(0, limit))
        for id in expired { records[id] = nil }
        return Array(expired)
    }
    public func unfinished(after cursor: String?, limit: Int, now: Date) -> [TaskRecord] {
        Array(records.values.filter { record in
            !record.status.isTerminal && record.expires > now && (cursor.map { record.id > $0 } ?? true)
        }.sorted { $0.id < $1.id }.prefix(max(0, limit)))
    }
}
