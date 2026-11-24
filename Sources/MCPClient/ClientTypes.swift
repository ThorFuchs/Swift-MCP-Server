// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON

// Typed views of 2026-07-28 shapes the client returns or its handlers exchange (CS3 A1–A11).
// Responses are validated against the frozen schema before these views are built.

// MARK: Content

/// One content block of a tool result or prompt message.
public enum Content: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    /// A resource the server can read; not necessarily listed by `resources/list`.
    case resourceLink(uri: String, name: String, mimeType: String?, description: String?)
    case embeddedResource(ResourceContents)
    /// A content type this SDK does not model, or one whose payload did not decode.
    case unknown(JSON)

    init(_ raw: JSON) {
        guard let object = raw.objectValue else { self = .unknown(raw); return }
        switch object["type"]?.stringValue {
        case "text":
            if let text = object["text"]?.stringValue { self = .text(text); return }
        case "image", "audio":
            if let encoded = object["data"]?.stringValue, let data = Data(base64Encoded: encoded), let mime = object["mimeType"]?.stringValue {
                self = object["type"]?.stringValue == "image" ? .image(data: data, mimeType: mime) : .audio(data: data, mimeType: mime); return
            }
        case "resource_link":
            if let uri = object["uri"]?.stringValue, let name = object["name"]?.stringValue {
                self = .resourceLink(uri: uri, name: name, mimeType: object["mimeType"]?.stringValue, description: object["description"]?.stringValue)
                return
            }
        case "resource":
            if let resource = object["resource"], let contents = try? ResourceContents(resource) { self = .embeddedResource(contents); return }
        default: break
        }
        self = .unknown(raw)
    }

    /// The text of a `.text` block.
    public var text: String? { if case .text(let text) = self { return text }; return nil }
}

/// One entry of `resources/read` contents or an embedded resource.
public enum ResourceContents: Sendable, Equatable {
    case text(uri: String, mimeType: String?, text: String)
    case blob(uri: String, mimeType: String?, data: Data)

    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let uri = object["uri"]?.stringValue else { throw ClientError.invalidResponse("resource contents without uri") }
        let mime = object["mimeType"]?.stringValue
        if let text = object["text"]?.stringValue { self = .text(uri: uri, mimeType: mime, text: text); return }
        guard let blob = object["blob"]?.stringValue, let data = Data(base64Encoded: blob) else {
            throw ClientError.invalidResponse("resource contents of \(uri) without text or valid base64 blob")
        }
        self = .blob(uri: uri, mimeType: mime, data: data)
    }

    /// Resource URI associated with either text or blob content.
    public var uri: String { switch self { case .text(let uri, _, _), .blob(let uri, _, _): uri } }
    /// Optional media type reported by the server.
    public var mimeType: String? { switch self { case .text(_, let mime, _), .blob(_, let mime, _): mime } }
    /// The bytes: UTF-8 of text, or the decoded blob.
    public var bytes: [UInt8] { switch self { case .text(_, _, let text): Array(text.utf8); case .blob(_, _, let data): Array(data) } }
}

// MARK: Prompts, completion, templates

/// Role of a message in a prompt or sampling conversation.
public enum Role: String, Sendable, Equatable { case user, assistant }

/// One role-tagged prompt message.
public struct PromptMessage: Sendable, Equatable {
    public let role: Role
    public let content: Content
}

/// A `prompts/get` result.
public struct PromptResult: Sendable {
    public let description: String?
    public let messages: [PromptMessage]
    public let raw: JSON
    init(_ raw: JSON) throws {
        let object = raw.objectValue
        description = object?["description"]?.stringValue
        messages = try (object?["messages"]?.arrayValue ?? []).map { message in
            guard let role = message.objectValue?["role"]?.stringValue.flatMap(Role.init(rawValue:)), let content = message.objectValue?["content"] else {
                throw ClientError.invalidResponse("prompt message without role or content")
            }
            return PromptMessage(role: role, content: Content(content))
        }
        self.raw = raw
    }
}

/// What `completion/complete` completes an argument of.
public enum CompletionReference: Sendable, Equatable {
    case prompt(name: String)
    /// A resource template, by its URI template.
    case resourceTemplate(uri: String)

    var json: JSON {
        get throws {
            switch self {
            case .prompt(let name):
                .object(try JSONObject(members: [JSONMember("type", value: .string("ref/prompt")), JSONMember("name", value: .string(name))]))
            case .resourceTemplate(let uri):
                .object(try JSONObject(members: [JSONMember("type", value: .string("ref/resource")), JSONMember("uri", value: .string(uri))]))
            }
        }
    }
}

