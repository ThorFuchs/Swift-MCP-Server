// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

public struct ExportSettlementFailure: Error, Sendable {
    public let primaryWasCancellation: Bool
    public let cleanupFailed = true
    public init(primaryWasCancellation: Bool) { self.primaryWasCancellation = primaryWasCancellation }
}
public enum ActivityExportFailure: Error, Sendable { case encodedLimit, busy, empty, cleanupFailed }
public enum ActivityExportEncoder {
    private struct Row: Encodable, Sendable {
        let id, timestampUTC, origin, component, operation, outcome, summary: String
        let runID, correlation: String?
        let durationMilliseconds: Int64?
    }
    private struct Document: Encodable, Sendable {
        let format = "WRE-activity-v1"
        let generatedUTC: String, filter: ActivityFilter
        let discarded: UInt64, metricsPartial: Bool
        let payloadRecorded = false
        let events: [Row]
    }
    public static func encode(_ snapshot: ActivitySnapshot, filter: ActivityFilter, generatedAt: Date = Date()) throws -> Data {
        let events = snapshot.events.filter(filter.includes)
        guard events.count <= 2000 else { throw ActivityExportFailure.encodedLimit }
        // Pay a conservative UTF8/escaping admission BEFORE constructing encoded output.
        let upper = events.reduce(4096) { $0 + 6 * $1.logicalBytes + 512 }
        guard upper <= 4_194_304 else { throw ActivityExportFailure.encodedLimit }
        try Task.checkCancellation()
        let formatter = ISO8601DateFormatter()
        let rows = events.map { event in Row(id: event.id.uuidString, timestampUTC: formatter.string(from: event.date), origin: event.origin.rawValue, component: event.component, operation: event.operation, outcome: event.outcome.rawValue, summary: event.summary, runID: event.runID?.uuidString, correlation: event.correlation?.uuidString, durationMilliseconds: event.durationMilliseconds) }
        let document = Document(generatedUTC: formatter.string(from: generatedAt), filter: filter, discarded: snapshot.discarded, metricsPartial: snapshot.metricsPartial, events: rows)
        var limits = JSONLimits.balanced; limits[.outputBytes] = 4_194_304
        let json = try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(document).result
        let bytes = try WireCodec.write(json, limits: limits).result
        guard bytes.count <= upper else { throw ActivityExportFailure.encodedLimit }
        return Data(bytes)
    }
}
public actor ActivityExportWriter {
    private var active = false
    private let beforeCommit: @Sendable () async throws -> Void
    public init(beforeCommit: @escaping @Sendable () async throws -> Void = {}) { self.beforeCommit = beforeCommit }
    public func encodeAndWrite(_ snapshot: ActivitySnapshot, filter: ActivityFilter, to destination: URL) async throws {
        let data = try ActivityExportEncoder.encode(snapshot, filter: filter)
        try await write(data, to: destination)
    }
    public func write(_ data: Data, to destination: URL) async throws {
        guard !active else { throw ActivityExportFailure.busy }
        guard data.count <= 4_194_304, destination.isFileURL else { throw ActivityExportFailure.encodedLimit }
        active = true; defer { active = false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wre-\(UUID().uuidString).tmp")
        do {
            try Task.checkCancellation()
            try data.write(to: temporary, options: .withoutOverwriting)
            try await beforeCommit(); try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch {
            let primary = error
            do {
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            } catch { throw ExportSettlementFailure(primaryWasCancellation: primary is CancellationError) }
            throw primary
        }
    }
}
