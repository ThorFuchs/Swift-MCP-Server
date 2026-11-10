// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

/// Immutable, server-created admission view. It cannot replace identity, inputs,
/// the selected generation, request budget or terminal response ownership.
public struct MiddlewareRequest: Sendable {
    public let context: RequestContext
    fileprivate let invocation: UUID
    init(context: RequestContext, invocation: UUID) { self.context = context; self.invocation = invocation }
}
/// Admission is a capability returned by the active continuation, not a result
/// payload. Rejection intentionally skips the provider; all output stays checked.
public struct MiddlewareDecision: Sendable {
    fileprivate enum Value: Sendable { case admitted(UUID), rejected(ModernProtocolError) }
    fileprivate let value: Value
    public static func reject(_ error: ModernProtocolError) -> Self { .init(value: .rejected(error)) }
}
/// Admission-only continuation. Calling it never executes a provider in a host
/// task. The structured server owner advances the chain after the callback joins.
/// This makes duplicate, foreign and escaped calls incapable of starting work.
public actor MiddlewareContinuation {
    private let invocation: UUID, context: RequestContext
    private var called = false, closed = false
    private var failure: (any Error)?
    init(invocation: UUID, context: RequestContext) { self.invocation = invocation; self.context = context }
    public func proceed(for request: MiddlewareRequest) async throws -> MiddlewareDecision {
        do {
            guard !closed, !called, request.invocation == invocation else { throw CoreFailure.duplicate }
            called = true
            try context.checkCancellation()
            try await context.budget.consume(128)
            guard !(await context.budget.snapshot.isTerminal) else { throw RequestBudget.Failure.exhausted }
            return .init(value: .admitted(invocation))
        } catch { failure = failure ?? error; throw error }
    }
    func finish(_ decision: MiddlewareDecision) async throws -> ModernProtocolError? {
        closed = true
        if let failure { throw failure }
        try context.checkCancellation()
        guard !(await context.budget.snapshot.isTerminal) else { throw RequestBudget.Failure.exhausted }
        switch decision.value {
        case .admitted(let identity): guard called, identity == invocation else { throw CoreFailure.invalidOutput }; return nil
        case .rejected(let error): guard !called else { throw CoreFailure.invalidOutput }; return error
        }
    }
    func close() { closed = true }
}
/// Fixed outcome classifications for host observations. Private provider errors,
/// continuation tokens, arguments and result payloads are never supplied.
public enum MiddlewareOutcome: Sendable { case returned, rejected, failed, cancelled }
/// Ordered admission callbacks, then the owned provider, then reverse-order
/// completion callbacks. Host callbacks cooperate with cancellation. A completion
/// callback observes provider return, not successful wire delivery/validation.
public struct RequestMiddleware: Sendable {
    let admission: @Sendable (MiddlewareRequest, MiddlewareContinuation) async throws -> MiddlewareDecision
    let completion: @Sendable (MiddlewareRequest, MiddlewareOutcome) async -> Void
    public init(admit: @escaping @Sendable (MiddlewareRequest, MiddlewareContinuation) async throws -> MiddlewareDecision,
        didFinish: @escaping @Sendable (MiddlewareRequest, MiddlewareOutcome) async -> Void = { _, _ in }) {
        admission = admit; completion = didFinish
    }
}
enum MiddlewarePipeline {
    static func run<Value: Sendable>(_ registrations: [RequestMiddleware], context: RequestContext,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        guard !registrations.isEmpty else { return try await operation() }
        // Prepay bounded lookup/observer work while the original account is live.
        try await context.budget.consume(UInt64(registrations.count) * 256)
        var admitted: [(RequestMiddleware, MiddlewareRequest)] = []
        let result: Value
        do {
            for registration in registrations {
                try context.checkCancellation()
                let identity = UUID()
                // Each callback gets its own exact immutable capability view.
                let request = MiddlewareRequest(context: context, invocation: identity)
                let next = MiddlewareContinuation(invocation: identity, context: context)
                let rejection: ModernProtocolError?
                do { rejection = try await next.finish(registration.admission(request, next)) }
                catch { await next.close(); throw error }
                if let rejection {
                    await registration.completion(request, .rejected)
                    throw ProtocolRejection(error: rejection)
                }
                admitted.append((registration, request))
            }
            try context.checkCancellation()
            guard !(await context.budget.snapshot.isTerminal) else { throw RequestBudget.Failure.exhausted }
            result = try await operation()
        } catch {
            let outcome: MiddlewareOutcome = error is CancellationError || context.cancellation.cancelled ? .cancelled : .failed
            for (middleware, request) in admitted.reversed() { await middleware.completion(request, outcome) }
            throw error
        }
        for (middleware, request) in admitted.reversed() { await middleware.completion(request, .returned) }
        try context.checkCancellation()
        guard !(await context.budget.snapshot.isTerminal) else { throw RequestBudget.Failure.exhausted }
        return result
    }
}
