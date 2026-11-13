// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer

/// Server helpers for MCP Apps (`io.modelcontextprotocol/ui`, SEP-1865, stable 2026-01-26):
/// interactive HTML views a host renders for a tool.
///
/// A view is a `ui://` resource with MIME type `text/html;profile=mcp-app` (`AppView`); a
/// tool points at it with `_meta.ui.resourceUri` (`AppView.annotate`). Tools must still
/// return meaningful `content` for hosts without MCP Apps; `clientRendersApps` tells a
/// handler whether the calling host declared support.
public enum MCPApps {
    public static let extensionIdentifier = "io.modelcontextprotocol/ui"
    public static let mimeType = "text/html;profile=mcp-app"

    /// Declares the extension in `server/discover`. Optional: hosts decide from their own
    /// declaration; registering it only advertises support.
    public static func registration() throws -> ExtensionRegistration {
        ExtensionRegistration(official: ScalarText(extensionIdentifier),
            settingsSchema: try WireCodec.parse(Array(#"{"type":"object"}"#.utf8), limits: .balanced).result,
            reservedNames: [])
    }

    /// Whether the calling host declared MCP Apps with `text/html;profile=mcp-app` in
    /// `clientCapabilities.extensions["io.modelcontextprotocol/ui"].mimeTypes`.
    public static func clientRendersApps(_ context: RequestContext) -> Bool {
        let declaration = context.capabilities["extensions"]?.objectValue?[extensionIdentifier]?.objectValue
        return declaration?["mimeTypes"]?.arrayValue?.contains { $0.stringValue == mimeType } ?? false
    }

    /// Checks that every tool's `_meta.ui.resourceUri` names a `ui://` resource among
    /// `resources` with the MCP Apps MIME type. Call it on the catalog you serve.
    public static func validate(tools: [ToolRegistration], resources: [ResourceProvider]) throws(AppDefinitionError) {
        var views: [String: String?] = [:]
        for resource in resources {
            guard let uri = resource.definition.objectValue?["uri"]?.stringValue, uri.hasPrefix("ui://") else { continue }
            views[uri] = resource.definition.objectValue?["mimeType"]?.stringValue
        }
        for tool in tools {
            let name = tool.definition.objectValue?["name"]?.stringValue ?? "(unnamed)"
            guard let ui = tool.definition.objectValue?["_meta"]?.objectValue?["ui"]?.objectValue,
                  let reference = ui["resourceUri"] else { continue }
            guard let uri = reference.stringValue else { throw AppDefinitionError(subject: name, reason: "_meta.ui.resourceUri is not a string") }
            guard let mime = views[uri] else { throw AppDefinitionError(subject: name, reason: "references \(uri), which is not a served ui:// resource") }
            guard mime == mimeType else { throw AppDefinitionError(subject: name, reason: "references \(uri), whose mimeType is not \(mimeType)") }
        }
    }
}

/// Why an app view or tool reference is invalid. Thrown when a catalog is built.
public struct AppDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let subject: String
    public let reason: String
    public var description: String { "\(subject): \(reason)" }
}

/// Who may call a tool: the model, the app view, or both (the default).
public enum AppToolVisibility: String, Sendable, CaseIterable {
    case model, app
}

/// A device capability the view asks the host for (`_meta.ui.permissions`).
public enum AppPermission: String, Sendable, CaseIterable {
    case camera, microphone, geolocation, clipboardWrite
}

/// Origins the view may reach (`_meta.ui.csp`). Hosts block everything not declared.
public struct AppContentSecurityPolicy: Sendable, Equatable {
    public var connectDomains: [String]
    public var resourceDomains: [String]
    public var frameDomains: [String]
    public var baseUriDomains: [String]
    public init(connectDomains: [String] = [], resourceDomains: [String] = [], frameDomains: [String] = [], baseUriDomains: [String] = []) {
        self.connectDomains = connectDomains; self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains; self.baseUriDomains = baseUriDomains
    }
}

/// Rendering hints for a view (`_meta.ui` on the resource and its contents).
public struct AppViewMetadata: Sendable, Equatable {
    public var csp: AppContentSecurityPolicy?
    public var permissions: Set<AppPermission>
    /// A dedicated origin for the view, in the host's format.
    public var domain: String?
    /// Whether the host should draw a border; nil leaves it to the host.
    public var prefersBorder: Bool?
    public init(csp: AppContentSecurityPolicy? = nil, permissions: Set<AppPermission> = [], domain: String? = nil, prefersBorder: Bool? = nil) {
        self.csp = csp; self.permissions = permissions; self.domain = domain; self.prefersBorder = prefersBorder
    }
}

/// One HTML view served as a `ui://` resource.
public struct AppView: Sendable {
    public let uri: String
    public let name: String
    public let description: String?
    public let html: String
    public let metadata: AppViewMetadata

