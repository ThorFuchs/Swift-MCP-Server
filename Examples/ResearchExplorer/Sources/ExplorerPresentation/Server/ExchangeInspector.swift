// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import MCPClient
import ExplorerMCP

/// One real SDK exchange as the transport saw it: metadata and sizes only. No request or response
/// body, argument, header value, URL or error text is retained.
public struct ExchangeRecord: Sendable, Identifiable, Equatable {
    public enum Outcome: String, Sendable { case response = "Response", failed = "Failed", cancelled = "Cancelled" }
    public let id: Int
    /// JSON-RPC method, e.g. `server/discover`, `tools/list`, `tools/call`.
    public let method: String
    /// The tool name of a `tools/call`, only when it is one of this app's four catalogue tools.
    public let tool: String?
    public let requestBytes: Int
    /// Messages delivered for this request: notifications plus the final response.
    public let messages: Int
    public let responseBytes: Int
    public let outcome: Outcome
    public let milliseconds: Int
}

/// Session-bound, bounded store for `ExchangeRecord`s. Created per journey only when the user opted
/// in; never persisted or exported.
public final class ExchangeRecorder: Sendable {
    public static let capacity = 32
    private let state = Mutex((records: [ExchangeRecord](), next: 0, dropped: 0))
    public init() {}
    public var records: [ExchangeRecord] { state.withLock { $0.records } }
    public var dropped: Int { state.withLock { $0.dropped } }
    fileprivate func append(_ make: (Int) -> ExchangeRecord) {
        state.withLock { s in
            let id = s.next; s.next += 1
            if s.records.count < Self.capacity { s.records.append(make(id)) } else { s.dropped += 1 }
        }
    }
}

/// Wraps the real client transport and records each exchange it carries. It only observes: every
/// request and every delivered message passes through unchanged.
public struct InspectingTransport: ClientTransport {
    let base: any ClientTransport
    let recorder: ExchangeRecorder
    public init(_ base: any ClientTransport, recorder: ExchangeRecorder) { self.base = base; self.recorder = recorder }
    public var mirrorsToolParameters: Bool { base.mirrorsToolParameters }
    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let start = ContinuousClock.now
        let received = Mutex((messages: 0, bytes: 0))
        let tool = request.method == "tools/call" ? request.name.flatMap { MCPResearchClient.toolNames.contains($0) ? $0 : nil } : nil
        func finish(_ outcome: ExchangeRecord.Outcome) {
            let (messages, bytes) = received.withLock { ($0.messages, $0.bytes) }
            let elapsed = start.duration(to: .now).components
            let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            recorder.append { .init(id: $0, method: request.method, tool: tool, requestBytes: request.body.count,
                                    messages: messages, responseBytes: bytes, outcome: outcome, milliseconds: ms) }
        }
        do {
            try await base.exchange(request) { data in
                received.withLock { $0.messages += 1; $0.bytes += data.count }
                try await receive(data)
            }
            finish(.response)
        } catch {
            finish(error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }
}
