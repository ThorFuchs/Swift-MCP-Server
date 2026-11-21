// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum Normalizer {
    public static let provider = "synthetic-fixture"
    public static func component(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public static func normalize(_ seed: ArticleSeed, retrievedAt: Date, limits: ExplorerLimits) throws -> Snapshot {
        try Task.checkCancellation()
        guard retrievedAt.timeIntervalSince1970.isFinite else { throw structuralLimit() }
        guard seed.fixtureKind == "synthetic_normalized_example_not_upstream_payload",
              seed.formatVersion == "wre-fixture-1", seed.normalizerVersion == "fixture-1",
              seed.project == "fixture-enwiki", component(seed.pageID), component(seed.revisionID),
              seed.sourceURL == "fixture://riverglass/\(seed.pageID)/\(seed.revisionID)" else {
            throw ExplorerProblem(.invalidFixture, "Fixture identity or format is unsupported.", recovery: "Load an owned normalized wre-fixture-1 seed.")
        }
        var bytes = 0
        func charge(_ text: String, maximum: Int) throws {
            let n = text.utf8.count
            guard n <= maximum, n <= 4194304 - bytes else {
                throw ExplorerProblem(.budgetExceeded, "Normalized content exceeds its byte limit.", recovery: "Supply a smaller article; do not raise the default profile.")
            }
            bytes += n
        }
        for s in [seed.title, seed.license, seed.sourceURL, provider, seed.project, seed.pageID, seed.revisionID, seed.normalizerVersion] { try charge(s, maximum: 2048) }
        if let modified = seed.modifiedAt { try charge(modified, maximum: 128) }
        guard seed.parts.count <= limits.parts else { throw structuralLimit() }
        var stack: [(PartSeed, String?, Int)] = seed.parts.reversed().map { ($0, nil, 1) }
        var result: [NormalizedPart] = [], ids = Set<String>(), associations = 0
        while let (part, parent, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard result.count < limits.parts, depth <= limits.depth,
                  component(part.id), ids.insert(part.id).inserted else { throw structuralLimit() }
            guard part.kind == nil || part.kind == "section" || part.kind == "paragraph" else {
                throw ExplorerProblem(.unsupportedVariant, "The normalized part kind is unsupported.", recovery: "Preserve the original input and extend the owned format explicitly.")
            }
            try charge(part.id, maximum: 128)
            if let h = part.heading { try charge(h, maximum: 512) }
            if let t = part.text { try charge(t, maximum: 4194304) }
            let citations = part.citations ?? []
            guard citations.count <= 64, citations.count <= 8192 - associations else { throw structuralLimit() }
            associations += citations.count
            for c in citations { guard component(c) else { throw structuralLimit() }; try charge(c, maximum: 128) }
            result.append(.init(id: part.id, parentID: parent, depth: depth, heading: part.heading, text: part.text, citations: citations))
            let children = part.parts ?? []
            guard children.count <= limits.parts - result.count - stack.count else { throw structuralLimit() }
            for child in children.reversed() { stack.append((child, part.id, depth + 1)) }
        }
        var refIDs = Set<String>()
        guard (seed.references?.count ?? 0) <= 4096, (seed.tables?.count ?? 0) <= 128 else { throw structuralLimit() }
        for r in seed.references ?? [] {
            try Task.checkCancellation()
            guard component(r.id), refIDs.insert(r.id).inserted, r.synthetic,
                  r.url == nil || r.url!.hasPrefix("fixture://") else { throw structuralLimit() }
            try charge(r.id, maximum: 128); try charge(r.title, maximum: 512)
            if let url = r.url { try charge(url, maximum: 2048) }
        }
        var tableIDs = Set<String>()
        for t in seed.tables ?? [] {
            try Task.checkCancellation()
            guard component(t.id), tableIDs.insert(t.id).inserted, t.columns.count <= 32, t.rows.count <= 256,
                  t.rows.allSatisfy({ $0.count == t.columns.count }) else { throw structuralLimit() }
            try charge(t.id, maximum: 128); try charge(t.caption, maximum: 512)
            for column in t.columns { try charge(column, maximum: 256) }
            for row in t.rows { for cell in row {
                switch cell { case .text(let value): try charge(value, maximum: 1024)
                case .integer(let value): try charge(String(value), maximum: 21) }
            } }
        }
        let identity = SnapshotID(provider: provider, project: seed.project, pageID: seed.pageID, revisionID: seed.revisionID, normalizerVersion: seed.normalizerVersion)
        let date = ISO8601DateFormatter().string(from: retrievedAt)
        try charge(date, maximum: 128)
        // Counts retained source-content UTF8 bytes, NOT Swift allocation/RSS.
        return .init(provenance: .init(identity: identity, title: seed.title, sourceURL: seed.sourceURL,
            retrievedAt: date, modifiedAt: seed.modifiedAt, language: nil, license: seed.license, synthetic: true),
            parts: result, references: seed.references, tables: seed.tables, tableCount: seed.tables?.count ?? 0, contentBytes: bytes)
    }
    private static func structuralLimit() -> ExplorerProblem {
        .init(.budgetExceeded, "Depth, parts, associations, identifiers or table structure exceed the normalized contract.", recovery: "Use a bounded supported fixture with unique part/reference IDs.")
    }
    public static func prefix(_ text: String, maximumBytes: Int) throws -> (text: String, truncated: Bool) {
        guard maximumBytes >= 0 else { throw structuralLimit() }
        var output = "", bytes = 0, visited = 0
        for scalar in text.unicodeScalars {
            if visited % 256 == 0 { try Task.checkCancellation() }; visited += 1
            let v = scalar.value, n = v <= 0x7F ? 1 : v <= 0x7FF ? 2 : v <= 0xFFFF ? 3 : 4
            if n > maximumBytes - bytes { return (output, true) }
            output.unicodeScalars.append(scalar); bytes += n
        }
        return (output, false)
    }
}
