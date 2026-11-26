// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
import Synchronization

/// Local admission for one already-routed listen exchange. Schema validation
/// precedes admission; the mutex is never held across a host callback.
/// Extension-specific filter semantics remain with their extension consumers.
final class SubscriptionAdmission: Sendable {
    private struct CoreFilter: Sendable {
        let tools: Bool, prompts: Bool, resources: Bool
        let uris: Set<ScalarText>

        init(_ object: JSONObject) {
            tools = object["toolsListChanged"]?.booleanValue == true
            prompts = object["promptsListChanged"]?.booleanValue == true
            resources = object["resourcesListChanged"]?.booleanValue == true
            uris = Set((object["resourceSubscriptions"]?.arrayValue ?? []).compactMap {
                $0.stringValue.map { ScalarText($0) }
            })
        }

        func permits(_ other: Self) -> Bool {
            (!other.tools || tools) && (!other.prompts || prompts) &&
            (!other.resources || resources) && uris.isSuperset(of: other.uris)
        }
    }

    private let id: Int
    private let requested: CoreFilter
    private let agreed = Mutex<CoreFilter?>(nil)

    init(id: Int, requested: JSONObject) {
        self.id = id
        self.requested = CoreFilter(requested)
    }

    private func requireCorrelation(_ object: JSONObject?) throws {
        guard let number = object?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"]?.numberValue,
              (try? number.integer(as: Int.self)) == id else {
            throw ClientError.invalidResponse("subscription ID does not match request")
        }
    }

    func acknowledge(_ params: JSONObject?) throws {
        try requireCorrelation(params)
        guard let filter = params?["notifications"]?.objectValue else {
            throw ClientError.invalidResponse("missing acknowledged filter")
        }
        let accepted = CoreFilter(filter)
        try agreed.withLock { current in
            guard current == nil else { throw ClientError.invalidResponse("duplicate subscription acknowledgement") }
            guard requested.permits(accepted) else { throw ClientError.invalidResponse("acknowledged unrequested filter") }
            current = accepted
        }
    }

    /// Called only for events that would reach the listen callback, after
    /// known core notification schemas have been checked.
    func admit(_ method: String, params: JSONObject?) throws {
        try requireCorrelation(params)
        try agreed.withLock { current in
            guard let current else { throw ClientError.invalidResponse("event before subscription acknowledgement") }
            let permitted: Bool
            switch method {
            case "notifications/tools/list_changed": permitted = current.tools
            case "notifications/prompts/list_changed": permitted = current.prompts
            case "notifications/resources/list_changed": permitted = current.resources
            case "notifications/resources/updated":
                permitted = params?["uri"]?.stringValue.map { current.uris.contains(ScalarText($0)) } ?? false
            default:
                // An extension owns its own filter grammar and event payload.
                permitted = true
            }
            guard permitted else { throw ClientError.invalidResponse("event outside acknowledged filter") }
        }
    }

    func complete(_ result: JSONObject) throws {
        try requireCorrelation(result)
        guard agreed.withLock({ $0 != nil }) else {
            throw ClientError.invalidResponse("subscription completed before acknowledgement")
        }
    }
}
