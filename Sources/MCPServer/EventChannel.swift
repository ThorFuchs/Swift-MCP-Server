// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

public enum DeliveryMode: Sendable { case stdio, http }
public struct EventPolicy: Sendable {
    public let queuedEvents: Int, queuedBytes: Int, globalBytes: Int, principalBytes: Int, notificationBytes: Int
    public let maximumEvents: Int, subscriptions: Int, subscriptionsPerPrincipal: Int, filters: Int
    public let subscriptionLifetimeMilliseconds: Int64, progressIntervalMilliseconds: Int64, logIntervalMilliseconds: Int64
    let clock: @Sendable () -> Int64
    let logRedactor: (@Sendable (JSON) async throws -> JSON)?
    /// A redactor opts in to deprecated protocol logging. Nil disables it.
    public init(queuedEvents: Int = 64, queuedBytes: Int = 262144, globalBytes: Int = 16777216,
        principalBytes: Int = 1048576, notificationBytes: Int = 262144, maximumEvents: Int = 4096,
        subscriptions: Int = 32, subscriptionsPerPrincipal: Int = 16, filters: Int = 256,
        subscriptionLifetimeMilliseconds: Int64 = 60000, progressIntervalMilliseconds: Int64 = 40,
        logIntervalMilliseconds: Int64 = 50, clock: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1000000) },
        logRedactor: (@Sendable (JSON) async throws -> JSON)? = nil) throws {
        guard queuedEvents > 0, queuedEvents <= 1024, queuedBytes > 0, queuedBytes <= 16777216,
              globalBytes >= queuedBytes, globalBytes <= 268435456, principalBytes >= queuedBytes, principalBytes <= globalBytes,
              notificationBytes > 0, notificationBytes <= queuedBytes, maximumEvents > 0, maximumEvents <= 100000,
              subscriptions > 0, subscriptions <= 1024, subscriptionsPerPrincipal > 0, subscriptionsPerPrincipal <= subscriptions,
              filters > 0, filters <= 1024, subscriptionLifetimeMilliseconds > 0, subscriptionLifetimeMilliseconds <= 3600000,
              progressIntervalMilliseconds > 0, logIntervalMilliseconds > 0 else { throw CoreFailure.invalidPolicy }
        self.queuedEvents = queuedEvents; self.queuedBytes = queuedBytes; self.globalBytes = globalBytes
        self.principalBytes = principalBytes; self.notificationBytes = notificationBytes; self.maximumEvents = maximumEvents
        self.subscriptions = subscriptions; self.subscriptionsPerPrincipal = subscriptionsPerPrincipal; self.filters = filters
        self.subscriptionLifetimeMilliseconds = subscriptionLifetimeMilliseconds
        self.progressIntervalMilliseconds = progressIntervalMilliseconds; self.logIntervalMilliseconds = logIntervalMilliseconds
        self.clock = clock; self.logRedactor = logRedactor
    }
}
actor EventLedger {
    struct Ticket: Sendable { let id: UUID, principal: PrincipalKey, bytes: Int }
    let policy: EventPolicy
    private var tickets: [UUID: Ticket] = [:], principals: [PrincipalKey: Int] = [:]
    private(set) var retained = 0
    init(_ policy: EventPolicy) { self.policy = policy }
    func reserve(_ bytes: Int, principal: PrincipalKey) throws -> Ticket {
        guard tickets.count < 4096, bytes <= policy.globalBytes - retained,
              bytes <= policy.principalBytes - principals[principal, default: 0] else { throw CoreFailure.eventOverflow }
        let t = Ticket(id: UUID(), principal: principal, bytes: bytes)
        tickets[t.id] = t; retained += bytes; principals[principal, default: 0] += bytes; return t
    }
    func resize(_ t: Ticket, to size: Int) throws -> Ticket {
        guard tickets[t.id] != nil, size > 0, size <= t.bytes else { throw CoreFailure.limit }
        let next = Ticket(id: t.id, principal: t.principal, bytes: size)
        tickets[t.id] = next; retained -= t.bytes - size; principals[t.principal]! -= t.bytes - size
        return next
    }
    func release(_ t: Ticket) throws {
        guard tickets.removeValue(forKey: t.id) != nil else { throw CoreFailure.limit }
        retained -= t.bytes; principals[t.principal]! -= t.bytes
        if principals[t.principal] == 0 { principals.removeValue(forKey: t.principal) }
    }
}
actor EventChannel {
    struct Frame: Sendable { let data: Data, ticket: EventLedger.Ticket, replaceable: ScalarText? }
    enum Next: Sendable { case frame(Frame), terminal(Data?), waiting }
    let policy: EventPolicy, ledger: EventLedger, principal: PrincipalKey, budget: RequestBudget, wire: PreparedWire
    private var queue: [Frame] = []
    private var slots = 0, bytes = 0, emitted = 0
    private var finishing = false, terminal: Data?, ended = false
    private(set) var failed = false
    var isOpen: Bool { !finishing && !ended && !failed }
    init(policy: EventPolicy, ledger: EventLedger, principal: VerifiedPrincipal, budget: RequestBudget, wire: PreparedWire) {
        self.policy = policy; self.ledger = ledger; self.principal = PrincipalKey(principal); self.budget = budget; self.wire = wire
    }
    func emit(_ value: JSON, as definition: FrozenWireDefinition, replaceable: ScalarText? = nil) async throws {
        try await emitPrepared(value, definition: definition, replaceable: replaceable)
    }
    // Called only after a negotiated registration-owned params/metadata plan has
    // validated the server-constructed envelope. It uses the same bounded owner.
    func emitSupplemental(_ value: JSON, replaceable: ScalarText? = nil) async throws { try await emitPrepared(value, definition: nil, replaceable: replaceable) }
    private func emitPrepared(_ value: JSON, definition: FrozenWireDefinition?, replaceable: ScalarText?) async throws {
        guard !finishing, !ended, !failed else { throw CoreFailure.eventsUnavailable }
        if let key = replaceable, let index = queue.firstIndex(where: { $0.replaceable == key }) {
            let old = queue.remove(at: index); try await release(old)
        }
        guard emitted < policy.maximumEvents, slots < policy.queuedEvents, bytes < policy.queuedBytes else {
            await abort(failure: true); throw CoreFailure.eventOverflow
        }
        let capacity = min(policy.notificationBytes, policy.queuedBytes - bytes)
        slots += 1; bytes += capacity; emitted += 1
        var ticket: EventLedger.Ticket
        do { ticket = try await ledger.reserve(capacity, principal: principal) }
        catch { slots -= 1; bytes -= capacity; await abort(failure: true); throw error }
        do {
            if let definition { guard try await wire.validate(value, as: definition, budget: budget) else { throw CoreFailure.invalidOutput } }
            var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(capacity)
            let data = try await budget.performJSON(limits: limits) { try WireCodec.write(value, limits: $0) }
            // Queue copies and eventual write are prepaid while the parent is
            // live. Draining never replenishes or spends from a closed account.
            try await budget.consume(UInt64(data.count) * 4 + 128)
            guard !finishing, !ended, !failed else { throw CoreFailure.eventsUnavailable }
            ticket = try await ledger.resize(ticket, to: data.count)
            bytes -= capacity - data.count
            queue.append(.init(data: data, ticket: ticket, replaceable: replaceable))
        } catch {
            slots -= 1; bytes -= ticket.bytes; try await ledger.release(ticket)
            if !finishing { await abort(failure: true) }; throw error
        }
    }
    func take() -> Next {
        if !queue.isEmpty { return .frame(queue.removeFirst()) }
        if finishing || ended || failed { ended = true; let value = terminal; terminal = nil; return .terminal(value) }
        return .waiting
    }
    func release(_ frame: Frame) async throws {
        slots -= 1; bytes -= frame.ticket.bytes; try await ledger.release(frame.ticket)
    }
    func sealIfOpen() { if !finishing && !ended && !failed { finishing = true } }
    func finish(_ data: Data?) throws {
        guard !finishing, !ended, !failed else { throw CoreFailure.eventsUnavailable }
        finishing = true; terminal = data
    }
    func abort(failure: Bool = false) async {
        failed = failed || failure; ended = true; finishing = true; terminal = nil
        let discarded = queue; queue.removeAll()
        for frame in discarded { do { try await release(frame) } catch { failed = true } }
    }
    func write(to sink: @escaping ResponseSink, allowance: UInt64) async throws {
        var remaining = allowance
        do {
            while true {
                try Task.checkCancellation()
                switch take() {
                case .frame(let frame):
                    do { try await sink(frame.data) } catch { try await release(frame); throw CoreFailure.disconnected }
                    try await release(frame)
                case .terminal(let bytes): if let bytes { try await sink(bytes) }; return
                case .waiting:
                    guard remaining > 0 else { throw CoreFailure.limit }; remaining -= 1
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        } catch { await abort(failure: true); throw error }
    }
}
