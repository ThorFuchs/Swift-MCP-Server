// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import JSON
import MCPProtocol
@testable import ExplorerPresentation

struct ActivityTests {
    @Test func T08_T09_burstRetentionDoesNotLoseTerminalCounters() async throws {
        let store = ActivityStore(); let run = UUID(); try await store.beginRun(run)
        for _ in 0..<2100 { await store.localResearch("search_articles", success: true) }
        let token = await store.startCall(run: run, operation: "get_article_outline")
        await store.finishCall(token, outcome: .cancelled); await store.finishCall(token, outcome: .success)
        let s = await store.snapshot()
        #expect(s.events.count <= 2000 && s.retainedBytes <= 2_097_152 && s.discarded > 0)
        #expect(s.active == 0 && s.completed == 1 && s.failed == 0 && s.cancelled == 1)
        #expect(s.events.allSatisfy { $0.logicalBytes <= 4096 && $0.summary.utf8.count <= 1024 })
    }
    @Test func T09_T10_allTerminalsLocalExclusionAndObservationLoss() async throws {
        let store = ActivityStore()
        #expect(!(await store.snapshot()).metricsAvailable)
        let run = UUID(); try await store.beginRun(run)
        for outcome in [EventOutcome.success, .toolProblem, .failed, .cancelled] {
            let id = await store.startCall(run: run, operation: "read_article_section")
            await store.finishCall(id, outcome: outcome)
        }
        await store.localResearch("read_article_section", success: false)
        let s = await store.snapshot()
        #expect(s.completed == 4 && s.failed == 2 && s.cancelled == 1 && s.active == 0)
        _ = await store.startCall(run: UUID(), operation: "search_articles")
        #expect((await store.snapshot()).metricsPartial)
    }
    @Test func T11_T12_filteringDoesNotMutateAndEvictionIsObservableByID() async {
        let store = ActivityStore(); await store.localResearch("search_articles", success: true)
        let original = await store.snapshot(); let selected = original.events.first?.id
        let empty = original.events.filter(ActivityFilter(search: "unmatched").includes)
        #expect(empty.isEmpty); #expect((await store.snapshot()).events.count == 1)
        for _ in 0..<2001 { await store.localResearch("get_article_outline", success: true) }
        #expect(!(await store.snapshot()).events.contains { $0.id == selected })
    }
    @Test func T13_exportRedactionAdmissionAndCancellationLeaveNoPartial() async throws {
        let store = ActivityStore(); await store.localResearch("Bearer private-body", success: false)
        let snapshot = await store.snapshot()
        let data = try ActivityExportEncoder.encode(snapshot, filter: .init())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("Bearer") && !text.contains("private-body") && text.contains("payloadRecorded"))
        let parsed = try WireCodec.parse(Array(data), limits: .balanced).result
        #expect(parsed.objectValue?["payloadRecorded"]?.booleanValue == false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = ActivityExportWriter(), destination = dir.appendingPathComponent("events.json")
        try await writer.write(data, to: destination)
        #expect(try Data(contentsOf: destination) == data)
        let gate = ExportGate()
        let heldWriter = ActivityExportWriter(beforeCommit: { await gate.hold() })
        let task = Task { try await heldWriter.write(data, to: dir.appendingPathComponent("cancelled.json")) }
        await gate.waitEntered()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".tmp") })
        task.cancel(); await gate.release()
        do { try await task.value; Issue.record("Cancelled export unexpectedly completed") } catch is CancellationError {} catch { Issue.record("Wrong cancellation error") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["events.json"])
    }
    @Test func T14_clockWallChangesAndRunBoundariesDoNotCorruptDurations() async throws {
        let ticks = Mutex<Int64>(0), wall = Mutex(Date(timeIntervalSince1970: 1000))
        let store = ActivityStore(clock: .init(milliseconds: { ticks.withLock { $0 } }, wall: { wall.withLock { $0 } }))
        let run = UUID(); try await store.beginRun(run)
        let id = await store.startCall(run: run, operation: "search_articles")
        ticks.withLock { $0 = 184 }; wall.withLock { $0 = Date(timeIntervalSince1970: 1) }
        await store.finishCall(id, outcome: .success)
        let s = await store.snapshot()
        #expect(s.medianMilliseconds == 184 && s.buckets.count == 60 && s.buckets.reduce(UInt64(0)) { $0 + $1.calls } == 1)
        try await store.beginRun(UUID())
        let next = await store.snapshot()
        #expect(next.completed == 0 && next.recentCalls.isEmpty && next.events.contains { $0.runID == run })
    }
    @Test func T13_exportRejectsConservativeEscapingOverflow() async throws {
        let row = ActivityEvent(id: UUID(), runID: nil, date: Date(), severity: .info, origin: .localResearch, component: "Research", operation: "search_articles", summary: String(repeating: "\u{0001}", count: 1024), correlation: nil, outcome: .success, durationMilliseconds: nil)
        let snapshot = ActivitySnapshot(events: Array(repeating: row, count: 2000), recentCalls: [], buckets: [], runID: nil, discarded: 0, retainedBytes: 2_097_152, active: 0, completed: 0, failed: 0, cancelled: 0, medianMilliseconds: nil, durationSampleCount: 0, metricsPartial: false)
        do { _ = try ActivityExportEncoder.encode(snapshot, filter: .init()); Issue.record("Expected conservative denial") }
        catch ActivityExportFailure.encodedLimit {} catch { Issue.record("Wrong export failure") }
    }
    @Test func T08_activeTrackingOverflowMarksPartialWithoutInventedCompletion() async throws {
        let store = ActivityStore(); let run = UUID(); try await store.beginRun(run)
        var handles: [UUID?] = []
        for _ in 0..<129 { handles.append(await store.startCall(run: run, operation: "search_articles")) }
        let active = await store.snapshot(); #expect(active.active == 128 && active.metricsPartial)
        for h in handles { await store.finishCall(h, outcome: .success) }
        let ended = await store.snapshot(); #expect(ended.active == 0 && ended.completed == 128 && ended.metricsPartial)
    }
}

private actor ExportGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { pending = $0; entered = true; waiter?.resume(); waiter = nil } }
    func waitEntered() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { pending?.resume(); pending = nil }
}
