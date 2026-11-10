// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum EventOrigin: String, Codable, Sendable, CaseIterable { case localResearch = "Local research", externalMCP = "External MCP", server = "Server" }
public enum EventSeverity: String, Codable, Sendable, CaseIterable { case info = "Info", warning = "Warning", error = "Error" }
public enum EventOutcome: String, Codable, Sendable { case started, success, toolProblem, cancelled, failed, stopped }
public struct ActivityEvent: Identifiable, Codable, Sendable {
    public let id: UUID, runID: UUID?
    public let date: Date
    public let severity: EventSeverity, origin: EventOrigin
    public let component: String, operation: String, summary: String
    public let correlation: UUID?
    public let outcome: EventOutcome
    public let durationMilliseconds: Int64?
    public var logicalBytes: Int { 128 + component.utf8.count + operation.utf8.count + summary.utf8.count + severity.rawValue.utf8.count + origin.rawValue.utf8.count + outcome.rawValue.utf8.count }
    public var detail: String { "\(operation) · \(outcome.rawValue)\n\(summary)\nOrigin: \(origin.rawValue)\nRun: \(runID?.uuidString ?? "Not applicable")\nCorrelation: \(correlation?.uuidString ?? "Not supplied")\nDuration: \(durationMilliseconds.map { "\($0) ms" } ?? "Unavailable")\nPayload and credentials are not recorded." }
}
public struct ActivityFilter: Codable, Sendable, Equatable {
    public let search: String
    public let severity: EventSeverity?
    public let origin: EventOrigin?
    public let component: String?
    public init(search: String = "", severity: EventSeverity? = nil, origin: EventOrigin? = nil, component: String? = nil) {
        var bytes = Array(search.utf8.prefix(1024))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        self.search = String(decoding: bytes, as: UTF8.self)
        self.severity = severity; self.origin = origin
        self.component = component.map { ["Research", "MCP", "Server"].contains($0) ? $0 : "unknown" }
    }
    public func includes(_ event: ActivityEvent) -> Bool {
        (severity == nil || severity == event.severity) && (origin == nil || origin == event.origin) && (component == nil || component == event.component) && (search.isEmpty || event.operation.localizedCaseInsensitiveContains(search) || event.summary.localizedCaseInsensitiveContains(search))
    }
}
public struct RequestBucket: Identifiable, Sendable { public let slot: Int64; public let date: Date; public let calls: UInt64; public var id: Int64 { slot } }
public struct ActivitySnapshot: Sendable {
    public let events: [ActivityEvent], recentCalls: [ActivityEvent], buckets: [RequestBucket]
    public let runID: UUID?
    public let discarded: UInt64, retainedBytes: Int, active: Int
    public let completed: UInt64, failed: UInt64, cancelled: UInt64
    public let medianMilliseconds: Int64?, durationSampleCount: Int
    public let metricsPartial: Bool
    public var metricsAvailable: Bool { runID != nil }
    public static let empty = ActivitySnapshot(events: [], recentCalls: [], buckets: [], runID: nil, discarded: 0, retainedBytes: 0, active: 0, completed: 0, failed: 0, cancelled: 0, medianMilliseconds: nil, durationSampleCount: 0, metricsPartial: false)
}
public struct ActivityClock: Sendable {
    public let milliseconds: @Sendable () -> Int64
    public let wall: @Sendable () -> Date
    public init(milliseconds: @escaping @Sendable () -> Int64, wall: @escaping @Sendable () -> Date) { self.milliseconds = milliseconds; self.wall = wall }
    public static func continuous() -> Self {
        let origin = ContinuousClock.now
        return .init(milliseconds: {
            let c = origin.duration(to: .now).components
            return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
        }, wall: { Date() })
    }
}

public enum ActivityLifecycle: Sendable, Equatable {
    case joined, runFailed, cleanupUnresolved
    var outcome: EventOutcome { self == .joined ? .stopped : .failed }
    var summary: String {
        switch self {
        case .joined: "Server run joined."
        case .runFailed: "Server run failed and returned to its owner."
        case .cleanupUnresolved: "Shutdown did not settle; the app retains its server owner."
        }
    }
}
