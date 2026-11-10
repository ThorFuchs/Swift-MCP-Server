// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

actor RequestEvents {
    let channel: EventChannel
    let token: RequestID?, level: ProtocolLogLevel?, subscription: Bool
    let contextCancellation: RequestCancellation
    private var previous: JSONNumber?, lastProgress: Int64?, lastLog: Int64?
    private var busy = false
    init(channel: EventChannel, token: RequestID?, level: ProtocolLogLevel?, subscription: Bool, cancellation: RequestCancellation) {
        self.channel = channel; self.token = token; self.level = level; self.subscription = subscription; contextCancellation = cancellation
    }
    func notification(_ plan: PreparedExtensionNotification, parameters: JSON) async throws {
        guard !subscription, !contextCancellation.cancelled, !busy, await channel.isOpen else { throw CoreFailure.eventsUnavailable }
        busy = true; defer { busy = false }
        let budget = channel.budget
        guard parameters.objectValue != nil, try await SchemaPreparation.validate(parameters, against: plan.schema, budget: budget) else { throw CoreFailure.invalidOutput }
        if let metadata = parameters.objectValue?["_meta"] {
            guard try await channel.wire.validate(metadata, as: .NotificationMetaObject, budget: budget) else { throw CoreFailure.invalidOutput }
        }
        let raw = try await RuntimeJSON.object([.init("jsonrpc", value: .string("2.0")),
            .init("method", value: .string(plan.declaration.method.description)), .init("params", value: parameters)], budget: budget)
        try await channel.emitSupplemental(raw)
    }
    func progress(_ value: JSONNumber, total: JSONNumber?, message: String?) async throws -> Bool {
        guard !subscription, let token, !contextCancellation.cancelled, !busy, await channel.isOpen else { throw CoreFailure.eventsUnavailable }
        busy = true; defer { busy = false }
        guard (message?.utf8.count ?? 0) <= 4096 else { throw CoreFailure.limit }
        let budget = channel.budget
        var constraints: [JSONMember] = [.init("type",value:.string("number")),.init("minimum",value:.number(JSONNumber(integer:0)))]
        if let previous { constraints.append(.init("exclusiveMinimum",value:.number(previous))) }
        if let total { constraints.append(.init("maximum",value:.number(total))) }
        // The public number API has no ordering operation. This tiny dynamic
        // predicate uses the real private schema adapter and cumulative reports;
        // it is neither a copied number comparator nor a raw protocol recompile.
        let schema = try await RuntimeJSON.object(constraints,budget:budget)
        let predicate = try await SchemaPreparation.prepare(schema,identifier:0,budget:budget)
        let valid = try await SchemaPreparation.validate(.number(value),against:predicate,budget:budget)
        guard valid else { throw CoreFailure.invalidInput }
        let now = channel.policy.clock()
        guard now >= 0, lastProgress.map({ now >= $0 }) ?? true else { throw CoreFailure.invalidPolicy }
        if let lastProgress, now - lastProgress < channel.policy.progressIntervalMilliseconds { return false }
        var members: [JSONMember] = [.init("progressToken",value:token.value),.init("progress",value:.number(value))]
        if let total { members.append(.init("total",value:.number(total))) }
        if let message { members.append(.init("message",value:.string(message))) }
        let params = try await RuntimeJSON.object(members,budget:budget)
        let raw = try await RuntimeJSON.object([.init("jsonrpc",value:.string("2.0")),.init("method",value:.string("notifications/progress")),.init("params",value:params)],budget:budget)
        try await channel.emit(raw,as:.ProgressNotification)
        self.previous = value; lastProgress = now; return true
    }
    func log(_ severity: ProtocolLogLevel, data: JSON, logger: String?) async throws -> Bool {
        guard !subscription, !contextCancellation.cancelled, await channel.isOpen else { throw CoreFailure.eventsUnavailable }
        guard let redact = channel.policy.logRedactor, let level, severity.rank >= level.rank else { return false }
        guard !busy, (logger?.utf8.count ?? 0) <= 256 else { throw CoreFailure.limit }
        busy = true; defer { busy = false }
        let now = channel.policy.clock()
        guard now >= 0, lastLog.map({ now >= $0 }) ?? true else { throw CoreFailure.invalidPolicy }
        if let lastLog, now - lastLog < channel.policy.logIntervalMilliseconds { return false }
        let budget = channel.budget
        // Bound the host redactor's input before its cooperative callback.
        var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(channel.policy.notificationBytes)
        _ = try await budget.performJSON(limits:limits) { try WireCodec.write(data,limits:$0) }
        let safe = try await redact(data)
        var members: [JSONMember] = [.init("level",value:.string(severity.rawValue)),.init("data",value:safe)]
        if let logger { members.append(.init("logger",value:.string(logger))) }
        let params = try await RuntimeJSON.object(members,budget:budget)
        let raw = try await RuntimeJSON.object([.init("jsonrpc",value:.string("2.0")),.init("method",value:.string("notifications/message")),.init("params",value:params)],budget:budget)
        try await channel.emit(raw,as:.LoggingMessageNotification); lastLog = now; return true
    }
}
