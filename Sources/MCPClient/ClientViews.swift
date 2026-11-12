// SPDX-License-Identifier: Apache-2.0
import JSON

/// Typed views keep the validated raw JSON, so schemas and fields this SDK does not model
/// pass through unchanged.
public struct ServerDescription: Sendable {
    public let supportedVersions: [String]
    public let capabilities: JSONObject
    public let instructions: String?
    public let serverInfo: JSON?
    public let raw: JSON
    /// The server's settings for an extension, if it declares it.
    public func extensionSettings(_ identifier: String) -> JSON? { capabilities["extensions"]?.objectValue?[identifier] }
}

public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public let raw: JSON
    public init(items: [Item], nextCursor: String?, raw: JSON) { self.items = items; self.nextCursor = nextCursor; self.raw = raw }
}

public struct Tool: Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    /// Exactly as the server sent it; never dereferenced or rewritten.
    public let inputSchema: JSON
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
    public let resultType: String
    public let content: [JSON]
    public let structuredContent: JSON?
    public let isError: Bool
    public let raw: JSON
    init(_ raw: JSON) {
        let object = raw.objectValue
        resultType = object?["resultType"]?.stringValue ?? "complete"
        content = object?["content"]?.arrayValue ?? []
        structuredContent = object?["structuredContent"]
        isError = object?["isError"]?.booleanValue ?? false
        self.raw = raw
    }
    /// Concatenated text of all text content blocks.
    public var text: String {
        content.compactMap { $0.objectValue?["type"]?.stringValue == "text" ? $0.objectValue?["text"]?.stringValue : nil }.joined()
    }
}

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
    public let progress: Double
    public let total: Double?
    public let message: String?
}

/// `notifications/message` for one call.
public struct LogMessage: Sendable {
    public let level: String
    public let logger: String?
    public let data: JSON
}
