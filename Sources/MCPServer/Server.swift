// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import JSON
import MCPProtocol

actor CursorStore {
    private(set) var current: CursorProtector
    init(_ current: CursorProtector) { self.current = current }
    func replace(_ next: CursorProtector) { current = next }
}
/// Opaque bounded correlation for transport cancellation and graceful stream closure. It grants
/// no method, capability or provider authority; dispatch revalidates the envelope.
public struct RequestCorrelation: Sendable, Hashable {
    let key: RequestKey
    let owner:ScalarText
}
/// Single-use prepared ingress. Native inspection and dispatch share the exact
/// same cumulative budget and subsystem ceilings; the transport cannot reset it.
public final class AdmittedIngress: Sendable {
    let owner: ScalarText
    let bytes: Data
    let raw: JSON?
    let principal: VerifiedPrincipal, origin: ScalarText
    let budget: RequestBudget, response: TerminalResponse
    private let used = Mutex(false)
    public let retainedBytes: Int
    public let correlation: RequestCorrelation?
    public let deadline: ContinuousClock.Instant
    public var byteCount: Int { bytes.count }
    /// Bounded telemetry classification, never provider or protocol authority.
    public var method: WireMethod? { raw?.objectValue?["method"]?.stringValue.flatMap(WireMethod.init(rawValue:)) }
    init(owner: ScalarText, bytes: Data, raw: JSON?, principal: VerifiedPrincipal, origin: ScalarText,
         budget: RequestBudget, response: TerminalResponse, retainedBytes: Int, correlation: RequestCorrelation?, deadline: ContinuousClock.Instant) {
        self.owner = owner; self.bytes = bytes; self.raw = raw; self.principal = principal; self.origin = origin
        self.budget = budget; self.response = response; self.retainedBytes = retainedBytes; self.correlation = correlation; self.deadline = deadline
    }
    func claim(owner: ScalarText) throws {
        guard self.owner == owner else { throw CoreFailure.invalidInput }
        try used.withLock { value in guard !value else { throw CoreFailure.duplicate }; value = true }
    }
    /// Cancel/expire a queued ingress without a reply. Repeated discard is safe;
    /// an already dispatched ticket cannot be discarded or reset by a transport.
    @discardableResult public func discard() async -> Bool {
        let accepted = used.withLock { value in if value { return false }; value = true; return true }
        if accepted { await budget.terminate() }; return accepted
    }
}
public enum IngressDisposition: Sendable {
    case request(AdmittedIngress)
    case notification(cancelled: RequestCorrelation?)
}
/// Modern server core. The host owns transport admission, authentication, keys,
/// clock, task lifetime and cooperative provider/sink callbacks.
public struct Server: Sendable {
    private let dispatcher: Dispatcher
    private let instrumentation: (any ServerRequestInstrumentation)?
    public let configuration: ServerConfiguration
    /// Frozen wire definitions every server prepares at construction. Shared with tests so a
    /// cold preparation of exactly this set is checked against the default preparation policy.
    static let preparedDefinitions: Set<FrozenWireDefinition> = {
        let methods: Set<WireMethod> = [.discover, .listTools, .callTool, .listResources, .listResourceTemplates,
            .readResource, .listPrompts, .getPrompt, .complete]
        var definitions = Set(methods.map(\.definition)); definitions.formUnion(methods.compactMap(\.resultDefinition))
        definitions.formUnion([.InputRequiredResult, .InputRequest, .ElicitResult, .CreateMessageResult, .ListRootsResult,
            .SubscriptionsListenRequest, .SubscriptionsListenResult, .SubscriptionsAcknowledgedNotification,
            .ProgressNotification, .LoggingMessageNotification, .ToolListChangedNotification, .ResourceListChangedNotification,
            .PromptListChangedNotification, .ResourceUpdatedNotification, .CancelledNotification, .Tool, .Resource, .ResourceTemplate, .Prompt, .ClientCapabilities, .Implementation, .RequestMetaObject, .ResultMetaObject, .Result, .NotificationMetaObject])
        return definitions
    }()
    public static func make(info: JSON, catalog: ServerCatalog, cursors: CursorProtector,
        configuration: ServerConfiguration? = nil, continuations: RequestStateProtector? = nil, events: EventPolicy? = nil,
        instrumentation: (any ServerRequestInstrumentation)? = nil, middleware: [RequestMiddleware] = []) async throws -> Self {
        guard middleware.count <= 32 else { throw CoreFailure.limit }
        let configuration = try configuration ?? ServerConfiguration()
        let eventPolicy = try events ?? EventPolicy()
        let budget = try configuration.preparation.budget()
        let definitions = Self.preparedDefinitions
        let wire = try await PreparedWire.prepare(definitions, budget: budget)
        guard try await wire.validate(info, as: .Implementation, budget: budget) else { throw CoreFailure.invalidInput }
        let snapshot = try await CatalogSnapshot.prepare(catalog, generation: 1, wire: wire, configuration: configuration, budget: budget)
        let dispatcher = try Dispatcher(configuration: configuration,
            admission: AdmissionController(activeLimit: configuration.activeRequests, queueLimit: configuration.queuedRequests),
            control: AdmissionController(activeLimit: 1, queueLimit: 1),
            inspection: AdmissionController(activeLimit: configuration.activeRequests, queueLimit: configuration.queuedRequests),
            ownership: RequestOwnership(perPrincipal: configuration.requestsPerPrincipal), buffers: BufferedWork(limit: configuration.bufferedBytes),
            catalogs: CatalogStore(snapshot, wireWeight: wire.logicalRetainedUpperBound), wire: wire, info: info,
            instance: ScalarText(UUID().uuidString), cursors: CursorStore(cursors), continuations: continuations, eventPolicy: eventPolicy, eventLedger: EventLedger(eventPolicy), subscriptions: SubscriptionHub(eventPolicy), publisher: AdmissionController(activeLimit: 1, queueLimit: 1), middleware: middleware)
        for relay in catalog.extensions.compactMap(\.relay) { relay.attach(dispatcher.subscriptions, work: configuration.requestWork) }
        return .init(dispatcher: dispatcher, instrumentation: instrumentation, configuration: configuration)
    }
    /// One bounded request/notification. Loss or cancellation is signaled by the
    /// caller cancelling this task or the sink throwing. No task is detached.
    public func dispatch(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText,
        mirror: RequestMirrorValidator? = nil, send: @escaping ResponseSink) async throws {
        try await observed(.init(method:nil,transport:.inProcess,principal:principal)) { observer in
            try await dispatcher.dispatch(bytes, principal: principal, origin: origin, mirror: mirror, send: send,observeError:observer)
        }
    }
    /// Multiple notifications followed by at most one terminal attempt. Modes
    /// exercise D02 ordering in-process; they do not implement real transports.
    public func dispatchEvents(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText,
        mode: DeliveryMode, mirror: RequestMirrorValidator? = nil, send: @escaping ResponseSink) async throws {
        try await observed(.init(method:nil,transport: mode == .stdio ? .stdio : .http,principal:principal)) { observer in
            try await dispatcher.dispatch(bytes, principal: principal, origin: origin, mirror: mirror, send: send, mode: mode,observeError:observer)
        }
    }
    public func publish(_ event: SubscriptionEvent, audience: SubscriptionAudience) async throws {
        let permit = try await dispatcher.publisher.acquire()
        do {
            // A host publication is independently admitted, with its own finite
            // filtering/copy account; subscriber encoding uses subscriber accounts.
            let budget = try RequestBudget(workUnits: configuration.requestWork)
            try await dispatcher.subscriptions.publish(event, audience: audience, budget: budget)
        }
        catch { try await dispatcher.publisher.release(permit); throw error }
        try await dispatcher.publisher.release(permit)
    }
    public func closeSubscriptions() async { await dispatcher.subscriptions.closeAll() }
    /// Close only this authenticated transport origin's streams.
    public func closeSubscriptions(for principal: VerifiedPrincipal, origin: ScalarText) async {
        await dispatcher.subscriptions.close(principal, origin: origin)
    }
    /// End only the subscription identified by this server's inspected ingress.
    /// A foreign server correlation cannot close a matching principal/origin/ID.
    @discardableResult public func closeSubscription(_ correlation:RequestCorrelation) async -> Bool {
        guard correlation.owner == dispatcher.instance else { return false }
        return await dispatcher.subscriptions.close(correlation.key)
    }
    public func revokeSubscriptions(for principal: VerifiedPrincipal) async { await dispatcher.subscriptions.revoke(principal) }
    /// Convenience for in-process consumers; notifications return nil.
    public func handle(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText,
        mirror: RequestMirrorValidator? = nil) async throws -> Data? {
        let output = Mutex<Data?>(nil)
        try await dispatch(bytes, principal: principal, origin: origin, mirror: mirror) { bytes in
            try output.withLock { value in
                guard value == nil else { throw CoreFailure.invalidOutput }; value = bytes
            }
        }
        return output.withLock { $0 }
    }
    /// Host adapters should route admitted cancellation notifications through
    /// this independent finite control path when the provider queue is full.
    public func cancel(id: RequestID, principal: VerifiedPrincipal, origin: ScalarText) async throws {
        try await dispatcher.cancel(id: id, principal: principal, origin: origin)
    }
    /// Independent bounded transport/control admission. Correlation supports
    /// cancellation of queued/validating frames without parsing or normalizing
    /// exact IDs again in a transport. Unknown cancellations retain no tombstone.
    /// Response copy/observer work is paid inside the original terminal reserve;
    /// defaults preserve direct/stdio accounting. Hosts cannot replenish it.
    public func inspectIngress(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, acceptNotifications: Bool = true, responseCopyMultiplier:UInt64 = 1,responseFixedWork:UInt64 = 0) async throws -> IngressDisposition {
        try await dispatcher.notification(bytes, principal:principal, origin:origin, acceptNotifications:acceptNotifications,responseCopyMultiplier:responseCopyMultiplier,responseFixedWork:responseFixedWork)
    }
    /// Consume a server-bound ingress once. No caller budget or identity override.
    public func dispatchEvents(_ ingress: AdmittedIngress, mode: DeliveryMode?,
        validate: RequestIngressValidator? = nil, validateEnvelope: RequestEnvelopeValidator? = nil, validateScopes: RequestScopeValidator? = nil, mirror: RequestMirrorValidator? = nil, observeError:ResponseErrorObserver? = nil,
        diagnosticTransport: DiagnosticTransport? = nil, send: @escaping ResponseSink) async throws {
        // Reject foreign tickets before exposing their typed identity to the
        // host's diagnostic facade. The original owner may still consume them.
        guard ingress.owner == dispatcher.instance else { throw CoreFailure.invalidInput }
        try await observed(.init(method:ingress.method,transport:diagnosticTransport ?? (mode == .stdio ? .stdio : mode == nil ? .inProcess : .http),principal:ingress.principal),errorObserver:observeError,unclaimed:ingress) { observer in
            try await dispatcher.dispatch(ingress, send:send, mode:mode, validate:validate, validateEnvelope:validateEnvelope, validateScopes:validateScopes, mirror:mirror,observeError:observer)
        }
    }
    public func replaceCatalog(_ catalog: ServerCatalog) async throws {
        try await dispatcher.catalogs.replace(catalog, wire: dispatcher.wire, configuration: configuration, budget: configuration.preparation.budget())
        for relay in catalog.extensions.compactMap(\.relay) { relay.attach(dispatcher.subscriptions, work: configuration.requestWork) }
    }
    /// Retaining an old key in the supplied ring admits its unexpired tokens.
    /// Changing epoch or removing that key rejects them. Each new Server also
    /// has a distinct catalog instance, including when identical keys are reused.
    public func replaceCursors(_ cursors: CursorProtector) async { await dispatcher.cursors.replace(cursors) }
    public struct Activity: Sendable {
        public let active: Int, queued: Int, requests: Int, leases: Int, bufferedBytes: Int
        public let inspections: Int, queuedInspections: Int
        public let generation: UInt64
        public let subscriptions: Int, eventBytes: Int
    }
    public var activity: Activity {
        get async { await .init(active: dispatcher.admission.activeCount, queued: dispatcher.admission.queuedCount,
            requests: dispatcher.ownership.activeCount, leases: dispatcher.catalogs.activeLeases,
            bufferedBytes: dispatcher.buffers.retainedBytes, inspections: dispatcher.inspection.activeCount,
            queuedInspections: dispatcher.inspection.queuedCount, generation: dispatcher.catalogs.generation,
            subscriptions: dispatcher.subscriptions.count, eventBytes: dispatcher.eventLedger.retained) }
    }
    /// Reject queued/future dispatches. Active caller-owned operations must be
    /// cancelled/joined by the host; this is not complete lifecycle drain.
    public func stopAdmission() async { await dispatcher.inspection.stop(); await dispatcher.admission.stop() }
    private func observed(_ request: DiagnosticRequest, errorObserver: ResponseErrorObserver? = nil, unclaimed:AdmittedIngress? = nil,
        operation: @escaping @Sendable (ResponseErrorObserver?) async throws -> Void) async throws {
        guard let instrumentation else { try await operation(errorObserver); return }
        struct Invocation { var called = false, completed = false, duplicate = false, closed = false; var error:(any Error)? }
        let state = Mutex(Invocation()), protocolFailure = Mutex(false)
        do {
            try await instrumentation.withRequest(request) {
                try state.withLock { value in
                    guard !value.closed, !value.called else { value.duplicate = true; throw CoreFailure.duplicate }; value.called = true
                }
                do {
                    try await operation { error in
                        protocolFailure.withLock { $0 = true }
                        if let errorObserver { await errorObserver(error) }
                    }
                } catch { state.withLock { $0.error = error }; throw error }
                state.withLock { $0.completed = true }
                return protocolFailure.withLock { $0 } ? .protocolError : .completed
            }
        } catch {
            state.withLock { $0.closed = true }
            if !state.withLock({ $0.called }), let unclaimed, unclaimed.owner == dispatcher.instance { await unclaimed.discard() }
            throw state.withLock { $0.error } ?? error
        }
        state.withLock { $0.closed = true }
        if let error = state.withLock({ $0.error }) { throw error }
        if state.withLock({ $0.duplicate }) { throw CoreFailure.duplicate }
        guard state.withLock({ $0.completed }) else {
            if let unclaimed, unclaimed.owner == dispatcher.instance { await unclaimed.discard() }
            throw CoreFailure.invalidOutput
        }
    }
}
