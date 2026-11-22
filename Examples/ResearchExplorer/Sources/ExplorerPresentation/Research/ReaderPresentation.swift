// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Every research state the reader distinguishes, derived deterministically from the controller.
/// Views render this; tests assert it. No state is inferred from text or timing.
public enum ResearchStatus: Equatable, Sendable {
    case idle
    case searching
    case noResults
    case candidates(count: Int, truncated: Bool)
    case opening
    /// An article is open; no section is selected yet.
    case outline
    case readingSection
    case loadingReferences
    case section(truncated: Bool)
    case comparing
    case publishingEdit
    case cancelled
    /// The pinned snapshot expired or was evicted; only an explicit new outline recovers.
    case expired
    case problem(ExplorerProblem.Code)

    public var isBusy: Bool { [.searching, .opening, .readingSection, .loadingReferences, .comparing, .publishingEdit].contains(self) }
}

/// The evidence for the selected section: what the reference projection actually says.
public enum EvidenceStatus: Equatable, Sendable {
    /// No section selected; nothing to show yet.
    case noSection
    case loading
    /// The provider supplied no reference metadata: never shown as an empty list.
    case metadataMissing
    /// Another reference failure (problem code), distinct from missing metadata.
    case unavailable(ExplorerProblem.Code)
    /// Reference metadata exists and this section cites nothing.
    case uncited
    /// Resolved references and citation identifiers without metadata.
    case cited(resolved: Int, unresolved: [String], truncated: Bool)
}

public struct OutlineRow: Equatable, Sendable, Identifiable {
    public var id: String { location.partID }
    public let location: PartLocation
    public let title: String
    /// 0 for top-level parts.
    public let indent: Int
    public let isSelected: Bool
    /// VoiceOver: heading, level and selection in words.
    public let accessibilityLabel: String
}

public struct ProvenanceLine: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String
}

/// Pure projection of `ResearchController` state for the 3-pane reader.
public struct ReaderPresentation: Equatable, Sendable {
    public let status: ResearchStatus
    public let evidence: EvidenceStatus
    public let outline: [OutlineRow]
    public let provenance: [ProvenanceLine]
    /// A live, verified-shape permalink to the exact revision; nil for fictional data.
    public let permalink: URL?
    public let canReadPrevious: Bool
    public let canReadNext: Bool

    public init(status: ResearchStatus, evidence: EvidenceStatus, outline: [OutlineRow], provenance: [ProvenanceLine],
                permalink: URL?, canReadPrevious: Bool, canReadNext: Bool) {
        self.status = status; self.evidence = evidence; self.outline = outline; self.provenance = provenance
        self.permalink = permalink; self.canReadPrevious = canReadPrevious; self.canReadNext = canReadNext
    }
}

extension ResearchController {
    public var presentation: ReaderPresentation {
        let rows = Self.rows(outline, selected: selectedPart)
        let index = selectedPart.flatMap { part in rows.firstIndex { $0.location == part } }
        return .init(status: status, evidence: evidence, outline: rows, provenance: Self.provenance(outline),
                     permalink: Self.permalink(outline), canReadPrevious: !isBusy && (index ?? 0) > 0 && index != nil,
                     canReadNext: !isBusy && !rows.isEmpty && (index.map { $0 < rows.count - 1 } ?? true))
    }

    var status: ResearchStatus {
        switch phase {
        case .idle: return .idle
        case .searching: return .searching
        case .empty: return .noResults
        case .candidates: return .candidates(count: page?.candidates.count ?? 0, truncated: page?.truncated ?? false)
        case .opening: return .opening
        case .outline: return .outline
        case .reading: return .readingSection
        case .references: return .loadingReferences
        case .section: return .section(truncated: passage?.truncated ?? false)
        case .comparing: return .comparing
        case .publishing: return .publishingEdit
        case .cancelled: return .cancelled
        case .problem:
            guard let code = problem?.code else { return .problem(.upstreamUnavailable) }
            return code == .absentSnapshot ? .expired : .problem(code)
        }
    }

    var evidence: EvidenceStatus {
        guard selectedPart != nil else { return .noSection }
        if phase == .reading || phase == .references { return .loading }
        if let code = referenceProblem?.code { return code == .missingReferences ? .metadataMissing : .unavailable(code) }
        guard let citations else { return phase == .problem ? .unavailable(problem?.code ?? .upstreamUnavailable) : .loading }
        if citations.references.isEmpty && citations.unresolvedIDs.isEmpty { return .uncited }
        return .cited(resolved: citations.references.count, unresolved: citations.unresolvedIDs, truncated: citations.truncated)
    }

    /// Reads the section before or after the selected one, in outline order. Without a selection,
    /// "next" opens the first section. Uses the ordinary `read` path (identity checks, supersession).
    public func readAdjacent(_ offset: Int) {
        guard !isBusy, let outline, offset == 1 || offset == -1 else { return }
        let parts = outline.sections.map(\.location)
        guard !parts.isEmpty else { return }
        let target: Int
        if let selectedPart, let index = parts.firstIndex(of: selectedPart) { target = index + offset }
        else { guard offset == 1 else { return }; target = 0 }
        guard parts.indices.contains(target) else { return }
        read(parts[target])
    }

    static func rows(_ outline: Outline?, selected: PartLocation?) -> [OutlineRow] {
        guard let outline else { return [] }
        return outline.sections.map { section in
            let title = section.heading.flatMap { $0.isEmpty ? nil : $0 } ?? (section.parentPartID == nil ? "Introduction" : "Untitled section")
            let indent = max(0, section.depth - 1)
            let isSelected = section.location == selected
            return OutlineRow(location: section.location, title: title, indent: indent, isSelected: isSelected,
                              accessibilityLabel: "\(title), section level \(indent + 1)\(isSelected ? ", selected" : "")")
        }
    }

    static func provenance(_ outline: Outline?) -> [ProvenanceLine] {
        guard let outline else { return [] }
        let p = outline.provenance, id = outline.snapshot
        var lines = [
            ProvenanceLine(label: "Source", value: p.synthetic ? "Offline demo · fictional teaching data" : "Wikipedia English · fetched snapshot"),
            ProvenanceLine(label: "Revision", value: id.revisionID + " (pinned)"),
        ]
        if let modified = p.modifiedAt { lines.append(.init(label: "Edited", value: modified)) }
        lines += [
            ProvenanceLine(label: "Retrieved", value: p.retrievedAt),
            ProvenanceLine(label: "Page", value: "\(id.project) / \(id.pageID)"),
            ProvenanceLine(label: "Normalizer", value: id.normalizerVersion),
            ProvenanceLine(label: "License", value: p.license),
            ProvenanceLine(label: "Citations", value: "Metadata only; not independently verified"),
        ]
        if outline.tableCount > 0 { lines.append(.init(label: "Omitted", value: "\(outline.tableCount) table\(outline.tableCount == 1 ? "" : "s"); plain-text projection")) }
        if outline.truncated { lines.append(.init(label: "Outline", value: outline.introductionTruncated ? "Introduction shortened" : "\(outline.totalSections - outline.sections.count) sections omitted")) }
        return lines
    }

    /// Only an https Wikipedia permalink naming this exact revision is offered as a link.
    static func permalink(_ outline: Outline?) -> URL? {
        guard let outline, !outline.provenance.synthetic,
              let components = URLComponents(string: outline.provenance.sourceURL),
              components.scheme == "https", components.host == "en.wikipedia.org",
              components.queryItems?.contains(where: { $0.name == "oldid" && $0.value == outline.snapshot.revisionID }) == true
        else { return nil }
        return components.url
    }
}
