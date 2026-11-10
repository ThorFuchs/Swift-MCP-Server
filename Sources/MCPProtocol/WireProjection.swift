// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import JSONSchema
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A definition-specific, schema-checked projection retaining exact JSON and all
/// permitted unknown members. No unchecked public initializer or Codable bypass.
/// Shape tags prevent substituting a resource result for a tool result.
public struct WireProjection<Shape: WireShape>: Sendable {
    public let value: JSON
    fileprivate init(_ value: JSON) { self.value = value }
    public func presence(of key: String, limits: JSONLimits) throws -> JSONPresence<JSON> {
        try value.presence(of: key, limits: limits)
    }
    public func write(limits: JSONLimits) throws -> JSONOperationReport<Data> {
        try WireCodec.write(value, limits: limits)
    }
}
public protocol WireShape: Sendable {
    static var definition: FrozenWireDefinition { get }
}

/// Immutable offline plan for one frozen definition. Compile, evaluate and write
/// expose the upstream reports independently; the request owner settles each once.
public struct WireDefinitionPlan: Sendable {
    public let definition: FrozenWireDefinition
    private let plan: CompiledJSONSchema
    public static func compile(_ schema: FrozenWireRoot,
                               limits: JSONLimits) throws -> JSONOperationReport<Self> {
        let report = try JSONSchemaCompiler(options: .init(limits: limits)).compileWithReport(schema.raw, registry: .empty)
        return .init(result: .init(definition: schema.definition, plan: report.result), statistics: report.statistics)
    }
    public func validate(_ value: JSON, limits: JSONLimits) throws -> JSONOperationReport<Bool> {
        let report = try JSONSchemaValidator(options: .init(limits: limits, output: .flag)).validateWithReport(value, against: plan)
        return .init(result: report.result.isValid, statistics: report.statistics)
    }
    /// Ordinary invalidity produces nil, preserving its reported work. Operational
    /// errors throw and are terminal at the request account boundary.
    public func project<Shape>(_ value: JSON, as: WireProjection<Shape>.Type,
                              limits: JSONLimits) throws -> JSONOperationReport<WireProjection<Shape>?> {
        guard definition == Shape.definition else { throw WireFailure.invalidParams }
        let report = try validate(value, limits: limits)
        return .init(result: report.result ? WireProjection(value) : nil, statistics: report.statistics)
    }
}

public struct FrozenWireDocument: Sendable {
    fileprivate let raw: JSON
    public func root(at definition: FrozenWireDefinition, limits: JSONLimits) throws -> JSONOperationReport<FrozenWireRoot> {
        struct Root: Encodable {
            let dialect: String
            let definitions: Definitions
            let reference: String
            enum CodingKeys: String, CodingKey { case dialect = "$schema", definitions = "$defs", reference = "$ref" }
        }
        let encoded = try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(
            Root(dialect: "https://json-schema.org/draft/2020-12/schema",
                 definitions: Definitions(raw: raw.objectValue!["$defs"]!, selected: definition.reachableDefinitions),
                 reference: "#/$defs/" + definition.rawValue))
        return .init(result: .init(definition: definition, raw: encoded.result), statistics: encoded.statistics)
    }
}
public struct FrozenWireRoot: Sendable {
    public let definition: FrozenWireDefinition
    fileprivate let raw: JSON
}

public enum FrozenWireSchema {
    public static let sha256 = "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203"
    public static let byteCount = 181_474
    /// Registration I/O, bounded before reading. The owner accounts these bytes
    /// separately from parsing/compilation. There is no network schema resolver.
    public static func read(maximumBytes: Int) throws -> Data {
        guard maximumBytes >= byteCount else { throw WireFailure.limit }
        return try read(maximumBytes: maximumBytes, in: Bundle.module)
    }

