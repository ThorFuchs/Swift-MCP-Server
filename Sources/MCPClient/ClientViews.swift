// SPDX-License-Identifier: Apache-2.0
import JSON

/// Typed views keep the validated raw JSON, so schemas and fields this SDK does not model
/// pass through unchanged.
public struct ServerDescription: Sendable {
    /// Protocol revisions advertised by the server.
    public let supportedVersions: [String]
    /// Server-declared capabilities, including extension settings.
    public let capabilities: JSONObject
    /// Optional guidance from the server.
    public let instructions: String?
    /// Optional server implementation identity.
    public let serverInfo: Implementation?
    public let raw: JSON
    /// The server's settings for an extension, if it declares it.
    public func extensionSettings(_ identifier: String) -> JSON? { capabilities["extensions"]?.objectValue?[identifier] }
}

/// One listing page; no cross-page snapshot consistency is implied.
public struct Page<Item: Sendable>: Sendable {
    /// Items decoded from this page.
    public let items: [Item]
    /// Opaque continuation cursor, or nil at the end. An empty string is a valid cursor.
    public let nextCursor: String?
    public let raw: JSON
    /// Creates a typed page while retaining its source JSON.
    public init(items: [Item], nextCursor: String?, raw: JSON) { self.items = items; self.nextCursor = nextCursor; self.raw = raw }
}

/// A tool advertised by the server, including its input and optional output schema.
public struct Tool: Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    /// Exactly as the server sent it; never dereferenced or rewritten.
    public let inputSchema: JSON
    /// Optional schema for structured tool output.
    public let outputSchema: JSON?
    public let raw: JSON
    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let name = object["name"]?.stringValue, let input = object["inputSchema"] else {
            throw ClientError.invalidResponse("tool without name or inputSchema")
        }
        self.name = name; title = object["title"]?.stringValue; description = object["description"]?.stringValue
        inputSchema = input; outputSchema = object["outputSchema"]; self.raw = raw
    }
}

/// A complete tools/call result, or a result type an extension defines (for example
/// `resultType: "task"`), which `resultType` names and `raw` carries.
public struct ToolResult: Sendable {
    /// Wire result discriminator, including extension-defined outcomes.
    public let resultType: String
    /// Decoded content blocks returned by the tool.
    public let content: [Content]
    /// Optional structured JSON accompanying the content blocks.
    public let structuredContent: JSON?
    /// Whether the tool reports an application-level error.
    public let isError: Bool
    public let raw: JSON
    /// Creates a raw result view; this initializer does not validate the wire result.
    public init(_ raw: JSON) {
        let object = raw.objectValue
        resultType = object?["resultType"]?.stringValue ?? "complete"
        content = (object?["content"]?.arrayValue ?? []).map(Content.init)
        structuredContent = object?["structuredContent"]
        isError = object?["isError"]?.booleanValue ?? false
        self.raw = raw
    }
    /// Concatenated text of all text content blocks.
    public var text: String {
        content.compactMap(\.text).joined()
    }
}

/// A listed resource with its URI and advertised metadata.
public struct Resource: Sendable {
    public let uri: String, name: String
    public let mimeType: String?, description: String?
    public let raw: JSON
    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let uri = object["uri"]?.stringValue, let name = object["name"]?.stringValue else {
            throw ClientError.invalidResponse("resource without uri or name")
        }
        self.uri = uri; self.name = name; mimeType = object["mimeType"]?.stringValue; description = object["description"]?.stringValue; self.raw = raw
    }
}

/// A listed prompt with its name and advertised metadata.
public struct Prompt: Sendable {
    public let name: String, description: String?
    public let raw: JSON
    init(_ raw: JSON) throws {
        guard let object = raw.objectValue, let name = object["name"]?.stringValue else { throw ClientError.invalidResponse("prompt without name") }
        self.name = name; description = object["description"]?.stringValue; self.raw = raw
    }
}

/// One event of a `subscriptions/listen` stream.
public enum ListenEvent: Sendable {
    /// First event: the filters the server agreed to honor.
    case acknowledged(JSON)
    case toolsChanged, resourcesChanged, promptsChanged
    case resourceUpdated(uri: String)
    /// An extension notification such as `notifications/tasks`, with its params.
    case notification(method: String, params: JSON)
}

/// `notifications/progress` for one call.
public struct Progress: Sendable {
    /// Progress value supplied by the server.
    public let progress: Double
    /// Optional total for interpreting progress.
    public let total: Double?
    public let message: String?
}

/// `notifications/message` for one call.
public struct LogMessage: Sendable {
    /// Reported severity.
    public let level: LoggingLevel
    /// Optional name of the logger that produced the event.
    public let logger: String?
    /// Server-provided diagnostic payload; treat as untrusted data.
    public let data: JSON
}
