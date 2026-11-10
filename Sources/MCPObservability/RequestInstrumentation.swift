// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPServer
import MCPProtocol
import Logging
import Metrics
import ServiceContextModule

public enum InstrumentationFailure: Error, Sendable, Equatable { case invalidConfiguration, closed, activeRequests, capacity }

/// Host-injected logging/metrics/context, never a process-global bootstrap. All
/// dimensions are drawn from frozen methods plus unknown, three transports and
/// eight fixed outcomes. The private cache has a finite mathematical ceiling.
public actor RequestInstrumentation: ServerRequestInstrumentation {
    private struct Key: Hashable { let method: String, transport: String, outcome: String? }
    private let factory: any MetricsFactory
    private let logger: Logger, redaction: RedactionPolicy, maximumActive: Int
    private var counters: [Key: any CounterHandler] = [:]
    private var durations: [Key: any TimerHandler] = [:]
    private let activeGauge: any RecorderHandler
    private let gauges: [String: any RecorderHandler]
    private var active = 0, completed: UInt64 = 0, closed = false
    public struct Snapshot: Sendable { public let active: Int, instruments: Int; public let completed: UInt64, closed: Bool }
    public var snapshot: Snapshot { .init(active: active, instruments: counters.count + durations.count + gauges.count + 1, completed: completed, closed: closed) }
    public init(logger: Logger, metrics: any MetricsFactory, redaction: RedactionPolicy = .init(), maximumActive: Int = 1024) throws {
        guard (1...4096).contains(maximumActive) else { throw InstrumentationFailure.invalidConfiguration }
        var clean = logger; clean.handler.metadata = [:]; if clean.handler.metadataProvider != nil { clean.handler.metadataProvider = nil }
        self.logger = clean; factory = metrics; self.redaction = redaction; self.maximumActive = maximumActive
        activeGauge = metrics.makeRecorder(label: MetricNames.activeScopes, dimensions: [], aggregate: false)
        gauges = Dictionary(uniqueKeysWithValues: [MetricNames.handlers,MetricNames.subscriptions,MetricNames.bufferedBytes,MetricNames.eventBytes].map {
            ($0, metrics.makeRecorder(label: $0, dimensions: [], aggregate: false))
        })
    }
    private func counter(_ request: DiagnosticRequest, outcome: DiagnosticOutcome?) -> any CounterHandler {
        let key = Key(method: request.method?.rawValue ?? "unknown", transport: request.transport.rawValue, outcome: outcome?.rawValue)
        if let value = counters[key] { return value }
        var dimensions = [("method",key.method),("transport",key.transport)]
        if let outcome { dimensions.append(("outcome",outcome.rawValue)) }
        let value = factory.makeCounter(label: outcome == nil ? MetricNames.started : MetricNames.finished, dimensions: dimensions)
        counters[key] = value; return value
    }
    private func duration(_ request: DiagnosticRequest) -> any TimerHandler {
        let key = Key(method: request.method?.rawValue ?? "unknown", transport: request.transport.rawValue, outcome: nil)
        if let value = durations[key] { return value }
        let value = factory.makeTimer(label: MetricNames.duration, dimensions: [("method",key.method),("transport",key.transport)])
        value.preferDisplayUnit(.milliseconds); durations[key] = value; return value
    }
    public func withRequest(_ request: DiagnosticRequest,
        operation: @escaping @Sendable () async throws -> DiagnosticOutcome) async throws {
        try await withRequest(request, correlation: DiagnosticCorrelation(), operation: operation)
    }
    public func withRequest(_ request: DiagnosticRequest, correlation: DiagnosticCorrelation,
        operation: @escaping @Sendable () async throws -> DiagnosticOutcome) async throws {
        guard !closed else { throw InstrumentationFailure.closed }
        guard active < maximumActive else { throw InstrumentationFailure.capacity }
        try Task.checkCancellation()
        active += 1; activeGauge.record(Int64(active)); counter(request,outcome:nil).increment(by:1)
        let start = ContinuousClock.now
        // A fresh context deliberately discards untrusted/host inherited baggage.
        // Only verified typed identity and bounded local correlation propagate.
        var context = ServiceContext.topLevel
        context[TraceKey.self] = .init(correlation:correlation,request:request)
        logger.debug("MCP request started", metadata:redaction.metadata(request,outcome:nil,correlation:correlation))
        let outcome: DiagnosticOutcome
        do {
            outcome = try await ServiceContext.withValue(context) { try await operation() }
        } catch {
            finish(request, outcome:Self.outcome(error), correlation:correlation, start:start)
            throw error
        }
        finish(request,outcome:outcome,correlation:correlation,start:start)
    }
    private func finish(_ request:DiagnosticRequest,outcome:DiagnosticOutcome,correlation:DiagnosticCorrelation,start:ContinuousClock.Instant) {
        active -= 1; activeGauge.record(Int64(active)); if completed < UInt64.max { completed += 1 }
        counter(request,outcome:outcome).increment(by:1)
        let c = start.duration(to:.now).components
        let s = c.seconds.multipliedReportingOverflow(by:1_000_000_000)
        let n = s.partialValue.addingReportingOverflow(c.attoseconds / 1_000_000_000)
        duration(request).recordNanoseconds(s.overflow || n.overflow ? Int64.max : max(0,n.partialValue))
        logger.debug("MCP request finished",metadata:redaction.metadata(request,outcome:outcome,correlation:correlation))
    }
    private static func outcome(_ error: any Error) -> DiagnosticOutcome {
        if error is CancellationError { return .cancelled }
        if error is RequestAccessFailure { return .rejected }
        if let e = error as? CoreFailure {
            if e == .deadline { return .deadline }; if e == .disconnected { return .disconnected }
            if e == .insufficientScopes { return .rejected }; if e == .limit || e == .eventOverflow { return .limit }
        }
        if error is RequestBudget.Failure { return .limit }; return .failed
    }
    /// Logical activity values, no private IDs or high-cardinality dimensions.
    public func sample(_ server: Server) async throws {
        guard !closed else { throw InstrumentationFailure.closed }
        let a = await server.activity
        guard !closed else { throw InstrumentationFailure.closed }
        gauges[MetricNames.handlers]?.record(Int64(a.active)); gauges[MetricNames.subscriptions]?.record(Int64(a.subscriptions))
        gauges[MetricNames.bufferedBytes]?.record(Int64(a.bufferedBytes)); gauges[MetricNames.eventBytes]?.record(Int64(a.eventBytes))
    }
    /// Call after joined request owners. Active instruments are never destroyed
    /// beneath a suspended operation. Repeated successful close is idempotent.
    public func close() throws {
        guard !closed else { return }; guard active == 0 else { throw InstrumentationFailure.activeRequests }
        closed = true
        for value in counters.values { factory.destroyCounter(value) }
        for value in durations.values { factory.destroyTimer(value) }
        for value in gauges.values { factory.destroyRecorder(value) }; factory.destroyRecorder(activeGauge)
        counters.removeAll(); durations.removeAll()
    }
    deinit {
        if !closed {
            for value in counters.values { factory.destroyCounter(value) }
            for value in durations.values { factory.destroyTimer(value) }
            for value in gauges.values { factory.destroyRecorder(value) }; factory.destroyRecorder(activeGauge)
        }
    }
}
