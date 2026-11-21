// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Awaited projection, no unbounded stream or task per event. Production producers:
/// <=4 catalogue handlers, one Research worker and one lifecycle owner. There is
/// no additional pending-event queue; aggregates update before optional retention.
public actor ActivityStore {
    public enum Failure: Error, Sendable { case activeRun, staleRun }
    private let clock: ActivityClock
    private var events: [ActivityEvent] = [], recent: [ActivityEvent] = []
    private var bytes = 0, discarded: UInt64 = 0
    private var runID: UUID?
    private struct Call { let run: UUID, operation: String, start: Int64; let profile: SourceProfile }
    private var active: [UUID: Call] = [:]
    private var completed: UInt64 = 0, failed: UInt64 = 0, cancelled: UInt64 = 0
    private var partial = false, lastTick: Int64 = 0
    private var samples: [(tick: Int64, duration: Int64)] = []
    private var buckets: [Int64: UInt64] = [:]
    public init(clock: ActivityClock = .continuous()) { self.clock = clock }
    public func beginRun(_ id: UUID) throws {
        guard active.isEmpty else { throw Failure.activeRun }
        runID = id; completed = 0; failed = 0; cancelled = 0; partial = false
        samples.removeAll(); buckets.removeAll(); recent.removeAll()
        append(origin: .server, operation: "run", outcome: .started, summary: "A new app-owned server run was requested.")
    }
    public func markPartial() { partial = true }
    public func startCall(run id: UUID, operation: String, profile: SourceProfile = .offlineDemo) -> UUID? {
        guard runID == id, active.count < 128 else { partial = true; return nil }
        let token = UUID(), tick = now()
        active[token] = Call(run: id, operation: Self.operation(operation), start: tick, profile: profile)
        append(origin: .externalMCP, operation: operation, outcome: .started, summary: profile.rawValue + " eligible tool handler started.", correlation: token)
        return token
    }
    public func finishCall(_ token: UUID?, outcome: EventOutcome) {
        guard let token else { partial = true; return }
        guard let call = active.removeValue(forKey: token) else { return } // duplicate terminal cannot count twice
        guard call.run == runID else { partial = true; return }
        let tick = now(), duration = max(0, tick - call.start)
        if completed < .max { completed += 1 } else { partial = true }
        if outcome == .toolProblem || outcome == .failed { if failed < .max { failed += 1 } else { partial = true } }
        if outcome == .cancelled { if cancelled < .max { cancelled += 1 } else { partial = true } }
        samples.removeAll { tick - $0.tick > 300_000 }
        if samples.count == 512 { samples.removeFirst() }
        samples.append((tick, duration))
        let slot = tick / 5000
        buckets = buckets.filter { $0.key > slot - 60 }
        if buckets[slot, default: 0] < .max { buckets[slot, default: 0] += 1 } else { partial = true }
        let event = append(origin: .externalMCP, operation: call.operation, outcome: outcome, summary: call.profile.rawValue + " eligible tool handler reached its terminal path.", correlation: token, duration: duration)
        if recent.count == 50 { recent.removeFirst() }; recent.append(event)
    }
    public func localResearch(_ operation: String, success: Bool, profile: SourceProfile = .offlineDemo) {
        append(origin: .localResearch, operation: operation, outcome: success ? .success : .failed, summary: profile.rawValue + (success ? " research operation completed." : " research operation ended without a result."))
    }
    public func lifecycle(_ event: ActivityLifecycle) {
        append(origin: .server, operation: "lifecycle", outcome: event.outcome, summary: event.summary)
    }
    private func now() -> Int64 {
        let tick = clock.milliseconds()
        if tick < lastTick { partial = true }
        lastTick = max(lastTick, tick); return lastTick
    }
    @discardableResult private func append(origin: EventOrigin, operation: String, outcome: EventOutcome, summary: String, correlation: UUID? = nil, duration: Int64? = nil) -> ActivityEvent {
        let event = ActivityEvent(id: UUID(), runID: origin == .localResearch ? nil : runID, date: clock.wall(), severity: outcome == .failed || outcome == .toolProblem ? .error : outcome == .cancelled ? .warning : .info, origin: origin, component: origin == .server ? "Server" : origin == .externalMCP ? "MCP" : "Research", operation: Self.operation(operation), summary: Self.clip(summary, maximum: 1024), correlation: correlation, outcome: outcome, durationMilliseconds: duration)
        // All fields are projected before retention. No provider text/arguments/headers.
        guard event.logicalBytes <= 4096 else { if discarded < .max { discarded += 1 }; return event }
        while !events.isEmpty && (events.count >= 2000 || bytes + event.logicalBytes > 2_097_152) { bytes -= events.removeFirst().logicalBytes; if discarded < .max { discarded += 1 } }
        events.append(event); bytes += event.logicalBytes
        return event
    }
    public func snapshot() -> ActivitySnapshot {
        let tick = now(), wall = clock.wall(), slot = tick / 5000
        samples.removeAll { tick - $0.tick > 300_000 }; buckets = buckets.filter { $0.key > slot - 60 }
        let durations = samples.map(\.duration).sorted()
        let chart = (0..<60).map { offset -> RequestBucket in
            let index = slot - Int64(59 - offset)
            return .init(slot: index, date: wall.addingTimeInterval(Double(index * 5000 - tick) / 1000), calls: buckets[index, default: 0])
        }
        return .init(events: events, recentCalls: recent, buckets: chart, runID: runID, discarded: discarded, retainedBytes: bytes, active: active.count, completed: completed, failed: failed, cancelled: cancelled, medianMilliseconds: durations.isEmpty ? nil : durations[durations.count / 2], durationSampleCount: durations.count, metricsPartial: partial)
    }
    private static func operation(_ value: String) -> String {
        ["search_articles", "get_article_outline", "read_article_section", "get_section_references", "run", "lifecycle"].contains(value) ? value : "unknown"
    }
    private static func clip(_ value: String, maximum: Int) -> String {
        var bytes = Array(value.utf8.prefix(maximum))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
