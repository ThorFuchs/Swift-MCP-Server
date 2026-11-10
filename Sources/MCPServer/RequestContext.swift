// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
import Synchronization

final class RequestCancellation: Sendable {
    enum Reason: Sendable { case cancelled, deadline }
    private let state = Mutex<Reason?>(nil)
    func cancel(_ reason: Reason = .cancelled) { state.withLock { if $0 == nil { $0 = reason } } }
    var reason: Reason? { state.withLock { $0 } }
    var cancelled: Bool { reason != nil }
}
/// Trace fields validated as request metadata. These are caller-provided
/// diagnostic data, never identity, authority, metric labels, or automatic logs.
public struct RequestTraceContext: Sendable {
    public let traceparent: String?
    public let tracestate: String?
    public let baggage: String?
    static func extract(_ metadata: JSONObject, budget: RequestBudget) async throws -> Self? {
        // Charge the examined keys on the request account before lookup.
        for member in metadata { try await budget.consume(UInt64(member.key.string.utf8.count + 1) * 3) }
        let parent = metadata["traceparent"]?.stringValue
        let state = metadata["tracestate"]?.stringValue
        let baggage = metadata["baggage"]?.stringValue
        guard parent != nil || state != nil || baggage != nil else { return nil }
        return .init(traceparent: parent, tracestate: state, baggage: baggage)
    }
}
public struct RequestContext: Sendable {
    /// Dispatch admits only this frozen version; no negotiated session exists.
    public var protocolVersion: ScalarText { ScalarText(ProtocolMetadata.version) }
    public let principal: VerifiedPrincipal
    public let origin: ScalarText
    public let id: RequestID
    public let method: RequestMethod
    public let capabilities: JSONObject
    public let extensions: JSONObject
    public let generation: UInt64
    public let deadline: ContinuousClock.Instant
    public let budget: RequestBudget
    /// Validated request metadata, available only after request validation.
    public let traceContext: RequestTraceContext?
    /// The exact admitted modern progress token, when this dispatch has an
    /// event channel. Reading it does not transfer emission/terminal ownership.
    public var progressToken: RequestID? { events?.token }
    let cancellation: RequestCancellation
    let events: RequestEvents?
    let scopeValidator:RequestScopeValidator?
    let extensionRegistry: ExtensionRegistry
    /// Exact finite numbers; missing event channel/token is an explicit failure.
    @discardableResult public func progress(_ value: JSONNumber, total: JSONNumber? = nil, message: String? = nil) async throws -> Bool {
        try checkCancellation(); guard let events else { throw CoreFailure.eventsUnavailable }
        return try await events.progress(value, total: total, message: message)
    }
    @discardableResult public func log(_ level: ProtocolLogLevel, data: JSON, logger: String? = nil) async throws -> Bool {
        try checkCancellation(); guard let events else { return false }
        return try await events.log(level, data: data, logger: logger)
    }
    /// Supplemental notifications require the active request's declared extension.
    /// The server owns validation, queue admission and terminal/cancellation state.
    public func notify(extensionMethod: ScalarText, parameters: JSON) async throws {
        try checkCancellation()
        guard let events, let plan = extensionRegistry.notifications[extensionMethod],
              extensions[plan.namespace.description] != nil else { throw CoreFailure.missingCapability }
        try await events.notification(plan, parameters: parameters)
    }
    public func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellation.reason == .deadline { throw CoreFailure.deadline }
        if cancellation.cancelled { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw CoreFailure.deadline }
    }
}
