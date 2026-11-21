// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum SnapshotProjection {
    private static func subtree(_ snapshot: Snapshot, part: PartLocation) throws -> ArraySlice<NormalizedPart> {
        guard snapshot.provenance.identity == part.snapshot else {
            throw ExplorerProblem(.revisionMismatch, "The part locator belongs to another snapshot.", recovery: "Pass a locator returned by this exact outline, including revision and normalizer.")
        }
        guard let index = snapshot.parts.firstIndex(where: { $0.id == part.partID }) else {
            throw ExplorerProblem(.absentSection, "That part is absent from this revision.", recovery: "Fetch this snapshot's outline and choose a returned locator.")
        }
        let depth = snapshot.parts[index].depth
        var end = index + 1
        while end < snapshot.parts.count, snapshot.parts[end].depth > depth { try Task.checkCancellation(); end += 1 }
        return snapshot.parts[index..<end]
    }
    public static func outline(_ snapshot: Snapshot) throws -> Outline {
        try Task.checkCancellation()
        let identity = snapshot.provenance.identity
        let sections = snapshot.parts.prefix(128).map { p in
            OutlineSection(location: .init(snapshot: identity, partID: p.id), parentPartID: p.parentID, depth: p.depth, heading: p.heading)
        }
        let intro = try snapshot.parts.first?.text.map { try Normalizer.prefix($0, maximumBytes: 1024) }
        return .init(snapshot: identity, provenance: snapshot.provenance, introduction: intro?.text, sections: sections,
            totalSections: snapshot.parts.count, introductionTruncated: intro?.truncated ?? false, referenceCount: snapshot.references?.count,
            tableCount: snapshot.tableCount, truncated: (intro?.truncated ?? false) || snapshot.parts.count > sections.count)
    }
    public static func section(_ snapshot: Snapshot, part: PartLocation, maximumBytes: Int) throws -> SectionPassage {
        guard (1...32768).contains(maximumBytes) else {
            throw ExplorerProblem(.invalidArguments, "Invalid section text limit.", recovery: "Use 1–32768 UTF8 bytes.")
        }
        let parts = try subtree(snapshot, part: part)
        var output = "", included: [String] = [], truncated = false
        for p in parts {
            try Task.checkCancellation()
            guard let text = p.text else { continue }
            if included.count == 128 { truncated = true; break }
            let separator = output.isEmpty ? "" : "\n\n"
            let remaining = maximumBytes - output.utf8.count
            guard remaining >= separator.utf8.count else { truncated = true; break }
            let clipped = try Normalizer.prefix(text, maximumBytes: remaining - separator.utf8.count)
            if !clipped.text.isEmpty { output += separator + clipped.text; included.append(p.id) }
            if clipped.truncated { truncated = true; break }
        }
        return .init(snapshot: snapshot.provenance.identity, provenance: snapshot.provenance,
            selectedPartID: part.partID, includedPartIDs: included, text: output, textAvailable: parts.contains(where: { $0.text != nil }), truncated: truncated, continuationSupported: false)
    }
    public static func references(_ snapshot: Snapshot, part: PartLocation) throws -> SectionReferences {
        let parts = try subtree(snapshot, part: part)
        guard let source = snapshot.references else {
            throw ExplorerProblem(.missingReferences, "The provider did not supply reference metadata.", recovery: "Treat citations as unverified; do not infer an empty reference list.")
        }
        let lookup = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var associations: [CitationAssociation] = [], refs: [ReferenceEntry] = [], unresolved: [String] = []
        var seen = Set<String>(), missing = Set<String>(), truncated = false
        outer: for p in parts { for id in p.citations {
            try Task.checkCancellation()
            if associations.count == 64 { truncated = true; break outer }
            let r = lookup[id]
            if r != nil, !seen.contains(id), refs.count == 20 { truncated = true; break outer }
            associations.append(.init(partID: p.id, referenceID: id, resolved: r != nil))
            if let r, seen.insert(id).inserted { refs.append(.init(id: r.id, title: r.title, url: r.url, synthetic: r.synthetic)) }
            else if r == nil, missing.insert(id).inserted { unresolved.append(id) }
        } }
        return .init(snapshot: snapshot.provenance.identity, provenance: snapshot.provenance, references: refs,
            associations: associations, unresolvedIDs: unresolved, truncated: truncated, independentlyVerified: false)
    }
}
