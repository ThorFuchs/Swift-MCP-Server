// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import JSON
import MCPProtocol

private final class RequestSlot: Sendable {
    let key = Mutex<RequestKey?>(nil)
}
public enum RequestMirrorFailure: Error, Sendable { case mismatch }

/// Transport checks over the same admitted envelope/account, before provider authority.
/// Transport-only envelope checks retain D01 recovery and the same request account.
public typealias RequestScopeValidator = @Sendable (Set<ScalarText>, RequestBudget) async throws -> Void

public typealias RequestEnvelopeValidator = @Sendable (JSON, RequestBudget) async throws -> Void

public typealias RequestIngressValidator = @Sendable (IncomingEnvelope.Request, RequestBudget) async throws -> Void

/// A sanitized host admission rejection must cross the core without becoming a protocol response.
public protocol RequestAccessFailure: Error, Sendable {}

/// Exact error metadata for an owned transport; no second JSON parse/account.
/// The nonthrowing callback must cooperate with cancellation like the sink.
public typealias ResponseErrorObserver = @Sendable (ModernProtocolError) async -> Void

public typealias ResponseSink = @Sendable (Data) async throws -> Void

enum RuntimePolicy {
    static func scopes(_ scopes: Set<ScalarText>) throws {
        guard scopes.count <= 256, scopes.allSatisfy({ !$0.description.isEmpty && $0.description.utf8.count <= 4096 }) else { throw CoreFailure.limit }
    }
    static func principal(_ principal: VerifiedPrincipal, origin: ScalarText) throws {
        guard [principal.issuer, principal.subject, principal.resource, origin].allSatisfy({
            !$0.description.isEmpty && $0.description.utf8.count <= 4096
        }) else { throw CoreFailure.limit }
        try scopes(principal.scopes)
    }
}

/// In-process owner. The host verifies identity and transport admission before
/// calling it. Every callback must cooperate with cancellation. A cancelled or
/// disconnected sink has at most one attempt; delivery cannot be guaranteed.
struct Dispatcher: Sendable {
    let configuration: ServerConfiguration
    let admission: AdmissionController
    let control: AdmissionController
    let inspection: AdmissionController
    let ownership: RequestOwnership
    let buffers: BufferedWork
    let catalogs: CatalogStore
    let wire: PreparedWire
    let info: JSON
    let instance: ScalarText
    let cursors: CursorStore
    let continuations: RequestStateProtector?
    let eventPolicy: EventPolicy, eventLedger: EventLedger, subscriptions: SubscriptionHub
    let publisher: AdmissionController
    let middleware: [RequestMiddleware]

    func cancel(id: RequestID, principal: VerifiedPrincipal, origin: ScalarText) async throws {
        try RuntimePolicy.principal(principal, origin: origin)
        // This small separate admission path remains available when providers
        // saturate their queue. It never starts a provider or emits a response.
        let permit = try await control.acquire()
        do {
            let budget = try RequestBudget(workUnits: 65_536)
            let key = try await RequestKey.make(id, principal: principal, origin: origin, budget: budget)
            await ownership.cancel(key)
        } catch { try await control.release(permit); throw error }
        try await control.release(permit)
    }

    func dispatch(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText,
                  mirror: RequestMirrorValidator?, send: @escaping ResponseSink, mode: DeliveryMode? = nil,observeError:ResponseErrorObserver? = nil) async throws {
        try RuntimePolicy.principal(principal, origin: origin)
        guard bytes.count <= configuration.messageBytes else { throw CoreFailure.limit }
        let weight = bytes.count * 4 + configuration.resultBytes
        let buffer = try await buffers.reserve(weight)
        do {
            let budget = try RequestBudget(workUnits: configuration.requestWork)
            let identityBytes = [principal.issuer, principal.subject, principal.resource, origin].reduce(0) { $0 + $1.description.utf8.count + 1 }
            try await budget.consume(UInt64(bytes.count) * 4 + UInt64(identityBytes) * 4 + UInt64(principal.scopes.reduce(0) { $0 + $1.description.utf8.count + 1 }))
            let terminal = TerminalCoordinator()
            let response = try await TerminalResponse.reserve(from: budget, work: configuration.terminalWork, maximumBytes: configuration.resultBytes)
            try await AdmittedOperation.runDelivering(admission: admission, budget: budget) {
                let lease = CatalogLeaseOwner(store: catalogs, lease: await catalogs.acquire())
                do {
                    try await owned(bytes, principal: principal, origin: origin, lease: lease,
                        budget: budget, terminal: terminal, response: response, mirror: mirror, send: send, mode: mode,observeError:observeError)
                } catch { try await lease.releaseIfOwned(); throw error }
                try await lease.releaseIfOwned()
            }
        } catch { try await buffers.release(buffer); throw error }
        try await buffers.release(buffer)
    }

