// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Identity and admission policy, independent of the UI's appearance settings.
public enum SourceProfile: String, Sendable, CaseIterable, Codable {
    case offlineDemo = "Offline demo", wikipediaEnglish = "Wikipedia English"
    public var project: String { self == .offlineDemo ? "fixture-enwiki" : "enwiki" }
    public var provider: String { self == .offlineDemo ? "synthetic-fixture" : "mediawiki-rest" }
    public var normalizer: String { self == .offlineDemo ? "fixture-1" : "mediawiki-html-1" }
    public var synthetic: Bool { self == .offlineDemo }
    public func admits(_ id: SnapshotID) -> Bool {
        id.project == project && id.provider == provider && id.normalizerVersion == normalizer
            && Normalizer.component(id.pageID) && Normalizer.component(id.revisionID)
    }
    public func problem(_ code: ExplorerProblem.Code) -> ExplorerProblem {
        guard self == .wikipediaEnglish else { return PublicProblems.project(code) }
        switch code {
        case .projectNotAllowed: return .init(code, "Project is not enabled.", recovery: "Use enwiki with Wikipedia English.")
        case .absentPage: return .init(code, "Wikipedia page is absent.", recovery: "Search again and choose a current returned candidate.")
        case .unsupportedVariant, .invalidFixture: return .init(code, "Wikipedia response is outside the supported plain-text contract.", recovery: "Preserve the failed operation; no fictional content was substituted.")
        default: return PublicProblems.project(code)
        }
    }
}
