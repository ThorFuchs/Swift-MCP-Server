// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain
import WikimediaAccess

public protocol ResearchClient: Sendable {
    func search(_ input: SearchInput) async throws -> SearchPage
    func outline(_ input: OutlineInput) async throws -> Outline
    func section(_ input: SectionInput) async throws -> SectionPassage
    func references(_ input: ReferencesInput) async throws -> SectionReferences
}
extension ExplorerService: ResearchClient {}

/// Provider choice is an actual dependency, never an appearance preference.
public typealias ResearchSource = SourceProfile
public enum ResearchPhase: String, Sendable {
    case idle, searching, candidates, opening, outline, reading, references, section, empty, problem, cancelled
    case comparing, publishing
}

/// The predictable one-click offline journey: search → Observatory → its telescope section.
/// Every value must resolve in the shipped Riverglass collection; tests enforce this.
public enum OfflineTour {
    public static let query = "Riverglass"
    public static let candidateID = "fixture-observatory"
    public static let partID = "p2"
}

/// Offline-demo affordance that publishes the Riverglass collection's prepared edit, so an
/// upstream revision change can be demonstrated without a network. Live sources have none.
/// Publishing never touches an outline the user already holds; comparison stays explicit.
public struct OfflineRevisionEdit: Sendable {
    public let summary: String
    let publish: @Sendable () async -> Void
    public init(summary: String, publish: @escaping @Sendable () async -> Void) {
        self.summary = summary; self.publish = publish
    }
    public static func prepared(_ provider: FixtureProvider) -> OfflineRevisionEdit {
        .init(summary: "Riverglass Observatory r2 corrects the published mirror aperture.") { await provider.select(.r2) }
    }
}

/// Result of an explicit, user-initiated check of the pinned snapshot against the source's
/// current revision. The pinned outline, passage and references are never replaced by it.
public struct RevisionComparison: Sendable {
    public enum Passage: Sendable, Equatable {
        /// Same revision, or no section was selected when comparing.
        case notCompared
        case unchanged(String)
        case changed(pinned: String, latest: String)
        /// The selected part ID does not exist in the latest revision.
        case absentInLatest
    }
    public let pinned: SnapshotID
    public let latest: Outline
    public let partID: String?
    public let passage: Passage
    public var latestIsPinned: Bool { latest.snapshot == pinned }
}
