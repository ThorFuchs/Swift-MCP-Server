// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
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
    public static let protocolVersion = "2026-07-28"

    public let configuration: ClientConfiguration
    private let transport: any ClientTransport
    private let validator = WireValidator()
    private var nextID = 1
    /// `x-mcp-header` declarations from the latest `tools/list` pages, by tool name.
    private var toolHeaders: [String: ToolHeaders] = [:]
    /// Tools dropped from `tools/list` because of invalid `x-mcp-header` annotations.
    public private(set) var rejectedTools: [(name: String, reason: String)] = []

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
            serverInfo: object["_meta"]?.objectValue?["io.modelcontextprotocol/serverInfo"], raw: result)
    }

    // MARK: Tools, resources, prompts

    /// `tools/list`. On transports that mirror tool parameters into headers, tools with
    /// invalid `x-mcp-header` annotations are excluded and recorded in `rejectedTools`.
    public func listTools(cursor: String? = nil) async throws -> Page<Tool> {
        let page = try await page("tools/list", key: "tools", cursor: cursor, definition: .ListToolsResult, Tool.init)
        guard transport.mirrorsToolParameters else { return page }
        var kept: [Tool] = []
        for tool in page.items {
            do { toolHeaders[tool.name] = try ToolHeaders(inputSchema: tool.inputSchema); kept.append(tool) }
            catch { toolHeaders[tool.name] = nil; rejectedTools.append((tool.name, String(describing: error))) }
        }
        return Page(items: kept, nextCursor: page.nextCursor, raw: page.raw)
    }

    /// `tools/call`. Input requests are answered by the configured handlers; a result type
    /// an extension defines (for example a task) is returned with that `resultType`.
    public func callTool(_ name: String, arguments: JSON? = nil, onProgress: (@Sendable (Progress) async -> Void)? = nil,
                         onLog: (@Sendable (LogMessage) async -> Void)? = nil) async throws -> ToolResult {
        var params = [JSONMember("name", value: .string(name))]
        if let arguments { params.append(JSONMember("arguments", value: arguments)) }
        let headers = transport.mirrorsToolParameters ? toolHeaders[name]?.headers(for: arguments) ?? [] : []
        let result = try await perform("tools/call", params: params, name: name, definition: .CallToolResult,
                                       acceptsExtensionResults: true, parameterHeaders: headers, onProgress: onProgress, onLog: onLog)
        return ToolResult(result)
    }

    public func listResources(cursor: String? = nil) async throws -> Page<Resource> {
        try await page("resources/list", key: "resources", cursor: cursor, definition: .ListResourcesResult, Resource.init)
    }
    public func listResourceTemplates(cursor: String? = nil) async throws -> Page<JSON> {
        try await page("resources/templates/list", key: "resourceTemplates", cursor: cursor, definition: .ListResourceTemplatesResult) { $0 }
    }
    /// `resources/read`; returns the `contents` array (text or base64 `blob` entries).
    public func readResource(_ uri: String) async throws -> [JSON] {
        let result = try await perform("resources/read", params: [JSONMember("uri", value: .string(uri))], name: uri, definition: .ReadResourceResult)
        return result.objectValue?["contents"]?.arrayValue ?? []
    }

    public func listPrompts(cursor: String? = nil) async throws -> Page<Prompt> {
        try await page("prompts/list", key: "prompts", cursor: cursor, definition: .ListPromptsResult, Prompt.init)
    }
    /// `prompts/get`; returns the raw result (`messages`, optional `description`).
    public func getPrompt(_ name: String, arguments: [String: String] = [:]) async throws -> JSON {
        var params = [JSONMember("name", value: .string(name))]
        if !arguments.isEmpty {
            let members = arguments.sorted { $0.key < $1.key }.map { JSONMember($0.key, value: .string($0.value)) }
            params.append(JSONMember("arguments", value: .object(try JSONObject(members: members))))
        }
        return try await perform("prompts/get", params: params, name: name, definition: .GetPromptResult)
    }

    /// `completion/complete` for a prompt or resource-template reference.
    public func complete(reference: JSON, argument name: String, value: String, context: JSON? = nil) async throws -> JSON {
        var params = [JSONMember("ref", value: reference),
                      JSONMember("argument", value: .object(try JSONObject(members: [JSONMember("name", value: .string(name)), JSONMember("value", value: .string(value))])))]
        if let context { params.append(JSONMember("context", value: context)) }
        return try await perform("completion/complete", params: params, definition: .CompleteResult)
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
    /// - Parameter notifications: the `SubscriptionFilter` object, for example
    ///   `{"toolsListChanged": true, "resourceSubscriptions": ["file:///a"]}`.
    public func listen(_ notifications: JSON, onEvent: @escaping @Sendable (ListenEvent) async throws -> Void) async throws {
        _ = try await perform("subscriptions/listen", params: [JSONMember("notifications", value: notifications)],
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
            let validator = self.validator, limits = configuration.limits
            try await transport.exchange(OutgoingRequest(id: .integer(JSONNumber(integer: id)), method: method, name: name, body: body, parameterHeaders: parameterHeaders)) { frame in
                let message = try WireCodec.parse(Array(frame), limits: limits).result
                guard let object = message.objectValue else { throw ClientError.invalidResponse("message is not an object") }
                if object["id"] != nil, object["method"] == nil {
                    guard Self.matches(object["id"], id) else { throw ClientError.invalidResponse("response for another request") }
                    try final.withLock { value in
                        guard value == nil else { throw ClientError.invalidResponse("second response") }
                        value = message
                    }
                    return
                }
                guard let notification = object["method"]?.stringValue, object["id"] == nil else { throw ClientError.invalidResponse("unexpected message") }
                try await Self.dispatch(notification, params: object["params"], raw: message, token: token, validator: validator,
                                        onProgress: onProgress, onLog: onLog, onEvent: onEvent)
            }
            guard let response = final.withLock({ $0 })?.objectValue else { throw ClientError.noResponse }
            if let error = response["error"] {
                let failure = Self.serverError(error)
                // UnsupportedProtocolVersionError: retry once when the server says it supports
                // our only version after all; otherwise report what it supports.
                if case .server(-32022, _, let data) = failure {
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
        if logs, let level = configuration.logLevel { meta.append(JSONMember("io.modelcontextprotocol/logLevel", value: .string(level))) }
        if let progressToken { meta.append(JSONMember("progressToken", value: .string(progressToken))) }
        let parameters = [JSONMember("_meta", value: .object(try JSONObject(members: meta)))] + params
        let message = JSON.object(try JSONObject(members: [
            JSONMember("jsonrpc", value: .string("2.0")), JSONMember("id", value: .number(JSONNumber(integer: id))),
            JSONMember("method", value: .string(method)), JSONMember("params", value: .object(try JSONObject(members: parameters)))]))
        return try WireCodec.write(message, limits: configuration.limits).result
    }

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
                response = try await elicitation.handler(params); definition = .ElicitResult
            case "sampling/createMessage":
                guard let sampling = configuration.sampling else { throw ClientError.unsupportedInput(method: method) }
                response = try await sampling(params); definition = .CreateMessageResult
            case "roots/list":
                guard let roots = configuration.roots else { throw ClientError.unsupportedInput(method: method) }
                response = try await roots(params); definition = .ListRootsResult
            default: throw ClientError.unsupportedInput(method: method)
            }
            guard try await validator.validate(response, as: definition) else { throw ClientError.invalidResponse("handler result for \(method)") }
            responses.append(JSONMember(entry.key.string, value: response))
        }
        return .object(try JSONObject(members: responses))
    }

    private static func dispatch(_ method: String, params: JSON?, raw: JSON, token: String?, validator: WireValidator,
                                 onProgress: (@Sendable (Progress) async -> Void)?, onLog: (@Sendable (LogMessage) async -> Void)?,
                                 onEvent: (@Sendable (ListenEvent) async throws -> Void)?) async throws {
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
            await onLog?(LogMessage(level: object?["level"]?.stringValue ?? "info", logger: object?["logger"]?.stringValue,
                                    data: object?["data"] ?? .null))
        case "notifications/subscriptions/acknowledged":
            try await check(.SubscriptionsAcknowledgedNotification)
            try await onEvent?(.acknowledged(object?["notifications"] ?? .null))
        case "notifications/tools/list_changed": try await check(.ToolListChangedNotification); try await onEvent?(.toolsChanged)
        case "notifications/resources/list_changed": try await check(.ResourceListChangedNotification); try await onEvent?(.resourcesChanged)
        case "notifications/prompts/list_changed": try await check(.PromptListChangedNotification); try await onEvent?(.promptsChanged)
        case "notifications/resources/updated":
            try await check(.ResourceUpdatedNotification)
            try await onEvent?(.resourceUpdated(uri: object?["uri"]?.stringValue ?? ""))
        case "notifications/cancelled":
            try await check(.CancelledNotification)
        default:
            // Extension notifications (for example notifications/tasks) on a listen stream.
            if let onEvent { try await onEvent(.notification(method: method, params: params ?? .null)) }
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

/// Compiles frozen 2026-07-28 definitions on first use and validates against them.
actor WireValidator {
    private var document: FrozenWireDocument?
    private var plans: [FrozenWireDefinition: WireDefinitionPlan] = [:]

    static let compileLimits: JSONLimits = {
        var limits = JSONLimits.balanced
        for key: JSONResourceMetric in [.workUnits, .compileWorkUnits, .evaluationWorkUnits, .numericWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] {
            limits[key] = 256_000_000
        }
        return limits
    }()

    func validate(_ value: JSON, as definition: FrozenWireDefinition) throws -> Bool {
        try plan(definition).validate(value, limits: Self.compileLimits).result
    }

    private func plan(_ definition: FrozenWireDefinition) throws -> WireDefinitionPlan {
        if let plan = plans[definition] { return plan }
        let document = try self.document ?? FrozenWireSchema.parse(FrozenWireSchema.read(maximumBytes: FrozenWireSchema.byteCount), limits: Self.compileLimits).result
        self.document = document
        let root = try document.root(at: definition, limits: Self.compileLimits).result
        let plan = try WireDefinitionPlan.compile(root, limits: Self.compileLimits).result
        plans[definition] = plan
        return plan
    }
}
