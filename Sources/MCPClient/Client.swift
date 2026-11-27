// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import JSONSchema
import MCPJSONSchemaAdapter
import MCPProtocol
import Synchronization


/// A client for MCP revision 2026-07-28.
///
/// Every request carries the protocol version and client capabilities in `params._meta`.
/// Responses and notifications are validated against the frozen schema before they reach
/// the caller. When a server answers with `InputRequiredResult`, the configured handlers
/// answer the input requests and the request is resent with `inputResponses` and the
/// opaque `requestState` (MRTR). Requests run concurrently on the calling tasks; cancelling
/// a call cancels its exchange. The client keeps no session and owns no tasks.
public actor Client {
    /// Frozen protocol revision emitted in every request.
    public static let protocolVersion = "2026-07-28"

    /// Host-supplied capability declarations, handlers and parsing limits.
    public nonisolated let configuration: ClientConfiguration
    private let transport: any ClientTransport
    private let validator = WireValidator()
    private var nextID = 1
    // Routing and validation always come from the same observed definition.
    private struct ToolMetadata {
        let headers: ToolHeaders?
        let outputSchema: JSON?
        let rejection: RejectedTool?
    }
    private struct ToolListing {
        let nextCursor: String
        let observedNames: Set<String>
    }
    private var toolMetadata: [String: ToolMetadata] = [:]
    private var toolListing: ToolListing?
    // Opaque local tickets only: never interpret server cursors as generations.
    private var catalogRevision = UUID()
    private var latestListingHead: UUID?
    /// Latest known rejected definitions, one per tool name, ordered by name.
    /// Unvisited names retain their last validated metadata during a partial listing.
    public private(set) var rejectedTools: [RejectedTool] = []

    /// Creates a client over a supplied transport without starting it or discovering the server.
    public init(transport: any ClientTransport, configuration: ClientConfiguration = .init()) {
        self.transport = transport; self.configuration = configuration
    }

    // MARK: Discovery

    /// `server/discover`. Fails with `unsupportedProtocol` when the server does not list 2026-07-28.
    public func discover() async throws -> ServerDescription {
        let result = try await perform("server/discover", definition: .DiscoverResult)
        guard let object = result.objectValue else { throw ClientError.invalidResponse("discover result") }
        let versions = object["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard versions.contains(Self.protocolVersion) else { throw ClientError.unsupportedProtocol(supported: versions) }
        let empty = try JSONObject()
        return ServerDescription(supportedVersions: versions, capabilities: object["capabilities"]?.objectValue ?? empty,
            instructions: object["instructions"]?.stringValue,
            serverInfo: Implementation(object["_meta"]?.objectValue?["io.modelcontextprotocol/serverInfo"]), raw: result)
    }

    // MARK: Tools, resources, prompts

    /// `tools/list`. On transports that mirror tool parameters into headers, tools with
    /// invalid `x-mcp-header` annotations are excluded and recorded in `rejectedTools`.
    /// Successful pages update observed metadata; a completed listing started at nil
    /// retires names not observed in that chain. Failed pages leave metadata intact.
    /// Concurrent superseded pages return their own validated results without changing
    /// call metadata. This is a local policy, not a server snapshot guarantee.
    public func listTools(cursor: String? = nil) async throws -> Page<Tool> {
        try Task.checkCancellation()
        let revision = catalogRevision
        let head = cursor == nil ? UUID() : nil
        if let head { latestListingHead = head }

        let page = try await page("tools/list", key: "tools", cursor: cursor, definition: .ListToolsResult, Tool.init)
        var kept: [Tool] = []
        var observations: [String: ToolMetadata] = [:]
        for tool in page.items {
            var headers: ToolHeaders?
            var rejection: RejectedTool?
            if transport.mirrorsToolParameters {
                do { headers = try ToolHeaders(inputSchema: tool.inputSchema) }
                catch { rejection = RejectedTool(name: tool.name, reason: String(describing: error)) }
            }
            if rejection == nil { kept.append(tool) }
            observations[tool.name] = ToolMetadata(headers: headers, outputSchema: tool.outputSchema, rejection: rejection)
        }
        try Task.checkCancellation()
        // No suspension between admission of a validated page and the commit.
        // A later-started head supersedes earlier heads, even if it fails.
        // A concurrent continuation can only commit against the revision it read.
        let mayCommit = head.map { latestListingHead == $0 } ?? (catalogRevision == revision)
        if mayCommit {
            var observedNames: Set<String>?
            if head != nil {
                observedNames = []
            } else if let listing = toolListing, let cursor,
                      ScalarText(cursor) == ScalarText(listing.nextCursor) {
                observedNames = listing.observedNames
            }
            // An independent cursor page can update its own names, but cannot
            // establish completeness of any chain. Do not retire unseen tools.
            for (name, metadata) in observations {
                toolMetadata[name] = metadata
                observedNames?.insert(name)
            }
            if let observedNames {
                if let next = page.nextCursor {
                    toolListing = ToolListing(nextCursor: next, observedNames: observedNames)
                } else {
                    toolMetadata = toolMetadata.filter { observedNames.contains($0.key) }
                    toolListing = nil
                }
            } else {
                toolListing = nil
            }
            rejectedTools = toolMetadata.values.compactMap(\.rejection).sorted { $0.name < $1.name }
            catalogRevision = UUID()
        }
        return Page(items: kept, nextCursor: page.nextCursor, raw: page.raw)
    }

    /// `tools/call`. Input requests are answered by the configured handlers; a result type
    /// an extension defines (for example a task) is returned with that `resultType`.
    public func callTool(_ name: String, arguments: JSON? = nil, onProgress: (@Sendable (Progress) async -> Void)? = nil,
                         onLog: (@Sendable (LogMessage) async -> Void)? = nil) async throws -> ToolResult {
        var params = [JSONMember("name", value: .string(name))]
        if let arguments { params.append(JSONMember("arguments", value: arguments)) }
        // Pin both halves of the same definition for the entire call, including
        // MRTR and callbacks that may reenter this actor and refresh the catalog.
        let metadata = toolMetadata[name]
        let headers = transport.mirrorsToolParameters ? metadata?.headers?.headers(for: arguments) ?? [] : []
        let result = try await perform("tools/call", params: params, name: name, definition: .CallToolResult,
                                       acceptsExtensionResults: true, parameterHeaders: headers, onProgress: onProgress, onLog: onLog)
        let tool = ToolResult(result)
        // A successful result of a tool with an outputSchema must carry conforming structuredContent.
        if configuration.validatesStructuredContent, tool.resultType == "complete", !tool.isError, let schema = metadata?.outputSchema {
            guard let structured = tool.structuredContent else { throw ClientError.invalidResponse("\(name) result without structuredContent") }
            guard try await validator.conforms(structured, to: schema) else {
                throw ClientError.invalidResponse("structuredContent of \(name) does not match its outputSchema")
            }
        }
        return tool
    }

    /// Returns a validated resource page; nil starts a listing.
    public func listResources(cursor: String? = nil) async throws -> Page<Resource> {
        try await page("resources/list", key: "resources", cursor: cursor, definition: .ListResourcesResult, Resource.init)
    }
    /// Returns a validated resource-template page, preserving original URI templates.
    public func listResourceTemplates(cursor: String? = nil) async throws -> Page<ResourceTemplate> {
        try await page("resources/templates/list", key: "resourceTemplates", cursor: cursor, definition: .ListResourceTemplatesResult, ResourceTemplate.init)
    }
    /// `resources/read`; text entries and decoded binary (`blob`) entries.
    public func readResource(_ uri: String) async throws -> [ResourceContents] {
        let result = try await perform("resources/read", params: [JSONMember("uri", value: .string(uri))], name: uri, definition: .ReadResourceResult)
        return try (result.objectValue?["contents"]?.arrayValue ?? []).map(ResourceContents.init)
    }

    /// Returns a validated prompt page; pass the opaque next cursor to continue.
    public func listPrompts(cursor: String? = nil) async throws -> Page<Prompt> {
        try await page("prompts/list", key: "prompts", cursor: cursor, definition: .ListPromptsResult, Prompt.init)
    }
    /// `prompts/get`.
    public func getPrompt(_ name: String, arguments: [String: String] = [:]) async throws -> PromptResult {
        var params = [JSONMember("name", value: .string(name))]
        if !arguments.isEmpty {
            let members = arguments.sorted { $0.key < $1.key }.map { JSONMember($0.key, value: .string($0.value)) }
            params.append(JSONMember("arguments", value: .object(try JSONObject(members: members))))
        }
        return try PromptResult(try await perform("prompts/get", params: params, name: name, definition: .GetPromptResult))
    }

    /// `completion/complete` for an argument of a prompt or resource template.
    ///
    /// - Parameters:
    ///   - reference: The prompt or resource template being completed.
    ///   - name: The name of the argument to complete.
    ///   - value: The current argument value, including a partial value.
    ///   - previousArguments: Values of arguments already chosen (`context.arguments`).
    /// - Returns: Validated completion candidates and any reported pagination metadata.
    public func complete(_ reference: CompletionReference, argument name: String, value: String,
                         previousArguments: [String: String] = [:]) async throws -> Completion {
        var params = [JSONMember("ref", value: try reference.json),
                      JSONMember("argument", value: .object(try JSONObject(members: [JSONMember("name", value: .string(name)), JSONMember("value", value: .string(value))])))]
        if !previousArguments.isEmpty {
            let arguments = previousArguments.sorted { $0.key < $1.key }.map { JSONMember($0.key, value: .string($0.value)) }
            params.append(JSONMember("context", value: .object(try JSONObject(members: [JSONMember("arguments", value: .object(try JSONObject(members: arguments)))]))))
        }
        return Completion(try await perform("completion/complete", params: params, definition: .CompleteResult))
    }

    /// Any request, for extension methods such as `tasks/get` or `skills/list`. The result is
    /// checked only as a JSON-RPC result object; the caller validates its shape.
    public func request(_ method: String, params: [JSONMember] = [], name: String? = nil) async throws -> JSON {
        try await perform(method, params: params, name: name, definition: nil, acceptsExtensionResults: true)
    }

    // MARK: Subscriptions

    /// `subscriptions/listen`. `onEvent` first receives `.acknowledged` with the filters the
    /// server agreed to, then events, until the server ends the subscription (the call
    /// returns) or the calling task is cancelled.
    public func listen(_ filter: SubscriptionFilter, onEvent: @escaping @Sendable (ListenEvent) async throws -> Void) async throws {
        _ = try await perform("subscriptions/listen", params: [JSONMember("notifications", value: try filter.json)],
                              definition: .SubscriptionsListenResult, onEvent: onEvent)
    }

    // MARK: Request engine

    private func page<Item>(_ method: String, key: String, cursor: String?, definition: FrozenWireDefinition,
                            _ make: (JSON) throws -> Item) async throws -> Page<Item> {
        let params = cursor.map { [JSONMember("cursor", value: .string($0))] } ?? []
        let result = try await perform(method, params: params, definition: definition)
        let items = try (result.objectValue?[key]?.arrayValue ?? []).map(make)
        return Page(items: items, nextCursor: result.objectValue?["nextCursor"]?.stringValue, raw: result)
    }

    private func identifier() -> Int { defer { nextID += 1 }; return nextID }

    /// Sends one request, answers input rounds, and returns the validated final result.
    private func perform(_ method: String, params: [JSONMember] = [], name: String? = nil, definition: FrozenWireDefinition?,
                         acceptsExtensionResults: Bool = false, parameterHeaders: [(name: String, value: String)] = [],
                         onProgress: (@Sendable (Progress) async -> Void)? = nil,
                         onLog: (@Sendable (LogMessage) async -> Void)? = nil,
                         onEvent: (@Sendable (ListenEvent) async throws -> Void)? = nil) async throws -> JSON {
        var continuation: [JSONMember] = []
        var round = 0, versionRetried = false
        while true {
            try Task.checkCancellation()
            let id = identifier()
            let token = onProgress == nil ? nil : "progress-\(id)"
            let body = try request(id: id, method: method, params: params + continuation, progressToken: token, logs: onLog != nil)
            let final = Mutex<JSON?>(nil)
            let subscription: SubscriptionAdmission?
            if onEvent != nil {
                guard let requested = params.first(where: { $0.key.string == "notifications" })?.value.objectValue else {
                    throw ClientError.invalidResponse("missing subscription filter")
                }
                subscription = SubscriptionAdmission(id: id, requested: requested)
            } else { subscription = nil }
            let validator = self.validator, limits = configuration.limits
            try await transport.exchange(OutgoingRequest(id: .integer(JSONNumber(integer: id)), method: method, name: name, body: body, parameterHeaders: parameterHeaders)) { frame in
                let message = try WireCodec.parse(Array(frame), limits: limits).result
                guard let object = message.objectValue else { throw ClientError.invalidResponse("message is not an object") }
                guard object["jsonrpc"]?.stringValue == "2.0" else { throw ClientError.invalidResponse("invalid JSON-RPC version") }
                if object["id"] != nil, object["method"] == nil {
                    guard Self.matches(object["id"], id) else { throw ClientError.invalidResponse("response for another request") }
                    try final.withLock { value in
                        guard value == nil else { throw ClientError.invalidResponse("second response") }
                        value = message
                    }
                    return
                }
                guard let notification = object["method"]?.stringValue, object["id"] == nil else { throw ClientError.invalidResponse("unexpected message") }
                if subscription != nil, final.withLock({ $0 != nil }) {
                    throw ClientError.invalidResponse("notification after subscription response")
                }
                try await Self.dispatch(notification, params: object["params"], raw: message, token: token, validator: validator,
                                        onProgress: onProgress, onLog: onLog, onEvent: onEvent, subscription: subscription)
            }
            guard let response = final.withLock({ $0 })?.objectValue else { throw ClientError.noResponse }
            if let error = response["error"] {
                let failure = Self.serverError(error)
                // UnsupportedProtocolVersionError: retry once when the server says it supports
                // our only version after all; otherwise report what it supports.
                if case .server(ClientError.Code.unsupportedProtocolVersion, _, let data) = failure {
                    let supported = data?.objectValue?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if supported.contains(Self.protocolVersion), !versionRetried { versionRetried = true; continue }
                    throw ClientError.unsupportedProtocol(supported: supported)
                }
                throw failure
            }
            guard var result = response["result"], let original = result.objectValue else { throw ClientError.invalidResponse("response without result") }
            // A result without resultType is complete (servers of earlier revisions omit it).
            if original["resultType"] == nil {
                result = .object(try JSONObject(members: Array(original) + [JSONMember("resultType", value: .string("complete"))]))
            }
            let object = result.objectValue!
            switch object["resultType"]?.stringValue ?? "complete" {
            case "input_required":
                // Only tools/call, resources/read and prompts/get support MRTR among
                // frozen Core client methods. Leave extension-owned methods unchanged.
                switch method {
                case "server/discover", "tools/list", "resources/list", "resources/templates/list",
                     "prompts/list", "completion/complete", "subscriptions/listen":
                    throw ClientError.invalidResponse("unexpected input_required for \(method)")
                default: break
                }
                guard try await validator.validate(result, as: .InputRequiredResult) else { throw ClientError.invalidResponse("InputRequiredResult") }
                round += 1
                guard round <= configuration.maximumInputRounds else { throw ClientError.tooManyInputRounds }
                continuation = []
                if let requests = object["inputRequests"]?.objectValue, !requests.isEmpty {
                    continuation.append(JSONMember("inputResponses", value: try await answer(requests)))
                }
                if let state = object["requestState"] { continuation.append(JSONMember("requestState", value: state)) }
            case "complete":
                if let definition { guard try await validator.validate(result, as: definition) else { throw ClientError.invalidResponse("\(method) result") } }
                try subscription?.complete(object)
                return result
            default:
                guard acceptsExtensionResults, try await validator.validate(result, as: .Result) else {
                    throw ClientError.invalidResponse("unexpected resultType for \(method)")
                }
                return result
            }
        }
    }

    private func request(id: Int, method: String, params: [JSONMember], progressToken: String?, logs: Bool) throws -> Data {
        var meta = [JSONMember("io.modelcontextprotocol/protocolVersion", value: .string(Self.protocolVersion)),
                    JSONMember("io.modelcontextprotocol/clientCapabilities", value: try configuration.capabilities())]
        if let info = configuration.info { meta.append(JSONMember("io.modelcontextprotocol/clientInfo", value: info)) }
        if logs, let level = configuration.logLevel { meta.append(JSONMember("io.modelcontextprotocol/logLevel", value: .string(level.rawValue))) }
        if let progressToken { meta.append(JSONMember("progressToken", value: .string(progressToken))) }
        let parameters = [JSONMember("_meta", value: .object(try JSONObject(members: meta)))] + params
        let message = JSON.object(try JSONObject(members: [
            JSONMember("jsonrpc", value: .string("2.0")), JSONMember("id", value: .number(JSONNumber(integer: id))),
            JSONMember("method", value: .string(method)), JSONMember("params", value: .object(try JSONObject(members: parameters)))]))
        return try WireCodec.write(message, limits: configuration.limits).result
    }

    /// Answers MRTR input requests (`{key: {"method": …, "params": …}}`) with the configured
    /// handlers and returns the validated responses by key, for extensions that carry input
    /// requests outside `tools/call`, such as `tasks/update`.
    public func answerInputRequests(_ requests: JSONObject) async throws -> JSON { try await answer(requests) }

    /// Answers every input request with its handler; results are validated before sending.
    private func answer(_ requests: JSONObject) async throws -> JSON {
        var responses: [JSONMember] = []
        for entry in requests {
            let method = entry.value.objectValue?["method"]?.stringValue ?? ""
            let none = JSON.object(try JSONObject())
            let params = entry.value.objectValue?["params"] ?? none
            let response: JSON, definition: FrozenWireDefinition
            switch method {
            case "elicitation/create":
                guard let elicitation = configuration.elicitation else { throw ClientError.unsupportedInput(method: method) }
                let request = try ElicitationRequest(params)
                switch request.mode {
                case .form: guard elicitation.form else { throw ClientError.unsupportedInput(method: method) }
                case .url: guard elicitation.url else { throw ClientError.unsupportedInput(method: method) }
                }
                response = try await elicitation.handler(request).json; definition = .ElicitResult
                // Accepted form content must match the requested schema before it is sent.
                if response.objectValue?["action"]?.stringValue == "accept", let content = response.objectValue?["content"],
                   let schema = params.objectValue?["requestedSchema"] {
                    guard try await validator.conforms(content, to: schema) else {
                        throw ClientError.invalidResponse("elicitation content does not match requestedSchema")
                    }
                }
            case "sampling/createMessage":
                guard let sampling = configuration.sampling else { throw ClientError.unsupportedInput(method: method) }
                response = try await sampling(try SamplingRequest(params)).json; definition = .CreateMessageResult
            case "roots/list":
                guard let roots = configuration.roots else { throw ClientError.unsupportedInput(method: method) }
                response = try await roots().json; definition = .ListRootsResult
            default:
                guard let handler = configuration.additionalInputHandlers[method] else { throw ClientError.unsupportedInput(method: method) }
                response = try await handler(params); definition = .Result
            }
            guard try await validator.validate(response, as: definition) else { throw ClientError.invalidResponse("handler result for \(method)") }
            responses.append(JSONMember(entry.key.string, value: response))
        }
        return .object(try JSONObject(members: responses))
    }

    private static func dispatch(_ method: String, params: JSON?, raw: JSON, token: String?, validator: WireValidator,
                                 onProgress: (@Sendable (Progress) async -> Void)?, onLog: (@Sendable (LogMessage) async -> Void)?,
                                 onEvent: (@Sendable (ListenEvent) async throws -> Void)?, subscription: SubscriptionAdmission?) async throws {
        let object = params?.objectValue
        func check(_ definition: FrozenWireDefinition) async throws {
            guard try await validator.validate(raw, as: definition) else { throw ClientError.invalidResponse(method) }
        }
        switch method {
        case "notifications/progress":
            try await check(.ProgressNotification)
            guard let onProgress, let token, object?["progressToken"]?.stringValue == token else { return }
            await onProgress(Progress(progress: (try? object?["progress"]?.numberValue?.doubleValue(policy: .rounded)) ?? 0,
                                      total: try? object?["total"]?.numberValue?.doubleValue(policy: .rounded),
                                      message: object?["message"]?.stringValue))
        case "notifications/message":
            try await check(.LoggingMessageNotification)
            await onLog?(LogMessage(level: object?["level"]?.stringValue.flatMap(LoggingLevel.init(rawValue:)) ?? .info, logger: object?["logger"]?.stringValue,
                                    data: object?["data"] ?? .null))
        case "notifications/subscriptions/acknowledged":
            try await check(.SubscriptionsAcknowledgedNotification)
            try subscription?.acknowledge(object)
            try await onEvent?(.acknowledged(object?["notifications"] ?? .null))
        case "notifications/tools/list_changed":
            try await check(.ToolListChangedNotification)
            try subscription?.admit(method, params: object)
            try await onEvent?(.toolsChanged)
        case "notifications/resources/list_changed":
            try await check(.ResourceListChangedNotification)
            try subscription?.admit(method, params: object)
            try await onEvent?(.resourcesChanged)
        case "notifications/prompts/list_changed":
            try await check(.PromptListChangedNotification)
            try subscription?.admit(method, params: object)
            try await onEvent?(.promptsChanged)
        case "notifications/resources/updated":
            try await check(.ResourceUpdatedNotification)
            try subscription?.admit(method, params: object)
            try await onEvent?(.resourceUpdated(uri: object?["uri"]?.stringValue ?? ""))
        case "notifications/cancelled":
            try await check(.CancelledNotification)
        default:
            // Extension notifications (for example notifications/tasks) on a listen stream.
            if let onEvent {
                try subscription?.admit(method, params: object)
                try await onEvent(.notification(method: method, params: params ?? .null))
            }
        }
    }

    private static func matches(_ value: JSON?, _ id: Int) -> Bool {
        guard let number = value?.numberValue else { return false }
        return (try? number.integer(as: Int.self)) == id
    }

    private static func serverError(_ error: JSON) -> ClientError {
        let object = error.objectValue
        let code = (try? object?["code"]?.numberValue?.integer(as: Int.self)) ?? 0
        return .server(code: code, message: object?["message"]?.stringValue ?? "", data: object?["data"])
    }
}

/// Validates frozen definitions with shared immutable plans. Only server-supplied
/// schema plans remain in this validator's client-local cache.
actor WireValidator {
    private let frozenPlans: ClientFrozenWirePlanCache
    static let compileLimits = ClientFrozenWirePlanCache.compileLimits

    init(frozenPlans: ClientFrozenWirePlanCache = .shared) {
        self.frozenPlans = frozenPlans
    }

    /// Compiled server-supplied schemas (`outputSchema`, `requestedSchema`), bounded.
    private var schemas: [JSON: CompiledJSONSchema] = [:]

    /// Validates `value` against a server-supplied JSON Schema with Swift-JSON's validator.
    /// A schema that does not compile offline (for example a remote `$ref`) is an error,
    /// never a skipped check.
    func conforms(_ value: JSON, to schema: JSON) throws -> Bool {
        let plan: CompiledJSONSchema
        if let cached = schemas[schema] { plan = cached }
        else {
            do { plan = try SchemaCompilerAdapter.compile(schema, limits: Self.compileLimits).result }
            catch { throw ClientError.invalidResponse("schema cannot be compiled offline: \(error)") }
            if schemas.count >= 256 { schemas.removeAll() }
            schemas[schema] = plan
        }
        return try SchemaValidatorAdapter.validate(value, against: plan, limits: Self.compileLimits).result.isValid
    }

    func validate(_ value: JSON, as definition: FrozenWireDefinition) async throws -> Bool {
        try Task.checkCancellation()
        let compiled = try await frozenPlans.plan(for: definition)
        try Task.checkCancellation()
        // Do not hold the shared cache actor during instance-specific evaluation.
        let valid = try compiled.validate(value, limits: Self.compileLimits).result
        try Task.checkCancellation()
        return valid
    }
}
