// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPTasks
import SQLiteSwift

/// A durable `TaskStore` in one SQLite file (ADR-0004), built on SQLiteSwift.
///
/// `create` and `update` return only after `COMMIT` succeeded with `synchronous=FULL`
/// (and `F_FULLFSYNC` on Apple platforms by default), so a task the runtime has
/// replied with survives a crash or power loss. The table is `STRICT`; timestamps are
/// stored in whole milliseconds; JSON payloads are stored as UTF-8 JSON text in BLOB
/// columns and parsed back under the same byte limit.
///
/// The store owns its database file: open one store per file and process, and call
/// `close()` before discarding it.
public final class SQLiteTaskStore: TaskStore {
    /// The schema migrations, numbered from 1. The store uses its own database file,
    /// so these are the file's complete migration list.
    public static let migrations: [SQLiteMigration] = [
        SQLiteMigration(version: 1, name: "create mcp_tasks", sql: """
            CREATE TABLE mcp_tasks (
                id TEXT PRIMARY KEY NOT NULL,
                issuer TEXT NOT NULL,
                subject TEXT NOT NULL,
                resource TEXT NOT NULL,
                created INTEGER NOT NULL,
                expires INTEGER NOT NULL,
                updated INTEGER NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('working', 'input_required', 'completed', 'cancelled', 'failed')),
                status_message TEXT,
                result BLOB,
                failure_code INTEGER,
                failure_message TEXT,
                input_requests BLOB NOT NULL,
                next_input INTEGER NOT NULL CHECK (next_input >= 0),
                cancellation_requested INTEGER NOT NULL CHECK (cancellation_requested IN (0, 1)),
                version INTEGER NOT NULL CHECK (version >= 1)
            ) STRICT, WITHOUT ROWID;
            CREATE INDEX mcp_tasks_owner ON mcp_tasks (issuer, subject, resource, expires);
            CREATE INDEX mcp_tasks_expires ON mcp_tasks (expires);
            """),
    ]

    /// The database the store writes to.
    public let database: SQLiteDatabase
    /// The largest stored JSON payload (`result`, or all input requests together), in bytes.
    public let maximumPayloadBytes: Int
    /// The largest stored row: both payloads plus 64 KiB for IDs, owner and messages.
    var rowBytes: Int { maximumPayloadBytes * 2 + 65536 }

