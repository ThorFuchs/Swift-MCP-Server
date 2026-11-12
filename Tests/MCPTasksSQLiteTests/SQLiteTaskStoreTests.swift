// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPTasks
import MCPTasksSQLite
import MCPTasksTesting
import SQLiteSwift
import SQLiteSwiftTesting

/// A fresh directory per test, removed afterwards.
private func withDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tasks-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Owns the stores the kit opens so the test can close them.
private actor Opened {
    var stores: [SQLiteTaskStore] = []
    func add(_ store: SQLiteTaskStore) -> SQLiteTaskStore { stores.append(store); return store }
    func closeAll() async { for store in stores { await store.close() }; stores = [] }
}

private let owner = TaskOwner(issuer: "issuer", subject: "alice", resource: "server")

private func record(_ id: String) -> TaskRecord {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return TaskRecord(id: id, owner: owner, created: now, expires: now.addingTimeInterval(3600), updated: now)
}

@Suite struct SQLiteTaskStoreCases {
    @Test func passesTheTaskStoreConformanceKitIncludingReopen() async throws {
        try await withDirectory { directory in
            let opened = Opened()
            let counter = Counter()
            let kit = TaskStoreConformanceKit(makeStore: {
                let path = directory.appendingPathComponent("tasks-\(await counter.next()).sqlite").path
                return await opened.add(try await SQLiteTaskStore.open(path: path))
            }, reopen: { store in
                let sqlite = try #require(store as? SQLiteTaskStore)
                guard case .file(let path) = sqlite.database.configuration.storage else { throw CancellationError() }
                await sqlite.close()
                return await opened.add(try await SQLiteTaskStore.open(path: path))
            })
            for result in await kit.runAll() {
                #expect(result.outcome == .passed, "\(result.check): \(result.outcome)")
            }
            await opened.closeAll()
        }
    }

    @Test func passesSQLiteSwiftConformanceWithTheTaskSchema() async throws {
        try await withDirectory { directory in
            let kit = SQLiteConformanceKit(migrations: SQLiteTaskStore.migrations) { path in SQLiteConfiguration(path: path) }
            for result in await kit.runAll() {
                #expect(result.outcome == .passed, "\(result.check): \(result.outcome)")
            }
        }
    }

    @Test func oversizedPayloadsAreRejectedAndNothingIsStored() async throws {
        try await withDirectory { directory in
            let store = try await SQLiteTaskStore.open(path: directory.appendingPathComponent("t.sqlite").path, maximumPayloadBytes: 256)
            try await store.create(record("big"))
            var big = record("big")
            big.status = .completed
            big.result = .string(String(repeating: "x", count: 1024))
            await #expect(throws: TaskStoreError.payloadTooLarge) { try await store.update(big, expectedVersion: 1, now: big.created) }
            #expect(try await store.load(id: "big", owner: owner, now: big.created) == record("big"))
            await store.close()
        }
    }

    @Test func corruptRowsAreReportedAsInvalidRecords() async throws {
        try await withDirectory { directory in
            let store = try await SQLiteTaskStore.open(path: directory.appendingPathComponent("t.sqlite").path)
            try await store.create(record("bad"))
            try await store.database.write { (transaction) throws(SQLiteError) in
                try transaction.execute("UPDATE mcp_tasks SET input_requests = ? WHERE id = 'bad'", [.blob(Array("{not json".utf8))])
            }
            await #expect(throws: TaskStoreError.invalidRecord) { try await store.load(id: "bad", owner: owner, now: record("bad").created) }
            await store.close()
        }
    }

    @Test func aNewerSchemaIsRefusedWithoutTouchingTheFile() async throws {
        try await withDirectory { directory in
            let path = directory.appendingPathComponent("t.sqlite").path
            let store = try await SQLiteTaskStore.open(path: path)
            try await store.database.write { (transaction) throws(SQLiteError) in try transaction.execute("PRAGMA user_version = 99") }
            await store.close()
            await #expect(throws: SQLiteError.schemaTooNew(databaseVersion: 99, supportedVersion: 1)) { try await SQLiteTaskStore.open(path: path) }
        }
    }
}

private actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
