// SPDX-License-Identifier: Apache-2.0
import MCPProtocol

/// A server-admitted route. Frozen core inventory remains WireMethod (21 entries).
/// Supplemental routes are registered and negotiated, never client-created authority.
public struct RequestMethod: Sendable, Hashable {
    public let core: WireMethod?
    public let extensionNamespace: ScalarText?
    public let rawValue: String
    init(_ core: WireMethod) { self.core = core; extensionNamespace = nil; rawValue = core.rawValue }
    init(namespace: ScalarText, method: ScalarText) { core = nil; extensionNamespace = namespace; rawValue = method.description }
    var resultDefinition: FrozenWireDefinition? { core?.resultDefinition }
    var permitsInputRequired: Bool { core?.permitsInputRequired == true }
    var requiresCacheHints: Bool { core?.requiresCacheHints == true }
    public static let discover = Self(WireMethod.discover)
    public static let listTools = Self(WireMethod.listTools)
    public static let callTool = Self(WireMethod.callTool)
    public static let listResources = Self(WireMethod.listResources)
    public static let listResourceTemplates = Self(WireMethod.listResourceTemplates)
    public static let readResource = Self(WireMethod.readResource)
    public static let listPrompts = Self(WireMethod.listPrompts)
    public static let getPrompt = Self(WireMethod.getPrompt)
    public static let complete = Self(WireMethod.complete)
    public static let listen = Self(WireMethod.listen)
    public static let elicit = Self(WireMethod.elicit)
    public static let createMessage = Self(WireMethod.createMessage)
    public static let listRoots = Self(WireMethod.listRoots)
    public static let cancelled = Self(WireMethod.cancelled)
    public static let logMessage = Self(WireMethod.logMessage)
    public static let progress = Self(WireMethod.progress)
    public static let promptsChanged = Self(WireMethod.promptsChanged)
    public static let resourcesChanged = Self(WireMethod.resourcesChanged)
    public static let resourceUpdated = Self(WireMethod.resourceUpdated)
    public static let acknowledged = Self(WireMethod.acknowledged)
    public static let toolsChanged = Self(WireMethod.toolsChanged)
}