    private init(database: SQLiteDatabase, maximumPayloadBytes: Int) {
        self.database = database; self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// Opens (and if needed creates and migrates) the task database described by `configuration`.
    ///
    /// - Parameter maximumPayloadBytes: The byte limit for one stored JSON payload. Writes
    ///   above it throw `TaskStoreError.payloadTooLarge`. Default 4 MiB.
    public static func open(_ configuration: SQLiteConfiguration, maximumPayloadBytes: Int = 4 << 20) async throws -> SQLiteTaskStore {
        guard maximumPayloadBytes > 0, maximumPayloadBytes * 2 + 65536 <= configuration.limits.hardMaxResultBytes else {
            throw SQLiteError.invalidConfiguration("maximumPayloadBytes must be positive and fit twice, plus 64 KiB, into limits.hardMaxResultBytes")
        }
        let database = try await SQLiteDatabase.open(configuration, migrations: migrations)
        return SQLiteTaskStore(database: database, maximumPayloadBytes: maximumPayloadBytes)
    }

    /// Opens the task database at `path` with SQLiteSwift's durable defaults.
    public static func open(path: String, maximumPayloadBytes: Int = 4 << 20) async throws -> SQLiteTaskStore {
        try await open(SQLiteConfiguration(path: path), maximumPayloadBytes: maximumPayloadBytes)
    }

    /// Closes the database; later operations throw.
    public func close() async { await database.close() }

    // MARK: TaskStore

    public func create(_ record: TaskRecord) async throws {
        let row = try Row(record, limit: maximumPayloadBytes, rowBytes: rowBytes)
        let inserted = try await commit { (transaction) throws(SQLiteError) -> Bool in
            guard try transaction.scalar("SELECT 1 FROM mcp_tasks WHERE id = ?", [.text(record.id)]) == nil else { return false }
            try transaction.execute("""
                INSERT INTO mcp_tasks (id, issuer, subject, resource, created, expires, updated, status, status_message,
                    result, failure_code, failure_message, input_requests, next_input, cancellation_requested, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """, [.text(record.id), .text(record.owner.issuer), .text(record.owner.subject), .text(record.owner.resource),
                      Self.milliseconds(record.created), Self.milliseconds(record.expires)] + row.values)
            return true
        }
        guard inserted else { throw TaskStoreError.duplicate }
    }

    public func load(id: String, owner: TaskOwner, now: Date) async throws -> TaskRecord? {
        let bytes = rowBytes
        let found = try await translate { [database] () async throws(SQLiteError) -> SQLiteRow? in
            try await database.read { (transaction) throws(SQLiteError) in
                try transaction.queryOne("SELECT \(Self.columns) FROM mcp_tasks WHERE id = ? AND issuer = ? AND subject = ? AND resource = ? AND expires > ?",
                    [.text(id), .text(owner.issuer), .text(owner.subject), .text(owner.resource), Self.milliseconds(now)], maxBytes: bytes)
            }
        }
        return try found.map { try Self.record(from: $0, limit: maximumPayloadBytes) }
    }

    public func update(_ record: TaskRecord, expectedVersion: Int64, now: Date) async throws -> TaskUpdateResult {
        let row = try Row(record, limit: maximumPayloadBytes, rowBytes: rowBytes)
        let owner = record.owner
        return try await commit { (transaction) throws(SQLiteError) -> TaskUpdateResult in
            // Unknown, foreign and expired records are all `notFound`, before any version check.
            guard try transaction.scalar("SELECT 1 FROM mcp_tasks WHERE id = ? AND issuer = ? AND subject = ? AND resource = ? AND expires > ?",
                    [.text(record.id), .text(owner.issuer), .text(owner.subject), .text(owner.resource), Self.milliseconds(now)]) != nil
            else { return .notFound }
            let assignments = zip(Self.mutableColumns, row.values).map { SQLiteAssignment(SQLiteIdentifier($0), $1) }
            switch try transaction.compareAndSet(table: "mcp_tasks", id: .text(record.id), expectedVersion: expectedVersion,
                    assignments: assignments, alsoRequire: .notIn("status", Self.terminal)) {
            case .updated(let version): return .updated(version: version)
            case .conflict(let version): return .conflict(currentVersion: version)
            case .guardFailed: return .terminal
            case .notFound: return .notFound
            }
        }
    }

    public func count(owner: TaskOwner?, now: Date) async throws -> Int {
        let value = try await translate { [database] () async throws(SQLiteError) -> SQLiteValue? in
            try await database.read { (transaction) throws(SQLiteError) in
                if let owner {
                    try transaction.scalar("SELECT count(*) FROM mcp_tasks WHERE issuer = ? AND subject = ? AND resource = ? AND expires > ?",
                        [.text(owner.issuer), .text(owner.subject), .text(owner.resource), Self.milliseconds(now)])
                } else {
                    try transaction.scalar("SELECT count(*) FROM mcp_tasks WHERE expires > ?", [Self.milliseconds(now)])
                }
            }
        }
        guard case .integer(let count) = value else { throw TaskStoreError.invalidRecord }
        return Int(count)
    }

    public func expire(now: Date, limit: Int) async throws -> [String] {
        guard limit > 0 else { return [] }
        let batch = min(limit, SQLitePredicate.maxListCount)
        return try await commit { (transaction) throws(SQLiteError) -> [String] in
            let rows = try transaction.query("SELECT id FROM mcp_tasks WHERE expires <= ? ORDER BY id LIMIT ?",
                [Self.milliseconds(now), .integer(Int64(batch))], limits: SQLiteQueryLimits(maxRows: batch))
            var ids: [String] = []
            for row in rows { ids.append(try row.text(0)) }
            guard !ids.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            try transaction.execute("DELETE FROM mcp_tasks WHERE expires <= ? AND id IN (\(placeholders))",
                [Self.milliseconds(now)] + ids.map { .text($0) })
            return ids
        }
    }

    public func unfinished(after cursor: String?, limit: Int, now: Date) async throws -> [TaskRecord] {
        guard limit > 0 else { return [] }
        let bytes = rowBytes
        // IDs first, then each row under the per-row budget, all in one snapshot.
        let rows = try await translate { [database] () async throws(SQLiteError) -> [SQLiteRow] in
            try await database.read { (transaction) throws(SQLiteError) in
                let ids = try transaction.query("""
                    SELECT id FROM mcp_tasks
                    WHERE status NOT IN ('completed', 'failed', 'cancelled') AND expires > ? AND (? IS NULL OR id > ?)
                    ORDER BY id LIMIT ?
                    """, [Self.milliseconds(now), cursor.map(SQLiteValue.text) ?? .null, cursor.map(SQLiteValue.text) ?? .null, .integer(Int64(limit))],
                    limits: SQLiteQueryLimits(maxRows: limit))
                var rows: [SQLiteRow] = []
                for id in ids {
                    if let row = try transaction.queryOne("SELECT \(Self.columns) FROM mcp_tasks WHERE id = ?", [id[0]], maxBytes: bytes) { rows.append(row) }
                }
                return rows
            }
        }
        return try rows.map { try Self.record(from: $0, limit: maximumPayloadBytes) }
    }

    // MARK: Encoding

    private static let terminal: [SQLiteValue] = [.text("completed"), .text("failed"), .text("cancelled")]
    private static let columns = """
        id, issuer, subject, resource, created, expires, updated, status, status_message, result, failure_code, \
        failure_message, input_requests, next_input, cancellation_requested, version
        """
    /// The columns `update` replaces, in `Row.values` order.
    private static let mutableColumns = ["updated", "status", "status_message", "result", "failure_code", "failure_message",
                                         "input_requests", "next_input", "cancellation_requested"]

    /// The mutable part of a record as SQLite values, in `mutableColumns` order.
    private struct Row {
        let values: [SQLiteValue]
        init(_ record: TaskRecord, limit: Int, rowBytes: Int) throws {
            let inputs = JSON.array(record.inputRequests.map { .array([.string($0.key), $0.request]) })
            values = [
                SQLiteTaskStore.milliseconds(record.updated),
                .text(record.status.rawValue),
                record.statusMessage.map(SQLiteValue.text) ?? .null,
                try record.result.map { .blob(try SQLiteTaskStore.encode($0, limit: limit)) } ?? .null,
                record.failure.map { .integer(Int64($0.code)) } ?? .null,
                record.failure.map { .text($0.message) } ?? .null,
                .blob(try SQLiteTaskStore.encode(inputs, limit: limit)),
                .integer(Int64(record.nextInput)),
                .integer(record.cancellationRequested ? 1 : 0),
            ]
            let fixed = [record.id, record.owner.issuer, record.owner.subject, record.owner.resource].reduce(0) { $0 + $1.utf8.count }
            guard values.reduce(fixed + 64) { $0 + $1.byteCount } <= rowBytes else { throw TaskStoreError.payloadTooLarge }
        }
    }

    private static func milliseconds(_ date: Date) -> SQLiteValue {
        .integer(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func limits(_ bytes: Int) -> JSONLimits {
        var limits = JSONLimits.balanced
        limits[.inputBytes] = UInt64(bytes); limits[.outputBytes] = UInt64(bytes)
        return limits
    }

    private static func encode(_ value: JSON, limit: Int) throws -> [UInt8] {
        do { return Array(try WireCodec.write(value, limits: limits(limit)).result) }
        catch let failure as JSONFailure where failure.category == .resource { throw TaskStoreError.payloadTooLarge }
    }

    private static func decode(_ bytes: [UInt8], limit: Int) throws -> JSON {
        do { return try WireCodec.parse(bytes, limits: limits(limit)).result }
        catch { throw TaskStoreError.invalidRecord }
    }

    private static func record(from row: SQLiteRow, limit: Int) throws -> TaskRecord {
        do {
            guard let status = TaskStatus(rawValue: try row.text(7)) else { throw TaskStoreError.invalidRecord }
            let failure: TaskFailure? = try row.optionalInteger(10).map { code in
                TaskFailure(code: Int(code), message: try row.optionalText(11) ?? "")
            }
            guard case .array(let pairs) = try decode(try row.blob(12), limit: limit) else { throw TaskStoreError.invalidRecord }
            let inputs = try pairs.map { pair -> TaskInputRequest in
                guard case .array(let parts) = pair, parts.count == 2, case .string(let key) = parts[0] else { throw TaskStoreError.invalidRecord }
                return TaskInputRequest(key: key, request: parts[1])
            }
            return TaskRecord(
                id: try row.text(0),
                owner: TaskOwner(issuer: try row.text(1), subject: try row.text(2), resource: try row.text(3)),
                created: date(try row.integer(4)), expires: date(try row.integer(5)), updated: date(try row.integer(6)),
                status: status, statusMessage: try row.optionalText(8),
                result: try row.optionalBlob(9).map { try decode($0, limit: limit) },
                failure: failure, inputRequests: inputs, nextInput: Int(try row.integer(13)),
                cancellationRequested: try row.integer(14) != 0, version: try row.integer(15))
        } catch let error as SQLiteError where error.code == .typeMismatch {
            throw TaskStoreError.invalidRecord
        }
    }

    // MARK: Error mapping

    /// Runs a write transaction; an unknown commit outcome becomes `TaskStoreError.outcomeUnknown`.
    private func commit<T: Sendable>(_ body: @escaping @Sendable (SQLiteTransaction) throws(SQLiteError) -> T) async throws -> T {
        try await translate { [database] () async throws(SQLiteError) -> T in try await database.write(body) }
    }

    private func translate<T: Sendable>(_ operation: () async throws(SQLiteError) -> T) async throws -> T {
        do { return try await operation() }
        catch {
            switch error.code {
            case .commitOutcomeUnknown: throw TaskStoreError.outcomeUnknown
            case .resultTooLarge, .tooBig: throw TaskStoreError.payloadTooLarge
            case .interrupted: throw CancellationError()
            default: throw error
            }
        }
    }
}