/// A `completion/complete` result.
public struct Completion: Sendable {
    /// Completion candidates.
    public let values: [String]
    /// The total number of options, which can exceed `values.count`.
    public let total: Int?
    /// Whether more candidates are available, when reported.
    public let hasMore: Bool?
    public let raw: JSON
    init(_ raw: JSON) {
        let completion = raw.objectValue?["completion"]?.objectValue
        values = completion?["values"]?.arrayValue?.compactMap(\.stringValue) ?? []
        total = try? completion?["total"]?.numberValue?.integer(as: Int.self)
        hasMore = completion?["hasMore"]?.booleanValue
        self.raw = raw
    }
}

/// A server-advertised URI template and associated metadata.
public struct ResourceTemplate: Sendable {
    /// The original URI template, not an expanded URI.
    public let uriTemplate: String
    public let name: String
    public let title: String?
    public let description: String?
    public let mimeType: String?
    public let raw: JSON
    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let template = object["uriTemplate"]?.stringValue, let name = object["name"]?.stringValue else {
            throw ClientError.invalidResponse("resource template without uriTemplate or name")
        }
        uriTemplate = template; self.name = name; title = object["title"]?.stringValue
        description = object["description"]?.stringValue; mimeType = object["mimeType"]?.stringValue; self.raw = raw
    }
}

// MARK: Server, tools, logging

/// A client or server implementation (`serverInfo`, `clientInfo`).
public struct Implementation: Sendable, Equatable {
    public let name: String
    public let version: String
    public let title: String?
    public let raw: JSON
    init?(_ raw: JSON?) {
        guard let raw, let object = raw.objectValue, let name = object["name"]?.stringValue, let version = object["version"]?.stringValue else { return nil }
        self.name = name; self.version = version; title = object["title"]?.stringValue; self.raw = raw
    }
}

/// A tool `listTools` excluded because its `x-mcp-header` annotations are invalid.
public struct RejectedTool: Sendable, Equatable {
    public let name: String
    public let reason: String
}

/// RFC 5424 severities, as `notifications/message` and `io.modelcontextprotocol/logLevel` use them.
public enum LoggingLevel: String, Sendable, Equatable, CaseIterable, Comparable {
    case debug, info, notice, warning, error, critical, alert, emergency
    /// Orders severities from debug to emergency.
    public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
}

// MARK: Subscriptions

/// What `subscriptions/listen` asks for. Every notification type is opt-in.
public struct SubscriptionFilter: Sendable, Equatable {
    /// Requests tool catalog change notifications.
    public var toolsListChanged: Bool
    /// Requests prompt catalog change notifications.
    public var promptsListChanged: Bool
    /// Requests resource catalog change notifications.
    public var resourcesListChanged: Bool
    /// Resources to receive `notifications/resources/updated` for.
    public var resourceSubscriptions: [String]
    /// Extension members of the filter, for example `taskIds` of the Tasks extension.
    public var extensions: [String: JSON]

    /// Constructs an opt-in notification filter.
    public init(toolsListChanged: Bool = false, promptsListChanged: Bool = false, resourcesListChanged: Bool = false,
                resourceSubscriptions: [String] = [], extensions: [String: JSON] = [:]) {
        self.toolsListChanged = toolsListChanged; self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged; self.resourceSubscriptions = resourceSubscriptions; self.extensions = extensions
    }

    var json: JSON {
        get throws {
            var members: [JSONMember] = []
            if toolsListChanged { members.append(JSONMember("toolsListChanged", value: .boolean(true))) }
            if promptsListChanged { members.append(JSONMember("promptsListChanged", value: .boolean(true))) }
            if resourcesListChanged { members.append(JSONMember("resourcesListChanged", value: .boolean(true))) }
            if !resourceSubscriptions.isEmpty { members.append(JSONMember("resourceSubscriptions", value: .array(resourceSubscriptions.map(JSON.string)))) }
            for (key, value) in extensions.sorted(by: { $0.key < $1.key }) { members.append(JSONMember(key, value: value)) }
            return .object(try JSONObject(members: members))
        }
    }
}

// MARK: Input handlers (A11)

/// An `elicitation/create` request.
public struct ElicitationRequest: Sendable {
    /// The form or URL interaction requested by the server.
    public enum Mode: Sendable {
        /// Ask the user to fill a form; `requestedSchema` is a flat JSON Schema object.
        case form(requestedSchema: JSON)
        /// Send the user to `url` (for example to sign in); nothing sensitive passes the client.
        case url(URL, elicitationID: String?)
    }
    public let message: String
    /// Interaction mode and its associated schema or URL.
    public let mode: Mode
    public let raw: JSON

    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let message = object["message"]?.stringValue else { throw ClientError.invalidResponse("elicitation without message") }
        self.message = message; self.raw = raw
        if object["mode"]?.stringValue == "url" {
            guard let url = object["url"]?.stringValue.flatMap(URL.init(string:)) else { throw ClientError.invalidResponse("url elicitation without url") }
            mode = .url(url, elicitationID: object["elicitationId"]?.stringValue)
        } else {
            mode = .form(requestedSchema: object["requestedSchema"] ?? .null)
        }
    }
}