    // The module bundle owns selection. The internal overload permits real bundle
    // fixtures without changing the public API or accepting a host-selected URL.
    static func read(maximumBytes: Int, in bundle: Bundle) throws -> Data {
        guard maximumBytes >= byteCount else { throw WireFailure.limit }
        let url = try schemaURL(bundleURL: bundle.bundleURL, resourceURL: bundle.resourceURL)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try Task.checkCancellation()
        let data = try file.read(upToCount: byteCount + 1) ?? Data()
        guard data.count == byteCount else { throw WireFailure.invalidRequest }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw WireFailure.invalidRequest
        }
        return data
    }
    // SwiftPM copies the Resources directory intact. In a flat bundle,
    // Foundation can already report that directory as resourceURL. Appending it
    // again gives Resources/Resources. A canonical macOS BNDL instead places
    // the copied directory inside Contents/Resources. Select exactly one layout;
    // a missing/corrupt selected resource never triggers a search or fallback.
    static func schemaURL(bundleURL: URL, resourceURL: URL?) throws -> URL {
        guard bundleURL.isFileURL, let resourceURL, resourceURL.isFileURL else {
            throw WireFailure.invalidRequest
        }
        let root = bundleURL.standardizedFileURL
        let resources = resourceURL.standardizedFileURL
        let copied = root.appendingPathComponent("Resources", isDirectory: true)
        let canonical = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let base: URL
        if resources.path == canonical.path {
            base = canonical
        } else if resources.path == root.path || resources.path == copied.path {
            base = root
        } else {
            throw WireFailure.invalidRequest
        }
        return base.appendingPathComponent("Resources/schema.json", isDirectory: false)
    }
    /// Hashing has a fixed byte ceiling and is charged separately by the owner.
    public static func parse(_ data: Data, limits: JSONLimits) throws -> JSONOperationReport<FrozenWireDocument> {
        guard data.count == byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw WireFailure.invalidRequest
        }
        let report = try JSONParser(options: .init(limits: limits)).parseWithReport(Array(data))
        guard report.result.objectValue?["$defs"]?.objectValue?.count == 155 else { throw WireFailure.invalidRequest }
        return .init(result: .init(raw: report.result), statistics: report.statistics)
    }
}

// Normative dated text supplies constraints that the generated frozen schema
// describes but does not assert. Compose an offline allOf overlay; never change
// the frozen bytes or implement a second validator. See D16 and wire tests.
private struct Definitions: Encodable {
    let raw: JSON
    let selected: Set<String>
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for member in raw.objectValue! {
            guard selected.contains(member.key.string) else { continue }
            if let rule = NormativeRule(name: member.key.string) {
                try container.encode(Composition(raw: member.value, rule: rule), forKey: Key(member.key.string))
            } else { try container.encode(member.value, forKey: Key(member.key.string)) }
        }
    }
}
private struct Composition: Encodable {
    let raw: JSON
    let rule: NormativeRule
    enum CodingKeys: String, CodingKey { case allOf }
    func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: CodingKeys.self)
        var array = object.nestedUnkeyedContainer(forKey: .allOf)
        try array.encode(raw); try array.encode(rule)
    }
}
private struct NormativeRule: Encodable {
    let name: String
    init?(name: String) {
        guard ["InputRequiredResult", "CallToolResult", "DiscoverResult", "GetPromptResult",
               "ListPromptsResult", "ListResourcesResult", "ListResourceTemplatesResult",
               "ListToolsResult", "ReadResourceResult", "SubscriptionsListenResult", "CompleteResult", "Root",
               "MetaObject", "RequestMetaObject", "ResultMetaObject", "NotificationMetaObject",
               "SubscriptionsListenResultMetaObject", "ClientCapabilities", "ServerCapabilities"].contains(name) else { return nil }
        self.name = name
    }
    struct Constant: Encodable { let `const`: String }
    struct Required: Encodable { let required: [String] }
    struct Pattern: Encodable { let pattern: String }
    enum CodingKeys: String, CodingKey { case properties, anyOf, propertyNames }
    enum Properties: String, CodingKey { case resultType, uri, completion, extensions }
    struct NamePattern: Encodable {
        let pattern: String
        let not = Pattern(pattern: "[\\r\\n\\u2028\\u2029]")
    }
    struct Names: Encodable { let propertyNames: NamePattern }
    struct Completion: Encodable {
        struct Items: Encodable { let maxItems = 100 }
        struct Properties: Encodable { let values = Items() }
        let properties = Properties()
    }
    func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: CodingKeys.self)
        let prefix = "[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*/"
        let keyName = "(?:[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?)?"
        if name.hasSuffix("MetaObject") || name == "MetaObject" {
            try object.encode(NamePattern(pattern: "^(?:" + prefix + ")?" + keyName + "$"), forKey: .propertyNames)
            try object.encode(TraceMetadataRules(), forKey: .properties)
            return
        }
        var properties = object.nestedContainer(keyedBy: Properties.self, forKey: .properties)
        if name == "ClientCapabilities" || name == "ServerCapabilities" {
            try properties.encode(Names(propertyNames: NamePattern(pattern: "^" + prefix + keyName + "$")), forKey: .extensions)
            return
        }
        if name == "Root" { try properties.encode(Pattern(pattern: "^file://"), forKey: .uri); return }
        try properties.encode(Constant(const: name == "InputRequiredResult" ? "input_required" : "complete"), forKey: .resultType)
        if name == "InputRequiredResult" {
            try object.encode([Required(required: ["inputRequests"]), Required(required: ["requestState"])], forKey: .anyOf)
        }
        if name == "CompleteResult" { try properties.encode(Completion(), forKey: .completion) }
    }
}
