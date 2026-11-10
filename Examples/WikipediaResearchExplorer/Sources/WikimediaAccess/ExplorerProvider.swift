// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Provider adapters return owned domain data. Public REST HTML has a separate
/// checked decoder and normalizer; the fixture format is never live wire data.
public protocol ExplorerProvider: Sendable {
    var profile: SourceProfile { get }
    func search(query: String, project: String, limit: Int) async throws -> SearchPage
    func resolve(candidateID: String, project: String) async throws -> CandidateResolution
}

extension ExplorerProvider { public var profile: SourceProfile { .offlineDemo } }

/// Finite live policy. WikipediaHTTPTransport and WikipediaProvider enforce
/// delivery, concurrency, attempts and deadline independently of UI settings.
public struct LiveAccessPolicy: Sendable {
    public let maximumDeliveredBytes = 4_194_304
    public let maximumConcurrentRequests = 2
    public let maximumAttempts = 2
    public let timeoutSeconds = 15
    public init() {}
}

/// Bounded provider receipt: the provider's owned candidate mapping binds the
/// selected ID to a page and a particular admitted revision. Not authorization.
public struct CandidateResolution: Sendable {
    public let provider: String
    public let candidate: Candidate
    public let revisionID: String
    public let normalizerVersion: String
    public enum Payload: Sendable { case fixture(ArticleSeed), live(Snapshot) }
    public let payload: Payload
    public init(provider: String, candidate: Candidate, revisionID: String,
                normalizerVersion: String, article: ArticleSeed) {
        self.provider = provider; self.candidate = candidate; self.revisionID = revisionID
        self.normalizerVersion = normalizerVersion; self.payload = .fixture(article)
    }
    public init(candidate: Candidate, liveSnapshot: Snapshot) {
        self.provider = "mediawiki-rest"; self.candidate = candidate
        self.revisionID = liveSnapshot.provenance.identity.revisionID
        self.normalizerVersion = "mediawiki-html-1"; self.payload = .live(liveSnapshot)
    }
}
