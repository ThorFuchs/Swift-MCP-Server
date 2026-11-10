// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public struct ExtensionResult: Sendable {
    public let type: ScalarText, schema: JSON
    /// Core provider methods explicitly permitted to return this supplemental branch.
    public let coreMethods: Set<WireMethod>
    public init(type: ScalarText, schema: JSON, coreMethods: Set<WireMethod> = []) { self.type = type; self.schema = schema; self.coreMethods = coreMethods }
}
public struct ExtensionInput: Sendable {
    public let method: ScalarText, requestSchema: JSON, responseSchema: JSON
    public init(method: ScalarText, requestSchema: JSON, responseSchema: JSON) { self.method = method; self.requestSchema = requestSchema; self.responseSchema = responseSchema }
}
public struct ExtensionNotification: Sendable {
    public let method: ScalarText, parametersSchema: JSON
    public init(method: ScalarText, parametersSchema: JSON) { self.method = method; self.parametersSchema = parametersSchema }
}
public struct ExtensionRequest: Sendable {
    public let method: ScalarText, parametersSchema: JSON, resultTypes: Set<ScalarText>, requiredScopes: Set<ScalarText>
    public let rounds: MultiRoundProvider?
    let handler: ProviderHandler?
    public init(method: ScalarText, parametersSchema: JSON, resultTypes: Set<ScalarText>, requiredScopes: Set<ScalarText> = [], handler: @escaping ProviderHandler) {
        self.method = method; self.parametersSchema = parametersSchema; self.resultTypes = resultTypes; self.requiredScopes = requiredScopes; self.handler = handler; rounds = nil
    }
    /// Explicit multi-round semantics; no custom method inherits the three core methods' privilege.
    public init(method: ScalarText, parametersSchema: JSON, resultTypes: Set<ScalarText>, requiredScopes: Set<ScalarText> = [], rounds: MultiRoundProvider) {
        self.method = method; self.parametersSchema = parametersSchema; self.resultTypes = resultTypes; self.requiredScopes = requiredScopes; self.rounds = rounds; handler = nil
    }
}
public struct ExtensionRegistration: Sendable {
    public let identifier: ScalarText, settingsSchema: JSON
    public let capabilities: JSON?
    public let requests: [ExtensionRequest], results: [ExtensionResult], inputs: [ExtensionInput], notifications: [ExtensionNotification]
    public init(identifier: ScalarText, settingsSchema: JSON, capabilities: JSON? = nil, requests: [ExtensionRequest] = [], results: [ExtensionResult] = [], inputs: [ExtensionInput] = [], notifications: [ExtensionNotification] = []) {
        self.identifier = identifier; self.settingsSchema = settingsSchema; self.capabilities = capabilities
        self.requests = requests; self.results = results; self.inputs = inputs; self.notifications = notifications
    }
}
struct PreparedExtensionInput: Sendable {
    let namespace: ScalarText, request: PreparedSchema, response: PreparedSchema
}
struct PreparedExtensionResult: Sendable {
    let namespace: ScalarText, declaration: ExtensionResult, schema: PreparedSchema
}
struct PreparedExtensionNotification: Sendable {
    let namespace: ScalarText, declaration: ExtensionNotification, schema: PreparedSchema
}
struct PreparedExtensionRequest: Sendable {
    let namespace: ScalarText, registration: ExtensionRequest, parameters: PreparedSchema, headers: [HeaderDeclaration], rounds: PreparedRoundPlan?
}
struct ExtensionRegistry: Sendable {
    struct Entry: Sendable { let identifier: ScalarText, schema: PreparedSchema, capabilities: JSON }
    let entries: [Entry], weight: UInt64
    let requests: [ScalarText: PreparedExtensionRequest], results: [ScalarText: PreparedExtensionResult]
    let inputs: [ScalarText: PreparedExtensionInput], notifications: [ScalarText: PreparedExtensionNotification]
    static func prepare(_ input: [ExtensionRegistration], generation: UInt64, budget: RequestBudget, wire: PreparedWire) async throws -> Self {
        guard input.count <= 64 else { throw CoreFailure.limit }
        var names = Set<ScalarText>(), methods = Set<ScalarText>(), entries: [Entry] = [], weight: UInt64 = 0, forms = 0
        var requests: [ScalarText: PreparedExtensionRequest] = [:], results: [ScalarText: PreparedExtensionResult] = [:]
        var inputs: [ScalarText: PreparedExtensionInput] = [:], notifications: [ScalarText: PreparedExtensionNotification] = [:]
        func name(_ value: ScalarText, namespace: ScalarText) throws {
            let bytes = value.description.utf8
            guard !bytes.isEmpty, bytes.count <= 256, bytes.allSatisfy({ $0 > 32 && $0 < 127 }),
                  value.description.hasPrefix(namespace.description + "/"), value.description.count > namespace.description.count + 1,
                  WireMethod(rawValue: value.description) == nil else { throw CoreFailure.invalidInput }
        }
        func prepare(_ raw: JSON) async throws -> PreparedSchema {
            var limits = JSONLimits.balanced; limits[.outputBytes] = 262144
            _ = try await budget.performJSON(limits: limits) { try WireCodec.write(raw, limits: $0) }
            let plan = try await SchemaPreparation.prepare(raw, identifier: generation, budget: budget)
            guard plan.logicalRetainedUpperBound <= 33_554_432 - weight else { throw CoreFailure.limit }
            weight += plan.logicalRetainedUpperBound; return plan
        }
        for item in input {
            let bytes = item.identifier.description.utf8
            guard bytes.count <= 256, item.identifier.description.contains("/"), !bytes.isEmpty,
                  bytes.allSatisfy({ $0 > 32 && $0 < 127 }), names.insert(item.identifier).inserted else { throw CoreFailure.invalidInput }
            guard item.requests.count <= 16, item.results.count <= 16, item.inputs.count <= 16, item.notifications.count <= 16 else { throw CoreFailure.limit }
            forms += item.requests.count + item.results.count + item.inputs.count + item.notifications.count
            guard forms <= 256 else { throw CoreFailure.limit }
            let capabilities: JSON
            if let declared = item.capabilities { capabilities = declared } else { capabilities = try await RuntimeJSON.object([], budget: budget) }
            guard capabilities.objectValue != nil else { throw CoreFailure.invalidInput }
            var capabilityLimits = JSONLimits.balanced; capabilityLimits[.outputBytes] = 16384
            let capabilityBytes = try await budget.performJSON(limits: capabilityLimits) { try WireCodec.write(capabilities, limits: $0) }
            // Retained capability metadata is independent of compiled plan weight.
            let metadataWeight = UInt64(capabilityBytes.count) * 16 + UInt64(bytes.count) * 4 + 4096
            guard metadataWeight <= 33_554_432 - weight else { throw CoreFailure.limit }
            weight += metadataWeight
            entries.append(.init(identifier: item.identifier, schema: try await prepare(item.settingsSchema), capabilities: capabilities))
            for result in item.results {
                try name(result.type, namespace: item.identifier)
                guard results[result.type] == nil, result.coreMethods.isSubset(of: [.callTool, .readResource, .getPrompt]) else { throw CoreFailure.invalidInput }
                let constant = try await RuntimeJSON.object([.init("const", value: .string(result.type.description))], budget: budget)
                let props = try await RuntimeJSON.object([.init("resultType", value: constant)], budget: budget)
                let shape = try await RuntimeJSON.object([.init("type", value: .string("object")), .init("properties", value: props), .init("required", value: .array([.string("resultType")]))], budget: budget)
                let combined = try await RuntimeJSON.object([.init("allOf", value: .array([shape, result.schema]))], budget: budget)
                results[result.type] = .init(namespace: item.identifier, declaration: result, schema: try await prepare(combined))
            }
            for input in item.inputs {
                try name(input.method, namespace: item.identifier)
                guard methods.insert(input.method).inserted else { throw CoreFailure.invalidInput }
                inputs[input.method] = .init(namespace: item.identifier, request: try await prepare(input.requestSchema), response: try await prepare(input.responseSchema))
            }
            for notification in item.notifications {
                try name(notification.method, namespace: item.identifier)
                guard methods.insert(notification.method).inserted else { throw CoreFailure.invalidInput }
                notifications[notification.method] = .init(namespace: item.identifier, declaration: notification, schema: try await prepare(notification.parametersSchema))
            }
            for request in item.requests {
                try name(request.method, namespace: item.identifier)
                guard methods.insert(request.method).inserted, !request.resultTypes.isEmpty, request.resultTypes.count <= 16,
                      request.resultTypes.allSatisfy({ results[$0]?.namespace == item.identifier }) else { throw CoreFailure.invalidInput }
                try RuntimePolicy.scopes(request.requiredScopes)
                let parameters = try await prepare(request.parametersSchema), headers = try await SchemaPreparation.headers(for: parameters, budget: budget)
                let definition = try await RuntimeJSON.object([.init("method", value: .string(request.method.description)), .init("parameters", value: request.parametersSchema),
                    .init("namespace", value: .string(item.identifier.description)), .init("settings", value: item.settingsSchema),
                    .init("results", value: .array(request.resultTypes.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }.map { results[$0]!.schema.raw }))], budget: budget)
                let rounds = try await request.rounds.mapAsync { provider in
                    try await PreparedRoundPlan.prepare(provider, definition: definition, scopes: request.requiredScopes, features: [], wire: wire, generation: generation, budget: budget, supplemental: inputs.filter { $0.value.namespace == item.identifier })
                }
                if let rounds { guard rounds.weight <= 33_554_432 - weight else { throw CoreFailure.limit }; weight += rounds.weight }
                requests[request.method] = .init(namespace: item.identifier, registration: request, parameters: parameters, headers: headers, rounds: rounds)
            }
        }
        return .init(entries: entries, weight: weight, requests: requests, results: results, inputs: inputs, notifications: notifications)
    }
    func negotiate(_ capabilities: JSONObject, budget: RequestBudget) async throws -> JSONObject {
        let requested = capabilities["extensions"]?.objectValue
        var members: [JSONMember] = []
        if let requested {
            guard requested.count <= 64 else { throw CoreFailure.limit }
            try await budget.consume(UInt64(requested.reduce(0) { $0 + $1.key.string.utf8.count + 1 }) * 65)
            for entry in entries {
                guard let value = requested[entry.identifier.description] else { continue }
                var limits = JSONLimits.balanced; limits[.outputBytes] = 16384
                _ = try await budget.performJSON(limits: limits) { try WireCodec.write(value, limits: $0) }
                guard try await SchemaPreparation.validate(value, against: entry.schema, budget: budget) else { throw CoreFailure.invalidInput }
                members.append(.init(entry.identifier.description, value: value))
            }
        }
        return try await RuntimeJSON.object(members, budget: budget).objectValue!
    }
    func result(_ raw: JSON, method: RequestMethod, negotiated: JSONObject) -> PreparedExtensionResult? {
        guard let tag = raw.objectValue?["resultType"]?.stringValue, let result = results[ScalarText(tag)], negotiated[result.namespace.description] != nil else { return nil }
        if let core = method.core { return result.declaration.coreMethods.contains(core) ? result : nil }
        return requests[ScalarText(method.rawValue)]?.registration.resultTypes.contains(result.declaration.type) == true ? result : nil
    }
}
private extension Optional where Wrapped: Sendable {
    func mapAsync<T: Sendable>(_ body: (Wrapped) async throws -> T) async rethrows -> T? { guard let self else { return nil }; return try await body(self) }
}
