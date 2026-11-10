// SPDX-License-Identifier: Apache-2.0
/// Exact core method inventory from Contracts/method-registry.json.
public enum WireMethod: String, Sendable, CaseIterable {
    case discover = "server/discover"
    case listTools = "tools/list"
    case callTool = "tools/call"
    case listResources = "resources/list"
    case listResourceTemplates = "resources/templates/list"
    case readResource = "resources/read"
    case listPrompts = "prompts/list"
    case getPrompt = "prompts/get"
    case complete = "completion/complete"
    case listen = "subscriptions/listen"
    case elicit = "elicitation/create"
    case createMessage = "sampling/createMessage"
    case listRoots = "roots/list"
    case cancelled = "notifications/cancelled"
    case logMessage = "notifications/message"
    case progress = "notifications/progress"
    case promptsChanged = "notifications/prompts/list_changed"
    case resourcesChanged = "notifications/resources/list_changed"
    case resourceUpdated = "notifications/resources/updated"
    case acknowledged = "notifications/subscriptions/acknowledged"
    case toolsChanged = "notifications/tools/list_changed"

    public enum Leg: Sendable { case clientRequest, inputRequest, serverNotification }
    public var leg: Leg {
        switch self {
        case .elicit, .createMessage, .listRoots: .inputRequest
        case .cancelled, .logMessage, .progress, .promptsChanged, .resourcesChanged,
             .resourceUpdated, .acknowledged, .toolsChanged: .serverNotification
        default: .clientRequest
        }
    }
    public var permitsInputRequired: Bool {
        self == .callTool || self == .readResource || self == .getPrompt
    }
    public var requiresCacheHints: Bool {
        switch self {
        case .discover, .listTools, .listPrompts, .listResources, .listResourceTemplates, .readResource: true
        default: false
        }
    }
    public var mirroredNameField: String? {
        switch self {
        case .callTool, .getPrompt: "name"
        case .readResource: "uri"
        default: nil
        }
    }
}
public enum ProtocolMetadata {
    public static let version = "2026-07-28"
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
}