    func notification(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, acceptNotifications: Bool,responseCopyMultiplier:UInt64,responseFixedWork:UInt64) async throws -> IngressDisposition {
        guard (1...8).contains(responseCopyMultiplier),responseFixedWork <= 1_000_000 else { throw CoreFailure.invalidPolicy }
        try RuntimePolicy.principal(principal, origin: origin)
        guard bytes.count <= configuration.messageBytes else { throw CoreFailure.limit }
        // Envelope inspection has request capacity independent of both provider
        // execution and the tiny direct-cancellation control lane. A concurrent
        // HTTP POST must not consume cancellation-only capacity before dispatch.
        let permit = try await inspection.acquire()
        let result: IngressDisposition
        do { result = try await bufferedNotification(bytes, principal: principal, origin: origin, acceptNotifications:acceptNotifications,responseCopyMultiplier:responseCopyMultiplier,responseFixedWork:responseFixedWork) }
        catch { try await inspection.release(permit); throw error }
        try await inspection.release(permit)
        return result
    }
    private func bufferedNotification(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, acceptNotifications: Bool,responseCopyMultiplier:UInt64,responseFixedWork:UInt64) async throws -> IngressDisposition {
        let buffer = try await buffers.reserve(bytes.count * 4)
        let result: IngressDisposition
        do { result = try await inspectNotification(bytes, principal: principal, origin: origin, acceptNotifications:acceptNotifications,responseCopyMultiplier:responseCopyMultiplier,responseFixedWork:responseFixedWork) }
        catch { try await buffers.release(buffer); throw error }
        try await buffers.release(buffer)
        return result
    }
    private func inspectNotification(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, acceptNotifications: Bool,responseCopyMultiplier:UInt64,responseFixedWork:UInt64) async throws -> IngressDisposition {
        let budget = try RequestBudget(workUnits:configuration.requestWork)
        do {
            let result = try await prepareIngress(bytes,principal:principal,origin:origin,budget:budget,acceptNotifications:acceptNotifications,responseCopyMultiplier:responseCopyMultiplier,responseFixedWork:responseFixedWork)
            if case .notification = result { await budget.terminate() }
            return result
        } catch { await budget.terminate(); throw error }
    }
    private func prepareIngress(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, budget: RequestBudget, acceptNotifications: Bool,responseCopyMultiplier:UInt64,responseFixedWork:UInt64) async throws -> IngressDisposition {
        let identityBytes = [principal.issuer,principal.subject,principal.resource,origin].reduce(0) { $0 + $1.description.utf8.count + 1 }
        try await budget.consume(UInt64(bytes.count) * 4 + UInt64(identityBytes) * 4 +
            UInt64(principal.scopes.reduce(0) { $0 + $1.description.utf8.count + 1 }) + 64)
        let response = try await TerminalResponse.reserve(from:budget,work:configuration.terminalWork,maximumBytes:configuration.resultBytes,copyMultiplier:responseCopyMultiplier,fixedWork:responseFixedWork)
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(configuration.deadlineMilliseconds))
        var limits = JSONLimits.balanced; limits[.inputBytes] = UInt64(configuration.messageBytes)
        let parsed: (JSON,UInt64)
        do {
            parsed = try await budget.performJSON(limits:limits) {
                let report = try WireCodec.parse(Array(bytes),limits:$0)
                return JSONOperationReport(result:(report.result,report.statistics.peakLogicalRetainedBytes),statistics:report.statistics)
            }
        }
        catch let error as JSONFailure where error.category == .syntax {
            return .request(.init(owner:instance,bytes:bytes,raw:nil,principal:principal,origin:origin,budget:budget,response:response,retainedBytes:bytes.count+256,correlation:nil,deadline:deadline))
        }
        let raw = parsed.0
        let sum = parsed.1.addingReportingOverflow(UInt64(bytes.count+identityBytes+256))
        guard !sum.overflow, sum.partialValue <= UInt64(Int.max - configuration.resultBytes) else { throw CoreFailure.limit }
        let retained = Int(sum.partialValue)
        guard EnvelopeProjection.isNotification(raw) else {
            var correlation: RequestCorrelation?
            if let object = raw.objectValue, object["jsonrpc"]?.stringValue == "2.0", object["method"]?.stringValue != nil,
                object["result"] == nil, object["error"] == nil, let value = object["id"] {
                let id: RequestID?
                do { id = try RequestID(value) } catch let error as WireFailure where error == .invalidRequest { id = nil }
                if let id { correlation = .init(key:try await RequestKey.make(id,principal:principal,origin:origin,budget:budget),owner:instance) }
            }
            return .request(.init(owner:instance,bytes:bytes,raw:raw,principal:principal,origin:origin,budget:budget,response:response,retainedBytes:retained,correlation:correlation,deadline:deadline))
        }
        guard acceptNotifications else { return .notification(cancelled:nil) }
        let ticket = try await budget.reserve(65_536)
        let report: EnvelopeProjection.Report
        do { report = try EnvelopeProjection.decode(raw) }
        catch let error as WireFailure {
            try await budget.settle(ticket, consumed: nil)
            if error == .limit { throw error }
            return .notification(cancelled:nil)
        }
        catch { try await budget.settle(ticket, consumed: nil); throw error }
        try await budget.settle(ticket, consumed: report.workUnits)
        if case .cancellation(let params) = report.result,
            try await wire.validate(raw, as: .CancelledNotification, budget: budget), let target = params["requestId"] {
            let key = try await RequestKey.make(RequestID(target), principal: principal, origin: origin, budget: budget)
            await ownership.cancel(key)
            return .notification(cancelled:.init(key:key,owner:instance))
        }
        return .notification(cancelled:nil)
    }

    func dispatch(_ ingress: AdmittedIngress, send: @escaping ResponseSink, mode: DeliveryMode?,
                  validate: RequestIngressValidator?, validateEnvelope: RequestEnvelopeValidator?, validateScopes: RequestScopeValidator?, mirror: RequestMirrorValidator?,observeError:ResponseErrorObserver?) async throws {
        try ingress.claim(owner:instance)
        guard ContinuousClock.now < ingress.deadline else { await ingress.budget.terminate(); throw CoreFailure.deadline }
        let buffer: BufferedWork.Ticket
        do { buffer = try await buffers.reserve(ingress.retainedBytes + configuration.resultBytes) }
        catch { await ingress.budget.terminate(); throw error }
        do {
            try await AdmittedOperation.runDelivering(admission:admission,budget:ingress.budget) {
                if ingress.raw == nil {
                    // Failed parsing consumes its remaining main account. D01 uses
                    // only the separately prepaid terminal and one bounded deadline.
                    try await withThrowingTaskGroup(of:Void.self) { group in
                        group.addTask {
                            let terminal = TerminalCoordinator()
                            let bytes = try await ingress.response.encode(id:nil,result:nil,error:.standard(.parse))
                            if let observeError { await observeError(.standard(.parse)) }
                            try Task.checkCancellation()
                            guard await terminal.claim(.failure) else { throw CoreFailure.duplicate }
                            try await send(bytes)
                        }
                        group.addTask { try await ContinuousClock().sleep(until:ingress.deadline); throw CoreFailure.deadline }
                        defer { group.cancelAll() }; _ = try await group.next()
                    }
                } else {
                    let lease = CatalogLeaseOwner(store:catalogs,lease:await catalogs.acquire())
                    do {
                        try await owned(ingress.bytes,principal:ingress.principal,origin:ingress.origin,lease:lease,
                            budget:ingress.budget,terminal:TerminalCoordinator(),response:ingress.response,mirror:mirror,send:send,
                            mode:mode,preparsed:ingress.raw,admittedDeadline:ingress.deadline,validate:validate,validateEnvelope:validateEnvelope,validateScopes:validateScopes,observeError:observeError)
                    } catch { try await lease.releaseIfOwned(); throw error }
                    try await lease.releaseIfOwned()
                }
            }
        } catch { try await buffers.release(buffer); throw error }
        try await buffers.release(buffer)
    }

    private enum OwnedCompletion: Sendable { case producer, writer }

    private func owned(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, lease: CatalogLeaseOwner,
        budget: RequestBudget, terminal: TerminalCoordinator, response: TerminalResponse,
        mirror: RequestMirrorValidator?, send: @escaping ResponseSink, mode: DeliveryMode?,
        preparsed: JSON? = nil, admittedDeadline: ContinuousClock.Instant? = nil, validate: RequestIngressValidator? = nil, validateEnvelope: RequestEnvelopeValidator? = nil, validateScopes: RequestScopeValidator? = nil,observeError:ResponseErrorObserver? = nil) async throws {
        let slot = RequestSlot()
        let cancellation = RequestCancellation()
        let deadline = admittedDeadline ?? ContinuousClock.now.advanced(by: .milliseconds(configuration.deadlineMilliseconds))
        let cursor = await cursors.current
        let channel: EventChannel? = mode.map { _ in EventChannel(policy: eventPolicy, ledger: eventLedger, principal: principal, budget: budget, wire: wire) }
        let writerWork = channel == nil ? 0 : min(UInt64(configuration.deadlineMilliseconds / 5 + 2), await budget.remaining)
        if writerWork > 0 { try await budget.consume(writerWork) }
        // The finite observer allowance is consumed in full from this request.
        // Its local counter does not replenish the main or terminal account and
        // can still observe cancellation while a failed main account closes.
        let observerWork = min(UInt64(configuration.deadlineMilliseconds / 10 + 2), await budget.remaining)
        try await budget.consume(observerWork)
        do {
            try await withThrowingTaskGroup(of: OwnedCompletion.self) { group in
                group.addTask {
                    try await pipeline(bytes, principal: principal, origin: origin, lease: lease, cursor: cursor,
                        budget: budget, terminal: terminal, response: response, slot: slot, cancellation: cancellation,
                        deadline: deadline, mirror: mirror, channel: channel, mode: mode, preparsed:preparsed, validate:validate, validateEnvelope:validateEnvelope, validateScopes:validateScopes,observeError:observeError, send: { bytes in
                            if let channel { try await channel.finish(bytes) } else { try await send(bytes) }
                        })
                    if let channel { await channel.sealIfOpen() }
                    return .producer
                }
                if let channel { group.addTask { try await channel.write(to: send, allowance: writerWork); return .writer } }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    cancellation.cancel(.deadline)
                    _ = await terminal.claim(.cancelled); await budget.terminate()
                    throw CoreFailure.deadline
                }
                group.addTask {
                    var remaining = observerWork
                    while true {
                        try await Task.sleep(for: .milliseconds(10))
                        if cancellation.cancelled {
                            _ = await terminal.claim(.cancelled); await budget.terminate()
                            if cancellation.reason == .deadline { throw CoreFailure.deadline }
                            throw CancellationError()
                        }
                        guard remaining > 0 else { throw CoreFailure.limit }
                        remaining -= 1
                    }
                }
                defer { group.cancelAll() }
                var produced = false, written = channel == nil
                while !produced || !written {
                    guard let completed = try await group.next() else { throw CoreFailure.disconnected }
                    switch completed { case .producer: produced = true; case .writer: written = true }
                    if let channel, await channel.failed { throw CoreFailure.eventOverflow }
                }
                group.cancelAll()
                // Scope exit joins even an uncooperative callback. A host may
                // delay return, but the library never abandons that child.
            }
            if let key = slot.key.withLock({ $0 }) { await ownership.remove(key) }
        } catch {
            if let channel { await channel.abort() }
            let reason = cancellation.reason
            cancellation.cancel(); await budget.terminate()
            _ = await terminal.claim(error is CancellationError || error as? CoreFailure == .deadline ? .cancelled : .failure)
            if let key = slot.key.withLock({ $0 }) { await ownership.remove(key) }
            if reason == .deadline { throw CoreFailure.deadline }
            if reason == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func pipeline(_ bytes: Data, principal: VerifiedPrincipal, origin: ScalarText, lease: CatalogLeaseOwner,
        cursor: CursorProtector, budget: RequestBudget, terminal: TerminalCoordinator, response: TerminalResponse,
        slot: RequestSlot, cancellation: RequestCancellation, deadline: ContinuousClock.Instant,
        mirror: RequestMirrorValidator?, channel: EventChannel?, mode: DeliveryMode?, preparsed: JSON? = nil, validate: RequestIngressValidator? = nil, validateEnvelope: RequestEnvelopeValidator? = nil, validateScopes: RequestScopeValidator? = nil,observeError:ResponseErrorObserver? = nil, send: @escaping ResponseSink) async throws {
        var id: RequestID?, raw: JSON?, phase = 0, notification = false
        let encoded: Data
        let outcome: TerminalCoordinator.Outcome
        do {
            var limits = JSONLimits.balanced; limits[.inputBytes] = UInt64(configuration.messageBytes)
            let value: JSON
            if let preparsed { value = preparsed }
            else { value = try await budget.performJSON(limits: limits) { try WireCodec.parse(Array(bytes), limits: $0) } }
            raw = value; phase = 1
            // Input copy/inspection was prepaid before parsing. Establish the
            // no-response boundary as soon as the bounded parsed value exists;
            // even exhausted recovery/projection work cannot invent a reply.
            notification = EnvelopeProjection.isNotification(value)
            // Bounded recovery solely for D01. It grants no request authority.
            try await budget.consume(UInt64(bytes.count) + 1)
            if let value = value.objectValue?["id"] {
                do { id = try RequestID(value) } catch { id = nil }
            }
            if !notification, let validateEnvelope { try await validateEnvelope(value,budget) }
            let ticket = try await budget.reserve(65_536)
            let envelope: IncomingEnvelope
            do {
                let projection = try EnvelopeProjection.decode(value)
                try await budget.settle(ticket, consumed: projection.workUnits); envelope = projection.result
            } catch { try await budget.settle(ticket, consumed: nil); throw error }
            switch envelope {
            case .cancellation(let params):
                guard try await wire.validate(value, as: .CancelledNotification, budget: budget), let target = params["requestId"] else { throw WireFailure.invalidParams }
                let key = try await RequestKey.make(RequestID(target), principal: principal, origin: origin, budget: budget)
                await ownership.cancel(key)
                _ = await terminal.claim(.complete)
                return
            case .request(let request):
                if let validate { try await validate(request, budget) }
                let snapshot = try await lease.snapshot
                let core = WireMethod(rawValue: request.method.description)
                let supplemental = snapshot.extensions.requests[request.method]
                guard core != nil || supplemental != nil else {
                    if snapshot.extensions.inputs[request.method] != nil || snapshot.extensions.notifications[request.method] != nil { throw WireFailure.forbiddenDirection }
                    throw CoreFailure.unknownMethod
                }
                if let core {
                    if core == .listen, channel == nil { throw CoreFailure.unknownMethod }
                    guard wire.plans[core.definition] != nil else { throw CoreFailure.unknownMethod }
                    guard try await wire.validate(request.raw, as: core.definition, budget: budget) else { throw WireFailure.invalidParams }
                } else {
                    guard try await wire.validate(.object(request.capabilities), as: .ClientCapabilities, budget: budget),
                          let meta = request.params["_meta"], try await wire.validate(meta, as: .RequestMetaObject, budget: budget) else { throw WireFailure.invalidParams }
                }
                let method = core.map(RequestMethod.init) ?? RequestMethod(namespace: supplemental!.namespace, method: request.method)
                let key = try await RequestKey.make(request.id, principal: principal, origin: origin, budget: budget)
                try await ownership.insert(key, cancellation: cancellation); slot.key.withLock { $0 = key }
                let extensions = try await snapshot.extensions.negotiate(request.capabilities, budget: budget)
                if let supplemental, extensions[supplemental.namespace.description] == nil {
                    // Reserved official-extension methods (e.g. tasks/get) report the missing
                    // capability (-32021); other supplemental routes stay method-not-found.
                    if supplemental.reserved { throw try await ProtocolRejection.missingExtension(supplemental.namespace, wire: wire, budget: budget) }
                    throw CoreFailure.unknownMethod
                }
                let metadata = request.params["_meta"]!.objectValue!
                let token: RequestID? = try metadata["progressToken"].map { try RequestID($0) }
                let level = metadata["io.modelcontextprotocol/logLevel"]?.stringValue.flatMap(ProtocolLogLevel.init(rawValue:))
                let events = channel.map { RequestEvents(channel: $0, token: token, level: level, subscription: method == .listen, cancellation: cancellation) }
                let trace = try await RequestTraceContext.extract(metadata, budget: budget)
                let context = RequestContext(principal: principal, origin: origin, id: request.id, method: method,
                    capabilities: request.capabilities, extensions: extensions, generation: try await lease.snapshot.generation,
                    deadline: deadline, budget: budget, traceContext: trace, cancellation: cancellation, events: events, scopeValidator:validateScopes, extensionRegistry: snapshot.extensions)
                phase = 2
                let result: JSON
                if method == .listen {
                    guard let channel, let mode else { throw CoreFailure.unknownMethod }
                    let filters = try await SubscriptionHub.prepare(request.params["notifications"]!, snapshot: lease.snapshot, context: context, policy: eventPolicy, wire: wire)
                    try await lease.releaseIfOwned()
                    result = try await subscriptions.run(filters: filters, context: context, channel: channel, mode: mode, info: info)
                    guard try await wire.validate(result, as: .SubscriptionsListenResult, budget: budget) else { throw CoreFailure.invalidOutput }
                } else if let supplemental {
                    result = try await SupplementalDispatch.execute(request, context: context, plan: supplemental, wire: wire,
                        info: info, maximumBytes: configuration.resultBytes, mirror: mirror, continuations: continuations,
                        requestWork: configuration.requestWork, middleware: middleware)
                } else {
                    result = try await ProviderDispatch.execute(request, context: context, snapshot: lease.snapshot, wire: wire,
                    info: info, cursor: cursor, instance: instance, pageSize: configuration.pageEntries,
                    maximumBytes: configuration.resultBytes, mirror: mirror, continuations: continuations, requestWork: configuration.requestWork, loggingEnabled: eventPolicy.logRedactor != nil, middleware: middleware)
                }
                try context.checkCancellation()
                let final = await budget.snapshot
                guard !final.isTerminal, final.activeReservations == 0 else { throw RequestBudget.Failure.exhausted }
                encoded = try await response.encode(id: request.id, result: result, error: nil)
                outcome = .complete
            }
        } catch {
            if notification {
                _ = await terminal.claim(.failure)
                return
            }
            if error is any RequestAccessFailure { throw error }
            if error is CancellationError || error as? CoreFailure == .deadline || error as? CoreFailure == .insufficientScopes { throw error }
            let protocolError: ModernProtocolError
            if error is RequestMirrorFailure { protocolError = .standard(.headerMismatch) }
            else if let rejection = error as? ProtocolRejection { protocolError = rejection.error }
            else if let failure = error as? WireFailure {
                switch failure {
                case .unsupportedVersion:
                    let requested = raw?.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?[ProtocolMetadata.protocolVersion]?.stringValue ?? ""
                    if requested.utf8.count <= 256 { protocolError = .unsupportedVersion(requested: ScalarText(requested)) }
                    else { protocolError = .standard(.invalidParams) }
                case .invalidParams: protocolError = .standard(.invalidParams)
                case .invalidRequest, .forbiddenDirection: protocolError = .standard(.invalidRequest)
                default: protocolError = .standard(.internalError)
                }
            } else if let failure = error as? CoreFailure {
                switch failure {
                case .unknownProvider:
                    if raw?.objectValue?["method"]?.stringValue == WireMethod.readResource.rawValue,
                       let uri = raw?.objectValue?["params"]?.objectValue?["uri"]?.stringValue, uri.utf8.count <= 4096 {
                        protocolError = .resourceNotFound(uri: ScalarText(uri))
                    } else { protocolError = .standard(.invalidParams) }
                case .invalidInput, .invalidCursor, .invalidState: protocolError = .standard(.invalidParams)
                case .unknownMethod: protocolError = .standard(.methodNotFound)
                case .duplicate: protocolError = .standard(.invalidRequest)
                default: protocolError = .standard(.internalError)
                }
            } else if let failure = error as? JSONFailure, phase == 0, failure.category == .syntax {
                protocolError = .standard(.parse)
            } else { protocolError = .standard(.internalError) }
            encoded = try await response.encode(id: id, result: nil, error: protocolError)
            if let observeError { await observeError(protocolError) }
            outcome = .failure
        }
        try Task.checkCancellation()
        guard !cancellation.cancelled, ContinuousClock.now < deadline, await terminal.claim(outcome) else { throw CancellationError() }
        // Encoding error cannot trigger another attempt; sink errors are outside
        // translation. The separately prepaid account includes byte/write work.
        do { try await send(encoded) }
        catch { throw CoreFailure.disconnected }
    }
}
