// SPDX-License-Identifier: Apache-2.0
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import JSON
import MCPClient
import MCPSkillsFormat

/// One skill a server lists (`skills/list`, `skills/get`), before anything is fetched.
public struct SkillEntry: Sendable {
    /// The `SKILL.md` URI, for example `skill://pdf-processing/SKILL.md`.
    public let uri: String
    /// The frontmatter as the server declared it.
    public let frontmatter: JSON
    /// Every file of the skill with its expected digest and size, `SKILL.md` included.
    public let files: [SkillFileEntry]
    public let raw: JSON

    public var name: String? { frontmatter.objectValue?["name"]?.stringValue }
    public var description: String? { frontmatter.objectValue?["description"]?.stringValue }

    init(_ value: JSON) throws {
        guard let object = value.objectValue, let uri = object["uri"]?.stringValue, uri.hasPrefix("skill://"),
              let frontmatter = object["frontmatter"], frontmatter.objectValue != nil,
              let resources = object["resources"]?.arrayValue else { throw ClientError.invalidResponse("skill entry") }
        self.uri = uri; self.frontmatter = frontmatter; raw = value
        files = try resources.map(SkillFileEntry.init)
    }
}

/// One file of a skill as the server listed it.
public struct SkillFileEntry: Sendable, Equatable {
    public let uri: String
    /// `sha256:` followed by 64 lowercase hex digits.
    public let digest: String
    /// The size in bytes.
    public let size: Int

    init(_ value: JSON) throws {
        guard let object = value.objectValue, let uri = object["uri"]?.stringValue, let digest = object["digest"]?.stringValue,
              let size = try? object["size"]?.numberValue?.integer(as: Int.self), size >= 0 else {
            throw ClientError.invalidResponse("skill resource entry")
        }
        self.uri = uri; self.digest = digest; self.size = size
    }
}

/// A skill whose `SKILL.md` was fetched and verified.
public struct LoadedSkill: Sendable {
    public let entry: SkillEntry
    /// The verified `SKILL.md`, frontmatter included.
    public let markdown: String
}

/// Why fetched skill content was rejected. Rejected content is never returned.
public enum SkillVerificationError: Error, Sendable, Equatable {
    /// The URI is not a file of this skill's entry, so it cannot be verified.
    case notListed(uri: String)
    /// The server returned no content for the URI.
    case missingContent(uri: String)
    /// The byte length differs from the entry's `size`.
    case sizeMismatch(uri: String, expected: Int, actual: Int)
    /// The SHA-256 digest differs from the entry's `digest`.
    case digestMismatch(uri: String)
    /// The entry's digest is not `sha256:` plus 64 lowercase hex digits.
    case unsupportedDigest(uri: String)
    /// `SKILL.md` is not UTF-8 or its frontmatter does not parse.
    case invalidFrontmatter(uri: String, reason: String)
    /// The parsed frontmatter differs from the entry's frontmatter in this top-level field.
    case frontmatterMismatch(uri: String, field: String)
}

/// The client side of the Skills extension (`io.modelcontextprotocol/skills`, SEP-2640).
///
/// Nothing is fetched ahead of need: `list` and `get` return entries only; `load` fetches
/// `SKILL.md`; `file` fetches one supporting file when the host needs it. Every fetched
/// file is checked against its entry's size and SHA-256 digest, and `SKILL.md`'s
/// frontmatter is compared field by field with the entry's, before anything is returned.
public struct SkillsClient: Sendable {
    public static let extensionIdentifier = "io.modelcontextprotocol/skills"
    public let client: Client

    public init(client: Client) { self.client = client }

    /// Whether the server declares the extension (from `server/discover`).
    public static func isSupported(by server: ServerDescription) -> Bool {
        server.extensionSettings(extensionIdentifier) != nil
    }

    /// `skills/list`: one page of entries.
    public func list(cursor: String? = nil) async throws -> Page<SkillEntry> {
        let params = cursor.map { [JSONMember("cursor", value: .string($0))] } ?? []
        let result = try await client.request("skills/list", params: params)
        guard let skills = result.objectValue?["skills"]?.arrayValue else { throw ClientError.invalidResponse("skills/list result") }
        return Page(items: try skills.map(SkillEntry.init), nextCursor: result.objectValue?["nextCursor"]?.stringValue, raw: result)
    }

