// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import MCPSkillsFormat
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One file of a skill directory.
public struct SkillFile: Sendable {
    /// Path relative to the skill root, `/`-separated (for example `references/GUIDE.md`).
    public let path: String
    public let contents: [UInt8]
    public let mimeType: String
    public init(path: String, contents: [UInt8], mimeType: String? = nil) {
        self.path = path; self.contents = contents; self.mimeType = mimeType ?? SkillFile.mimeType(for: path)
    }
    public init(path: String, text: String, mimeType: String? = nil) {
        self.init(path: path, contents: Array(text.utf8), mimeType: mimeType)
    }
    static func mimeType(for path: String) -> String {
        switch path.split(separator: ".").last.map({ $0.lowercased() }) ?? "" {
        case "md", "markdown": "text/markdown"
        case "txt", "text": "text/plain"
        case "json": "application/json"
        case "yaml", "yml": "application/yaml"
        case "py": "text/x-python"
        case "sh": "text/x-shellscript"
        case "js", "mjs": "text/javascript"
        case "ts": "text/x-typescript"
        case "swift": "text/x-swift"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "csv": "text/csv"
        case "xml": "application/xml"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}

/// A skill directory: its location in the server's skill namespace and every file in it.
public struct SkillSource: Sendable {
    /// `/`-separated skill path whose final segment is the skill's `name`
    /// (for example `git-workflow` or `acme/billing/refunds`).
    public let path: String
    /// `SKILL.md` and every supporting file, including the files of nested skills.
    public let files: [SkillFile]
    public init(path: String, files: [SkillFile]) { self.path = path; self.files = files }
}

public struct SkillCatalogConfiguration: Sendable {
    /// `ttlMs` / `cacheScope` of `skills/list`, `skills/get` and directory reads.
    public var cache: CacheHints
    /// Entries per `skills/list` and directory page.
    public var pageSize: Int
    /// Scopes required for every skill method and skill resource.
    public var requiredScopes: Set<ScalarText>
    public init(cache: CacheHints? = nil, pageSize: Int = 50, requiredScopes: Set<ScalarText> = []) throws {
        self.cache = try cache ?? CacheHints(ttlMilliseconds: 300_000, scope: requiredScopes.isEmpty ? .public : .private)
        guard (1...500).contains(pageSize) else { throw CoreFailure.invalidPolicy }
        self.pageSize = pageSize; self.requiredScopes = requiredScopes
    }
}

/// A fixed set of skills served under the Skills extension (`io.modelcontextprotocol/skills`).
///
/// Every file becomes a `skill://` resource read with `resources/read`; `skills/list` and
/// `skills/get` return complete manifests with SHA-256 digests; `resources/directory/read`
/// lists every directory level. All validation happens here, when the catalog is built:
/// a skill that breaks the specification's rules (missing or unparsable frontmatter, a name
/// that does not match its path, limits, incomplete nesting) is an error, never served.
public struct SkillCatalog: Sendable {
    static let identifier = "io.modelcontextprotocol/skills"
    static let maximumFiles = 512
    static let maximumBytes = 16 * 1024 * 1024

    struct File: Sendable {
        let uri: String, name: String, mimeType: String, bytes: [UInt8], digest: String
        var description: String?
    }
    struct Skill: Sendable {
        let uri: String, path: String, frontmatter: FrontmatterValue, files: [String]
    }
    struct Child: Sendable, Comparable {
        let uri: String, name: String, directory: Bool
        static func < (a: Self, b: Self) -> Bool { a.uri.utf8.lexicographicallyPrecedes(b.uri.utf8) }
    }

    public let configuration: SkillCatalogConfiguration
    let skills: [Skill]
    let skillIndex: [String: Int]
    let files: [String: File]
    let directories: [String: [Child]]

    public init(_ sources: [SkillSource], configuration: SkillCatalogConfiguration? = nil) throws {
        self.configuration = try configuration ?? SkillCatalogConfiguration()
        var files: [String: File] = [:], skills: [Skill] = []
        for source in sources {
            let label = source.path
            func fail(_ reason: String) -> SkillDefinitionError { .init(skill: label, reason: reason) }
            let segments = source.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !segments.isEmpty, segments.allSatisfy(Self.validSegment) else { throw fail("invalid skill path") }
            guard source.files.count <= Self.maximumFiles else { throw fail("more than \(Self.maximumFiles) files") }
            guard source.files.reduce(0, { $0 + $1.contents.count }) <= Self.maximumBytes else { throw fail("more than 16 MiB of files") }
            var seen = Set<String>(), listed: [String] = []
            for file in source.files {
                let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, parts.allSatisfy(Self.validSegment) else { throw fail("invalid file path '\(file.path)'") }
                guard seen.insert(file.path).inserted else { throw fail("duplicate file '\(file.path)'") }
                let uri = "skill://\(source.path)/\(file.path)"
                let digest = "sha256:" + SHA256.hash(data: file.contents).map { String(format: "%02x", $0) }.joined()
                if let existing = files[uri] {
                    guard existing.digest == digest, existing.mimeType == file.mimeType else { throw fail("'\(file.path)' differs from the same file of another skill") }
                } else {
                    files[uri] = File(uri: uri, name: parts.last!, mimeType: file.mimeType, bytes: file.contents, digest: digest)
                }
                listed.append(uri)
            }
            guard let manifest = source.files.first(where: { $0.path == "SKILL.md" }) else { throw fail("missing SKILL.md") }
            guard let markdown = String(validating: manifest.contents, as: UTF8.self) else { throw fail("SKILL.md is not UTF-8") }
            let frontmatter: FrontmatterValue
            do { frontmatter = try Frontmatter.parse(markdown) }
            catch { throw fail("SKILL.md line \(error.line): \(error.reason)") }
            guard let name = frontmatter["name"]?.string, Self.validName(name) else { throw fail("frontmatter 'name' must be 1-64 lowercase letters, digits and single hyphens") }
            guard name == segments.last else { throw fail("frontmatter name '\(name)' must equal the final path segment") }
            guard let description = frontmatter["description"]?.string, !description.isEmpty, description.count <= 1024 else {
                throw fail("frontmatter 'description' must be a non-empty string of at most 1024 characters")
            }
            if case .mapping(let metadata)? = frontmatter["metadata"], metadata.contains(where: { $0.key.hasPrefix("io.modelcontextprotocol/") }) {
                throw fail("metadata keys under 'io.modelcontextprotocol/' are reserved")
            }
            let uri = "skill://\(source.path)/SKILL.md"
            files[uri]?.description = description
            skills.append(Skill(uri: uri, path: source.path, frontmatter: frontmatter, files: listed))
        }
        // Completeness extends to nested skills: the enclosing skill lists their files too.
        for outer in skills {
            let ownFiles = Set(outer.files)
            for inner in skills where inner.path.hasPrefix(outer.path + "/") {
                guard Set(inner.files).isSubset(of: ownFiles) else {
                    throw SkillDefinitionError(skill: outer.path, reason: "does not include every file of nested skill '\(inner.path)'")
                }
            }
        }
        skills.sort { $0.uri.utf8.lexicographicallyPrecedes($1.uri.utf8) }
        var index: [String: Int] = [:]
        for (offset, skill) in skills.enumerated() {
            guard index[skill.uri] == nil else { throw SkillDefinitionError(skill: skill.path, reason: "duplicate skill") }
            index[skill.uri] = offset
        }
        // Every proper prefix of a file URI is a directory resource; children are direct only.
        var tree: [String: Set<String>] = [:], kinds: [String: Bool] = [:]
        for uri in files.keys {
            let path = uri.dropFirst("skill://".count).split(separator: "/").map(String.init)
            for depth in 1..<path.count {
                let parent = "skill://" + path[..<depth].joined(separator: "/")
                let child = "skill://" + path[...depth].joined(separator: "/")
                tree[parent, default: []].insert(child)
                kinds[child] = depth + 1 < path.count
            }
        }
        var directories: [String: [Child]] = [:]
        for (parent, children) in tree {
            directories[parent] = children.map { Child(uri: $0, name: String($0.split(separator: "/").last!), directory: kinds[$0] ?? false) }.sorted()
        }
        self.skills = skills; self.skillIndex = index; self.files = files; self.directories = directories
    }

    /// Loads every directory under `root` that contains a `SKILL.md` as a skill, nested ones
    /// included; each skill's files are all regular files below its directory. Hidden files
    /// and directories (`.name`) are skipped; symbolic links are rejected.
    ///
    /// - Parameters:
    ///   - root: The directory containing the skill directories to load.
    ///   - prefix: Optional organizational prefix, for example `acme/billing`.
    ///   - configuration: Optional catalog settings; nil selects the catalog defaults.
    /// - Returns: A validated catalog of the discovered skill directories and their files.
    public static func load(directory root: URL, prefix: String? = nil, configuration: SkillCatalogConfiguration? = nil) throws -> SkillCatalog {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var relativeFiles: [String] = []
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                                           options: [.skipsHiddenFiles]) else { throw CoreFailure.invalidInput }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count)).drop { $0 == "/" }
            if values.isSymbolicLink == true { throw SkillDefinitionError(skill: String(relative), reason: "symbolic links are not served") }
            if values.isRegularFile == true { relativeFiles.append(String(relative)) }
        }
        let roots = relativeFiles.filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }.map { String($0.dropLast("SKILL.md".count)).trimmingSuffix("/") }
        var sources: [SkillSource] = []
        for skillRoot in roots.sorted() {
            guard !skillRoot.isEmpty else { throw SkillDefinitionError(skill: base.lastPathComponent, reason: "SKILL.md at the root needs its own directory") }
            let members = relativeFiles.filter { $0.hasPrefix(skillRoot + "/") }
            let skillFiles = try members.map { path in
                SkillFile(path: String(path.dropFirst(skillRoot.count + 1)), contents: Array(try Data(contentsOf: base.appendingPathComponent(path))))
            }
            let path = [prefix, skillRoot].compactMap { $0 }.joined(separator: "/")
            sources.append(SkillSource(path: path, files: skillFiles))
        }
        return try SkillCatalog(sources, configuration: configuration)
    }

    // MARK: Validation rules

    /// Agent Skills names: 1-64 of `a-z`, `0-9` and `-`, no leading, trailing or double hyphen.
    static func validName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && !name.hasPrefix("-") && !name.hasSuffix("-") && !name.contains("--")
    }
    /// Unreserved URI characters only, so every segment is a valid `reg-name` and path segment.
    static func validSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".." && segment.utf8.count <= 255
            && segment.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0)) }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
