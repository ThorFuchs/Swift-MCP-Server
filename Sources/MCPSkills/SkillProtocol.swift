// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import MCPSkillsFormat

enum SkillSchemas {
    static let settings = #"{"type":"object"}"#
    static let listParameters = #"{"type":"object","properties":{"cursor":{"type":"string","maxLength":32}}}"#
    static let getParameters = #"{"type":"object","required":["uri"],"properties":{"uri":{"type":"string","minLength":1,"maxLength":4096}}}"#
    static let directoryParameters = #"""
    {"type":"object","required":["uri"],"properties":{"uri":{"type":"string","minLength":1,"maxLength":4096},"cursor":{"type":"string","maxLength":32}}}
    """#
    static let entry = #"""
    {"type":"object","required":["uri","frontmatter","resources"],"properties":{
      "uri":{"type":"string"},
      "frontmatter":{"type":"object","required":["name","description"],"properties":{"name":{"type":"string"},"description":{"type":"string"}}},
      "resources":{"anyOf":[{"const":"dynamic"},{"type":"array","maxItems":512,"items":{"type":"object","required":["uri","digest","size"],
        "properties":{"uri":{"type":"string"},"digest":{"type":"string","pattern":"^sha256:[0-9a-f]{64}$"},"size":{"type":"integer","minimum":0}}}}]}}}
    """#
    static let cacheable = #""resultType":{"const":"complete"},"ttlMs":{"type":"integer","minimum":0},"cacheScope":{"enum":["public","private"]}"#
    static let listResult = #"{"type":"object","required":["resultType","skills","ttlMs","cacheScope"],"properties":{\#(cacheable),"skills":{"type":"array","items":\#(entry)},"nextCursor":{"type":"string"}}}"#
    static let getResult = #"{"type":"object","required":["resultType","skill","ttlMs","cacheScope"],"properties":{\#(cacheable),"skill":\#(entry)},"not":{"required":["nextCursor"]}}"#
    static let directoryResult = #"""
    {"type":"object","required":["resultType","resources","ttlMs","cacheScope"],"properties":{\#(cacheable),
      "resources":{"type":"array","items":{"type":"object","required":["uri","name"],"properties":{"uri":{"type":"string"},"name":{"type":"string"},"mimeType":{"type":"string"}}}},
      "nextCursor":{"type":"string"}}}
    """#
    static func parse(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
}

extension SkillCatalog {
    /// The extension registration to pass to `ServerCatalog(extensions:)`. Declares
    /// `directoryRead: true`. Clients call these methods after reading the server's
    /// declaration; they need not declare the extension themselves.
    public func registration() throws -> ExtensionRegistration {
        let catalog = self, scopes = configuration.requiredScopes
        return ExtensionRegistration(official: ScalarText(Self.identifier), settingsSchema: try SkillSchemas.parse(SkillSchemas.settings),
            capabilities: try SkillSchemas.parse(#"{"directoryRead":true}"#),
            reservedNames: [ScalarText("skills/list"), ScalarText("skills/get"), ScalarText("resources/directory/read")],
            requests: [
                ExtensionRequest(method: ScalarText("skills/list"), parametersSchema: try SkillSchemas.parse(SkillSchemas.listParameters),
                    completeResultSchema: try SkillSchemas.parse(SkillSchemas.listResult), requiredScopes: scopes) { input, context in
                    try await catalog.list(input, context)
                },
                ExtensionRequest(method: ScalarText("skills/get"), parametersSchema: try SkillSchemas.parse(SkillSchemas.getParameters),
                    completeResultSchema: try SkillSchemas.parse(SkillSchemas.getResult), requiredScopes: scopes) { input, context in
                    try await catalog.get(input, context)
                },
                ExtensionRequest(method: ScalarText("resources/directory/read"), parametersSchema: try SkillSchemas.parse(SkillSchemas.directoryParameters),
                    completeResultSchema: try SkillSchemas.parse(SkillSchemas.directoryResult), requiredScopes: scopes) { input, context in
                    try await catalog.readDirectory(input, context)
                },
            ],
            clientDeclarationRequired: false)
    }

    /// One resource per skill file, read with `resources/read`. Add them to the same
    /// `ServerCatalog` as `registration()`.
    public func resources() throws -> [ResourceProvider] {
        try files.values.sorted { $0.uri.utf8.lexicographicallyPrecedes($1.uri.utf8) }.map { file in
            var definition = Fields()
            if let description = file.description {
                // SKILL.md: name and description come from its frontmatter (the name is the final path segment).
                definition.add("uri", file.uri); definition.add("name", String(file.uri.dropLast("/SKILL.md".count).split(separator: "/").last!))
                definition.add("description", description)
            } else { definition.add("uri", file.uri); definition.add("name", file.name) }
            definition.add("mimeType", file.mimeType); definition.add("size", file.bytes.count)
            let text = file.mimeType.hasPrefix("text/") || ["application/json", "application/yaml", "application/xml", "image/svg+xml"].contains(file.mimeType)
                ? String(validating: file.bytes, as: UTF8.self) : nil
            var content = Fields()
            content.add("uri", file.uri); content.add("mimeType", file.mimeType)
            if let text { content.add("text", text) } else { content.add("blob", Data(file.bytes).base64EncodedString()) }
            var read = Fields()
            read.add("resultType", "complete"); read.add("contents", [content])
            let result = try Self.encode(read)
            return ResourceProvider(definition: try Self.encode(definition), requiredScopes: configuration.requiredScopes) { _, context in
                try context.checkCancellation()
                return result
            }
        }
    }

    // MARK: Methods

    func list(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        let start = try offset(input, count: skills.count)
        let page = skills[start..<min(start + configuration.pageSize, skills.count)]
        var members: [JSONMember] = [.init("resultType", value: .string("complete")),
                                     .init("skills", value: .array(try page.map(entry)))]
        if page.endIndex < skills.count { members.append(.init("nextCursor", value: .string(String(page.endIndex)))) }
        return try await RuntimeJSON.object(members + cacheMembers(), budget: context.budget)
    }

    func get(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        guard case .value(let params) = input, let uri = params.objectValue?["uri"]?.stringValue,
              let position = skillIndex[uri] else { throw CoreFailure.invalidInput }
        return try await RuntimeJSON.object([.init("resultType", value: .string("complete")), .init("skill", value: try entry(skills[position]))]
            + cacheMembers(), budget: context.budget)
    }

    func readDirectory(_ input: JSONPresence<JSON>, _ context: RequestContext) async throws -> JSON {
        guard case .value(let params) = input, let uri = params.objectValue?["uri"]?.stringValue,
              let children = directories[uri] else { throw CoreFailure.invalidInput }
        let start = try offset(input, count: children.count)
        let page = children[start..<min(start + configuration.pageSize, children.count)]
        let resources = try page.map { child -> JSON in
            var fields = Fields()
            fields.add("uri", child.uri); fields.add("name", child.name)
            fields.add("mimeType", child.directory ? "inode/directory" : files[child.uri]!.mimeType)
            return try Self.encode(fields)
        }
        var members: [JSONMember] = [.init("resultType", value: .string("complete")), .init("resources", value: .array(resources))]
        if page.endIndex < children.count { members.append(.init("nextCursor", value: .string(String(page.endIndex)))) }
        return try await RuntimeJSON.object(members + cacheMembers(), budget: context.budget)
    }

    // MARK: Encoding

    /// Cursors are page offsets; a malformed or out-of-range cursor is `-32602`.
    private func offset(_ input: JSONPresence<JSON>, count: Int) throws -> Int {
        guard case .value(let params) = input, let cursor = params.objectValue?["cursor"] else { return 0 }
        guard let text = cursor.stringValue, text.allSatisfy(\.isASCII), let value = Int(text), value > 0, value < count else { throw CoreFailure.invalidCursor }
        return value
    }
    private func cacheMembers() -> [JSONMember] {
        [.init("ttlMs", value: .number(JSONNumber(integer: Int(configuration.cache.ttlMilliseconds)))),
         .init("cacheScope", value: .string(configuration.cache.scope.rawValue))]
    }
    func entry(_ skill: Skill) throws -> JSON {
        struct Resource: Encodable { let uri: String, digest: String, size: Int }
        struct Entry: Encodable { let uri: String, frontmatter: FrontmatterValue, resources: [Resource] }
        let resources = skill.files.map { uri in Resource(uri: uri, digest: files[uri]!.digest, size: files[uri]!.bytes.count) }
        return try Self.encode(Entry(uri: skill.uri, frontmatter: skill.frontmatter, resources: resources))
    }
    static func encode(_ value: some Encodable) throws -> JSON {
        var limits = JSONLimits.balanced
        limits[.outputBytes] = 64 * 1024 * 1024
        return try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(value).result
    }
}

/// Ordered JSON object fields of mixed encodable types.
struct Fields: Encodable, Sendable {
    private var members: [(String, any Encodable & Sendable)] = []
    mutating func add(_ key: String, _ value: any Encodable & Sendable) { members.append((key, value)) }
    private struct Name: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Name.self)
        for (key, value) in members { try container.encode(value, forKey: Name(key)) }
    }
}