    /// `skills/get`: the entry of one skill by its `SKILL.md` URI.
    public func get(_ uri: String) async throws -> SkillEntry {
        let result = try await client.request("skills/get", params: [JSONMember("uri", value: .string(uri))])
        guard let skill = result.objectValue?["skill"] else { throw ClientError.invalidResponse("skills/get result") }
        return try SkillEntry(skill)
    }

    /// Fetches and verifies `SKILL.md`. Throws `SkillVerificationError` on any mismatch.
    public func load(_ entry: SkillEntry) async throws -> LoadedSkill {
        let bytes = try await fetch(entry.uri, of: entry)
        guard let markdown = String(validating: bytes, as: UTF8.self) else {
            throw SkillVerificationError.invalidFrontmatter(uri: entry.uri, reason: "not UTF-8")
        }
        let parsed: FrontmatterValue
        do { parsed = try Frontmatter.parse(markdown) }
        catch { throw SkillVerificationError.invalidFrontmatter(uri: entry.uri, reason: "line \(error.line): \(error.reason)") }
        if let field = Self.mismatch(parsed, entry.frontmatter) {
            throw SkillVerificationError.frontmatterMismatch(uri: entry.uri, field: field)
        }
        return LoadedSkill(entry: entry, markdown: markdown)
    }

    /// Fetches and verifies one file of a loaded skill.
    public func file(_ uri: String, of skill: LoadedSkill) async throws -> [UInt8] {
        try await fetch(uri, of: skill.entry)
    }

    // MARK: Verification

    private func fetch(_ uri: String, of entry: SkillEntry) async throws -> [UInt8] {
        guard let expected = entry.files.first(where: { $0.uri == uri }) else { throw SkillVerificationError.notListed(uri: uri) }
        let contents = try await client.readResource(uri)
        guard let content = contents.first(where: { $0.uri == uri }) else { throw SkillVerificationError.missingContent(uri: uri) }
        let bytes = content.bytes
        try Self.verify(bytes, against: expected)
        return bytes
    }

    static func verify(_ bytes: [UInt8], against expected: SkillFileEntry) throws(SkillVerificationError) {
        guard bytes.count == expected.size else {
            throw .sizeMismatch(uri: expected.uri, expected: expected.size, actual: bytes.count)
        }
        let hex = expected.digest.dropFirst("sha256:".count)
        guard expected.digest.hasPrefix("sha256:"), hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw .unsupportedDigest(uri: expected.uri)
        }
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == hex else { throw .digestMismatch(uri: expected.uri) }
    }

    /// The first top-level field where the parsed frontmatter and the entry's differ, or nil.
    static func mismatch(_ parsed: FrontmatterValue, _ declared: JSON) -> String? {
        guard case .mapping(let fields) = parsed, let object = declared.objectValue else { return "(root)" }
        let parsedKeys = Set(fields.map(\.key)), declaredKeys = Set(object.members.map(\.key.string))
        for key in parsedKeys.symmetricDifference(declaredKeys).sorted() { return key }
        for (key, value) in fields where !matches(value, object[key]!) { return key }
        return nil
    }

    static func matches(_ parsed: FrontmatterValue, _ declared: JSON) -> Bool {
        switch (parsed, declared) {
        case (.string(let a), .string(let b)): return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.null, .null): return true
        case (.integer(let a), .number(let b)): return (try? b.integer(as: Int64.self)) == a
        case (.double(let a), .number(let b)): return (try? b.doubleValue()) == a
        case (.sequence(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { matches($0, $1) }
        case (.mapping(let fields), .object(let object)):
            guard fields.count == object.count, Set(fields.map(\.key)) == Set(object.members.map(\.key.string)) else { return false }
            return fields.allSatisfy { key, value in object[key].map { matches(value, $0) } ?? false }
        default: return false
        }
    }
}
