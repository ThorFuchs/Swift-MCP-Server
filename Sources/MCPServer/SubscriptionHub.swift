// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

public enum SubscriptionEvent: Sendable {
    case toolsChanged, resourcesChanged, promptsChanged, resourceUpdated(ScalarText)
    var method: String {
        switch self { case .toolsChanged: "notifications/tools/list_changed"; case .resourcesChanged: "notifications/resources/list_changed";
        case .promptsChanged: "notifications/prompts/list_changed"; case .resourceUpdated: "notifications/resources/updated" }
    }
    var definition: FrozenWireDefinition {
        switch self { case .toolsChanged: .ToolListChangedNotification; case .resourcesChanged: .ResourceListChangedNotification;
        case .promptsChanged: .PromptListChangedNotification; case .resourceUpdated: .ResourceUpdatedNotification }
    }
}
/// Explicit host visibility. Empty required scopes means host-declared public.
public enum SubscriptionAudience: Sendable {
    case principal(VerifiedPrincipal), requiringScopes(Set<ScalarText>)
    func permits(_ p: VerifiedPrincipal) -> Bool {
        switch self { case .principal(let expected): PrincipalKey(expected) == PrincipalKey(p)
        case .requiringScopes(let scopes): p.scopes.isSuperset(of: scopes) }
    }
}
struct SubscriptionFilters: Sendable {
    let raw: JSON
    let tools: Bool, resources: Bool, prompts: Bool
    let uris: Set<ScalarText>
    func accepts(_ event: SubscriptionEvent) -> Bool {
        switch event { case .toolsChanged: tools; case .resourcesChanged: resources; case .promptsChanged: prompts;
        case .resourceUpdated(let uri): uris.contains(uri) }
    }
}
actor SubscriptionHub {
    private struct Entry: Sendable {
        let key: RequestKey, context: RequestContext, channel: EventChannel, filters: SubscriptionFilters
        var ready: Bool = false, close: Bool = false
    }
    let policy: EventPolicy
    private var entries: [UUID: Entry] = [:]
    init(_ policy: EventPolicy) { self.policy = policy }
    static func prepare(_ raw: JSON, snapshot: CatalogSnapshot, context: RequestContext, policy: EventPolicy) async throws -> SubscriptionFilters {
        guard let object = raw.objectValue else { throw CoreFailure.invalidInput }
        let requested = object["resourceSubscriptions"]?.arrayValue ?? []
        guard requested.count <= policy.filters else { throw CoreFailure.limit }
        var uris = Set<ScalarText>()
        for value in requested {
            guard let uri = value.stringValue, uri.utf8.count <= 4096 else { throw CoreFailure.limit }
            try await context.budget.consume(UInt64(uri.utf8.count) * 8 + 1)
            if let resource = snapshot.resourceIndex[ScalarText(uri)], context.principal.scopes.isSuperset(of: resource.requiredScopes) { uris.insert(ScalarText(uri)) }
        }
        var members: [JSONMember] = []
        for name in ["toolsListChanged","resourcesListChanged","promptsListChanged"] {
            if object[name]?.booleanValue == true { members.append(.init(name,value:.boolean(true))) }
        }
        if !uris.isEmpty { members.append(.init("resourceSubscriptions",value:.array(uris.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }.map { .string($0.description) }))) }
        return .init(raw: try await RuntimeJSON.object(members,budget:context.budget),tools:object["toolsListChanged"]?.booleanValue == true,
            resources:object["resourcesListChanged"]?.booleanValue == true,prompts:object["promptsListChanged"]?.booleanValue == true,uris:uris)
    }
    func run(filters: SubscriptionFilters, context: RequestContext, channel: EventChannel, mode _: DeliveryMode, info: JSON) async throws -> JSON {
        let key = try await RequestKey.make(context.id,principal:context.principal,origin:context.origin,budget:context.budget)
        guard entries.count < policy.subscriptions,
              entries.values.filter({ PrincipalKey($0.context.principal) == PrincipalKey(context.principal) }).count < policy.subscriptionsPerPrincipal else { throw CoreFailure.limit }
        // Reserve the subscriber quota before awaits. Publication starts only
        // after the acknowledgment has been queued on this serial owner.
        let id = UUID(); entries[id] = .init(key:key,context:context,channel:channel,filters:filters)
        do {
            let meta = try await RuntimeJSON.object([.init("io.modelcontextprotocol/subscriptionId",value:context.id.value)],budget:context.budget)
            let params = try await RuntimeJSON.object([.init("_meta",value:meta),.init("notifications",value:filters.raw)],budget:context.budget)
            let ack = try await RuntimeJSON.object([.init("jsonrpc",value:.string("2.0")),.init("method",value:.string("notifications/subscriptions/acknowledged")),.init("params",value:params)],budget:context.budget)
            try context.checkCancellation(); try await channel.emit(ack,as:.SubscriptionsAcknowledgedNotification)
            entries[id]!.ready = true
            let end = ContinuousClock.now.advanced(by:.milliseconds(policy.subscriptionLifetimeMilliseconds))
            while entries[id]?.close == false, ContinuousClock.now < end {
                try context.checkCancellation(); try await context.budget.consume(1)
                try await Task.sleep(for:.milliseconds(10))
            }
            try context.checkCancellation()
            entries.removeValue(forKey:id)
            // Frozen cancellation prose applies to server-initiated teardown
            // on either transport. D02's graceful complete result follows it.
            // A cancelled/unwritable owner throws; no successful delivery or
            // terminal retry is invented. EventChannel retains the same budget,
            // quota, serial writer and cancellation ownership.
            let cancelParams = try await RuntimeJSON.object([.init("requestId",value:context.id.value),.init("reason",value:.string("Server closed subscription")),.init("_meta",value:meta)],budget:context.budget)
            let cancel = try await RuntimeJSON.object([.init("jsonrpc",value:.string("2.0")),.init("method",value:.string("notifications/cancelled")),.init("params",value:cancelParams)],budget:context.budget)
            try await channel.emit(cancel,as:.CancelledNotification)
            let metadata = try await RuntimeJSON.overlay(meta,members:[.init(ProtocolMetadata.serverInfo,value:info)],budget:context.budget)
            return try await RuntimeJSON.object([.init("resultType",value:.string("complete")),.init("_meta",value:metadata)],budget:context.budget)
        } catch { entries.removeValue(forKey:id); throw error }
    }
    func publish(_ event: SubscriptionEvent, audience: SubscriptionAudience, budget: RequestBudget) async throws {
        let audienceBytes: Int
        switch audience {
        case .requiringScopes(let scopes):
            try RuntimePolicy.scopes(scopes)
            audienceBytes = scopes.reduce(0) { $0 + $1.description.utf8.count + 1 }
        case .principal(let principal):
            try RuntimePolicy.principal(principal, origin: ScalarText("host-publication"))
            audienceBytes = principal.issuer.description.utf8.count + principal.subject.description.utf8.count + principal.resource.description.utf8.count
        }
        var uriBytes = 0
        if case .resourceUpdated(let uri) = event {
            uriBytes = uri.description.utf8.count
            guard uriBytes <= 4096 else { throw CoreFailure.limit }
        }
        try Task.checkCancellation()
        try await budget.consume(UInt64(audienceBytes + uriBytes + 128) * UInt64(entries.count + 1) * 8)
        // Finite snapshot of at most policy.subscriptions; independent producer
        // admission/work prevents one task per blocked subscriber or event.
        let targets = entries.filter { $0.value.ready && !$0.value.close && $0.value.filters.accepts(event) && audience.permits($0.value.context.principal) }
        for (id,entry) in targets {
            do {
                try entry.context.checkCancellation()
                let budget = entry.context.budget
                try await budget.consume(UInt64(entries.count) * 128 + 1)
                let meta = try await RuntimeJSON.object([.init("io.modelcontextprotocol/subscriptionId",value:entry.context.id.value)],budget:budget)
                var members: [JSONMember] = [.init("_meta",value:meta)]
                if case .resourceUpdated(let uri) = event {
                    guard uri.description.utf8.count <= 4096 else { throw CoreFailure.limit }
                    members.append(.init("uri",value:.string(uri.description)))
                }
                let params = try await RuntimeJSON.object(members,budget:budget)
                let raw = try await RuntimeJSON.object([.init("jsonrpc",value:.string("2.0")),.init("method",value:.string(event.method)),.init("params",value:params)],budget:budget)
                try await entry.channel.emit(raw,as:event.definition,replaceable:ScalarText(event.method + { if case .resourceUpdated(let uri) = event { return "\0" + uri.description }; return "" }()))
            } catch {
                if error as? CoreFailure == .eventsUnavailable || entry.context.cancellation.cancelled { continue }
                if var current = entries[id] { current.close = true; entries[id] = current }
                await entry.channel.abort(failure:true)
            }
        }
    }
    func close(_ key:RequestKey) -> Bool {
        var found = false
        for id in entries.keys where entries[id]!.key == key { entries[id]!.close = true; found = true }
        return found
    }
    func closeAll() { for id in entries.keys { entries[id]!.close = true } }
    func close(_ principal: VerifiedPrincipal, origin: ScalarText) {
        for id in entries.keys where PrincipalKey(entries[id]!.context.principal) == PrincipalKey(principal)
            && entries[id]!.context.origin == origin { entries[id]!.close = true }
    }
    func revoke(_ principal: VerifiedPrincipal) {
        for entry in entries.values where PrincipalKey(entry.context.principal) == PrincipalKey(principal) { entry.context.cancellation.cancel() }
    }
    var count: Int { entries.count }
}

actor CatalogLeaseOwner {
    let store: CatalogStore
    private var lease: CatalogStore.Lease?
    init(store: CatalogStore, lease: CatalogStore.Lease) { self.store = store; self.lease = lease }
    var snapshot: CatalogSnapshot { get throws { guard let lease else { throw CoreFailure.staleGeneration }; return lease.snapshot } }
    func releaseIfOwned() async throws {
        guard let owned = lease else { return }; lease = nil
        try await store.release(owned)
    }
}
