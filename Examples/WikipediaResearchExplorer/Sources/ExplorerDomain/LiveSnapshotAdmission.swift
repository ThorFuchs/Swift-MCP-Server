// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Rechecks all owned fields at the service boundary; a Sendable snapshot is
/// not a normalization permit. Counts retained content UTF8, not heap/RSS.
public enum LiveSnapshotAdmission {
    public static func validate(_ value: Snapshot, limits: ExplorerLimits) throws -> Snapshot {
        let p = value.provenance, id = p.identity
        guard SourceProfile.wikipediaEnglish.admits(id), decimal(id.pageID), decimal(id.revisionID),
              !p.synthetic, p.language == "en", p.title.utf8.count <= 512,
              p.sourceURL == "https://en.wikipedia.org/w/index.php?curid=\(id.pageID)&oldid=\(id.revisionID)",
              ISO8601DateFormatter().date(from: p.retrievedAt) != nil,
              p.modifiedAt.map({ ISO8601DateFormatter().date(from: $0) != nil }) ?? false,
              !p.license.isEmpty, value.tables == nil, value.tableCount == 0,
              !value.parts.isEmpty, value.parts.count <= limits.parts else { throw invalid() }
        var bytes = 0
        func charge(_ s: String, _ maximum: Int) throws {
            let n = s.utf8.count; guard n <= maximum, n <= 4_194_304 - bytes else { throw invalid() }; bytes += n
        }
        for s in [id.provider, id.project, id.pageID, id.revisionID, id.normalizerVersion, p.title, p.sourceURL, p.license, p.retrievedAt, p.modifiedAt ?? "", p.language ?? ""] { try charge(s, 2048) }
        var depths: [String: Int] = [:], associations = 0
        for part in value.parts {
            try Task.checkCancellation()
            guard Normalizer.component(part.id), depths[part.id] == nil, (1...limits.depth).contains(part.depth),
                  part.depth == (part.parentID.flatMap { depths[$0] }.map { $0 + 1 } ?? 1),
                  part.parentID == nil || depths[part.parentID!] != nil,
                  part.citations.count <= 64, part.citations.count <= 8192 - associations else { throw invalid() }
            depths[part.id] = part.depth; associations += part.citations.count
            try charge(part.id, 128); if let h = part.heading { try charge(h, 512) }; if let text = part.text { try charge(text, 4_194_304) }
            for ref in part.citations { guard Normalizer.component(ref) else { throw invalid() }; try charge(ref, 128) }
        }
        guard (value.references?.count ?? 0) <= 4096 else { throw invalid() }
        var ids = Set<String>()
        for ref in value.references ?? [] {
            guard !ref.synthetic, Normalizer.component(ref.id), ids.insert(ref.id).inserted else { throw invalid() }
            try charge(ref.id, 128); try charge(ref.title, 512)
            if let url = ref.url {
                guard let c = URLComponents(string: url), ["https", "http"].contains(c.scheme), c.host != nil, c.user == nil, c.password == nil else { throw invalid() }
                try charge(url, 2048)
            }
        }
        return .init(provenance: p, parts: value.parts, references: value.references, tables: nil, tableCount: 0, contentBytes: bytes)
    }
    public static func decimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func invalid() -> ExplorerProblem { SourceProfile.wikipediaEnglish.problem(.unsupportedVariant) }
}