    /// Validates the view: a `ui://` URI with a host and no query or fragment, non-empty
    /// HTML, and CSP entries that are `http(s)` or `ws(s)` origins (a leading `*.` wildcard
    /// is allowed in the host).
    public init(uri: String, name: String, description: String? = nil, html: String, metadata: AppViewMetadata = .init()) throws(AppDefinitionError) {
        guard uri.hasPrefix("ui://"), let components = URLComponents(string: uri), components.scheme == "ui",
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil else {
            throw AppDefinitionError(subject: uri, reason: "a view URI must be ui://<server>/<path> without query or fragment")
        }
        guard !name.isEmpty else { throw AppDefinitionError(subject: uri, reason: "name is empty") }
        guard !html.isEmpty else { throw AppDefinitionError(subject: uri, reason: "html is empty") }
        if let csp = metadata.csp {
            for origin in csp.connectDomains + csp.resourceDomains + csp.frameDomains + csp.baseUriDomains where !Self.isOrigin(origin) {
                throw AppDefinitionError(subject: uri, reason: "\(origin) is not an http(s) or ws(s) origin")
            }
        }
        self.uri = uri; self.name = name; self.description = description; self.html = html; self.metadata = metadata
    }

    /// The resource to add to the `ServerCatalog`.
    public func resource(requiredScopes: Set<ScalarText> = []) throws -> ResourceProvider {
        var definition: [JSONMember] = [.init("uri", value: .string(uri)), .init("name", value: .string(name))]
        if let description { definition.append(.init("description", value: .string(description))) }
        definition.append(.init("mimeType", value: .string(MCPApps.mimeType)))
        let ui = try uiMetadata()
        if let ui { definition.append(.init("_meta", value: .object(try JSONObject(members: [.init("ui", value: ui)])))) }
        var content: [JSONMember] = [.init("uri", value: .string(uri)), .init("mimeType", value: .string(MCPApps.mimeType)),
                                     .init("text", value: .string(html))]
        if let ui { content.append(.init("_meta", value: .object(try JSONObject(members: [.init("ui", value: ui)])))) }
        let result = JSON.object(try JSONObject(members: [.init("resultType", value: .string("complete")),
                                                          .init("contents", value: .array([.object(try JSONObject(members: content))]))],
                                                limits: Self.limits))
        return ResourceProvider(definition: .object(try JSONObject(members: definition)), requiredScopes: requiredScopes) { _, context in
            try context.checkCancellation()
            return result
        }
    }

    /// Adds `_meta.ui.resourceUri` (and `visibility` unless it is the default of both)
    /// to a tool definition, keeping any other `_meta` members.
    public func annotate(_ toolDefinition: JSON, visibility: Set<AppToolVisibility> = [.model, .app]) throws -> JSON {
        guard let tool = toolDefinition.objectValue else { throw AppDefinitionError(subject: uri, reason: "tool definition is not an object") }
        guard !visibility.isEmpty else { throw AppDefinitionError(subject: uri, reason: "visibility is empty") }
        var ui: [JSONMember] = [.init("resourceUri", value: .string(uri))]
        if visibility != [.model, .app] {
            ui.append(.init("visibility", value: .array(AppToolVisibility.allCases.filter(visibility.contains).map { .string($0.rawValue) })))
        }
        var meta = tool["_meta"]?.objectValue?.members.filter { $0.key.string != "ui" } ?? []
        meta.append(.init("ui", value: .object(try JSONObject(members: ui))))
        let members = tool.members.filter { $0.key.string != "_meta" } + [.init("_meta", value: .object(try JSONObject(members: meta)))]
        return .object(try JSONObject(members: members))
    }

    // MARK: Encoding

    private static var limits: JSONLimits {
        var limits = JSONLimits.balanced
        limits[.outputBytes] = 16 * 1024 * 1024
        return limits
    }

    private func uiMetadata() throws -> JSON? {
        var members: [JSONMember] = []
        if let csp = metadata.csp {
            var policy: [JSONMember] = []
            for (key, values) in [("connectDomains", csp.connectDomains), ("resourceDomains", csp.resourceDomains),
                                  ("frameDomains", csp.frameDomains), ("baseUriDomains", csp.baseUriDomains)] where !values.isEmpty {
                policy.append(.init(key, value: .array(values.map(JSON.string))))
            }
            members.append(.init("csp", value: .object(try JSONObject(members: policy))))
        }
        if !metadata.permissions.isEmpty {
            let empty = JSON.object(try JSONObject())
            let permissions = AppPermission.allCases.filter(metadata.permissions.contains).map { JSONMember($0.rawValue, value: empty) }
            members.append(.init("permissions", value: .object(try JSONObject(members: permissions))))
        }
        if let domain = metadata.domain { members.append(.init("domain", value: .string(domain))) }
        if let border = metadata.prefersBorder { members.append(.init("prefersBorder", value: .boolean(border))) }
        return members.isEmpty ? nil : .object(try JSONObject(members: members))
    }

    static func isOrigin(_ text: String) -> Bool {
        guard let components = URLComponents(string: text), let scheme = components.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), var host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return false }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        return !host.isEmpty && !host.contains("*")
    }
}