/// The user's answer to an elicitation.
public enum ElicitationResponse: Sendable, Equatable {
    /// Submitted; `content` holds the form values (nil for URL mode).
    case accept(content: JSONObject?)
    case decline
    case cancel

    var json: JSON {
        get throws {
            switch self {
            case .accept(let content):
                var members = [JSONMember("action", value: .string("accept"))]
                if let content { members.append(JSONMember("content", value: .object(content))) }
                return .object(try JSONObject(members: members))
            case .decline: return .object(try JSONObject(members: [JSONMember("action", value: .string("decline"))]))
            case .cancel: return .object(try JSONObject(members: [JSONMember("action", value: .string("cancel"))]))
            }
        }
    }
}

/// One message of a sampling conversation. `content` stays JSON: it may be a single block or
/// an array, and includes tool-use blocks this SDK passes through unchanged.
public struct SamplingMessage: Sendable, Equatable {
    public let role: Role
    public let content: JSON
    /// The text of a single text block, if that is what the message holds.
    public var text: String? { Content(content).text }
}

/// A `sampling/createMessage` request.
public struct SamplingRequest: Sendable {
    /// Conversation messages supplied for the host sampling handler.
    public let messages: [SamplingMessage]
    /// Optional system guidance requested by the server.
    public let systemPrompt: String?
    /// Requested token limit; the host remains responsible for model policy.
    public let maxTokens: Int
    /// Optional requested sampling temperature.
    public let temperature: Double?
    /// Requested stop sequences.
    public let stopSequences: [String]
    /// Everything else (`modelPreferences`, `tools`, `includeContext`, `metadata`).
    public let raw: JSON

    init(_ raw: JSON) throws {
        let object = raw.objectValue
        messages = try (object?["messages"]?.arrayValue ?? []).map { message in
            guard let role = message.objectValue?["role"]?.stringValue.flatMap(Role.init(rawValue:)), let content = message.objectValue?["content"] else {
                throw ClientError.invalidResponse("sampling message without role or content")
            }
            return SamplingMessage(role: role, content: content)
        }
        systemPrompt = object?["systemPrompt"]?.stringValue
        maxTokens = (try? object?["maxTokens"]?.numberValue?.integer(as: Int.self)) ?? 0
        temperature = try? object?["temperature"]?.numberValue?.doubleValue(policy: .rounded)
        stopSequences = object?["stopSequences"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.raw = raw
    }
}

/// The sampled message.
public struct SamplingResponse: Sendable, Equatable {
    public var role: Role
    /// A content block (or array of blocks) as JSON; `text(_:)` builds a text block.
    public var content: JSON
    /// Name of the model used by the host.
    public var model: String
    /// Optional reason the host stopped generating.
    public var stopReason: String?

    /// Creates a host-provided sampling result without starting a model.
    public init(role: Role = .assistant, content: JSON, model: String, stopReason: String? = nil) {
        self.role = role; self.content = content; self.model = model; self.stopReason = stopReason
    }

    /// A text answer.
    public static func text(_ text: String, model: String, stopReason: String? = "endTurn") throws -> SamplingResponse {
        SamplingResponse(content: .object(try JSONObject(members: [JSONMember("type", value: .string("text")), JSONMember("text", value: .string(text))])),
                         model: model, stopReason: stopReason)
    }

    var json: JSON {
        get throws {
            var members = [JSONMember("role", value: .string(role.rawValue)), JSONMember("content", value: content), JSONMember("model", value: .string(model))]
            if let stopReason { members.append(JSONMember("stopReason", value: .string(stopReason))) }
            return .object(try JSONObject(members: members))
        }
    }
}

/// A root the server may operate on (`file://` URIs in 2026-07-28).
public struct Root: Sendable, Equatable {
    public var uri: String
    public var name: String?
    /// Creates a host-declared root with an optional display name.
    public init(uri: String, name: String? = nil) { self.uri = uri; self.name = name }
}

extension [Root] {
    var json: JSON {
        get throws {
            let roots = try map { root -> JSON in
                var members = [JSONMember("uri", value: .string(root.uri))]
                if let name = root.name { members.append(JSONMember("name", value: .string(name))) }
                return .object(try JSONObject(members: members))
            }
            return .object(try JSONObject(members: [JSONMember("roots", value: .array(roots))]))
        }
    }
}
