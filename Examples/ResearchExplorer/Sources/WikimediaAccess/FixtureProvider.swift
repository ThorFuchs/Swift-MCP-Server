// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import ExplorerDomain

/// Loads the owned fictional Riverglass collection once at startup, never inside a request budget.
/// No Wikimedia request or credential is used. Parsing uses public Swift-JSON.
///
/// The collection is published in *editions*: `r1` is the initial state, `r2` publishes the prepared
/// edit of the Observatory article. A page without a revision in the selected edition keeps its latest
/// earlier revision. Selecting an edition never rewrites an outline already returned: snapshots stay
/// pinned to their exact `SnapshotID` until they expire, exactly like a live upstream edit.
public actor FixtureProvider: ExplorerProvider {
    public enum Revision: String, Sendable, CaseIterable { case r1, r2 }
    public enum Fault: Sendable { case none, rateLimited, timedOut, unavailable }
    /// Fixed, owned file list; fixture content can never choose which resources are read.
    static let collection: [(pageID: String, revisions: [Revision])] = [
        ("observatory", [.r1, .r2]), ("expedition", [.r1]), ("instrument", [.r1]),
        ("observations", [.r1]), ("lanterns", [.r1]),
    ]
    /// Advertised only when a test asks for it, so shipped search results always resolve.
    public static let testOnlyNegativeCandidate = Candidate(id: "fixture-test-missing-seed", project: "fixture-enwiki",
        pageID: "test-missing-seed", title: "Riverglass test-only negative fixture",
        description: "Test-only: advertised without an article seed to exercise absent_page.")
    private struct SearchSeed: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let id, project, pageID, title: String
            let description: String?
            let keywords: [String]?
            enum CodingKeys: String, CodingKey { case id, project, pageID = "page_id", title, description, keywords }
        }
        let fixtureKind, query: String
        let candidates: [Item]
        let truncated: Bool
        enum CodingKeys: String, CodingKey {
            case fixtureKind = "fixture_kind", query, candidates, truncated
        }
    }
    private struct Entry: Sendable { let candidate: Candidate; let terms: [String] }
    private let entries: [Entry]
    private let articles: [String: [Revision: ArticleSeed]]
    private var revision: Revision
    private var fault: Fault
    private init(entries: [Entry], articles: [String: [Revision: ArticleSeed]], revision: Revision, fault: Fault) {
        self.entries = entries; self.articles = articles; self.revision = revision; self.fault = fault
    }
    public static func load(revision: Revision = .r1, fault: Fault = .none,
                            includeTestOnlyNegativeCandidate: Bool = false) throws -> FixtureProvider {
        let search: SearchSeed = try read("search.normalized")
        guard search.fixtureKind == "synthetic_normalized_example_not_upstream_payload",
              search.query == "Riverglass", !search.truncated,
              search.candidates.count <= 20 else { throw invalid() }
        let limits = try ExplorerLimits()
        var articles: [String: [Revision: ArticleSeed]] = [:]
        for (pageID, revisions) in collection {
            for r in revisions {
                let seed: ArticleSeed = try read("\(pageID)-\(r.rawValue).normalized")
                // Validate startup data once. These seeds are not claimed upstream data.
                _ = try Normalizer.normalize(seed, retrievedAt: Date(timeIntervalSince1970: 0), limits: limits)
                guard seed.pageID == pageID, seed.revisionID == r.rawValue else { throw invalid() }
                articles[pageID, default: [:]][r] = seed
            }
        }
        var seen = Set<String>(), pages = Set<String>()
        var entries = try search.candidates.map { c -> Entry in
            let keywords = c.keywords ?? []
            guard Normalizer.component(c.id), seen.insert(c.id).inserted, pages.insert(c.pageID).inserted,
                  c.project == "fixture-enwiki", Normalizer.component(c.pageID),
                  c.title.utf8.count <= 512, (c.description?.utf8.count ?? 0) <= 1024,
                  keywords.count <= 16, keywords.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
                  // Every advertised candidate must resolve, with the same title as its article.
                  let first = articles[c.pageID]?[.r1], first.title == c.title else { throw invalid() }
            return .init(candidate: .init(id: c.id, project: c.project, pageID: c.pageID, title: c.title, description: c.description),
                         terms: ([c.title] + keywords).map { $0.lowercased() })
        }
        // ...and every article must be reachable from search.
        guard pages == Set(articles.keys) else { throw invalid() }
        if includeTestOnlyNegativeCandidate {
            let c = testOnlyNegativeCandidate
            entries.append(.init(candidate: c, terms: [c.title.lowercased()]))
        }
        return .init(entries: entries, articles: articles, revision: revision, fault: fault)
    }
    /// Publishes a collection edition. Already returned outlines keep their pinned snapshot.
    public func select(_ revision: Revision) { self.revision = revision }
    public func edition() -> Revision { revision }
    public func setFault(_ fault: Fault) { self.fault = fault }
    public func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        try check()
        guard project == "fixture-enwiki", (1...20).contains(limit), query.utf8.count <= 256 else { throw Self.invalid() }
        let needle = query.lowercased()
        let matches = entries.filter { $0.candidate.project == project && $0.terms.contains { $0.contains(needle) } }.map(\.candidate)
        return .init(candidates: Array(matches.prefix(limit)), truncated: matches.count > limit, provider: Normalizer.provider, query: query)
    }
    public func resolve(candidateID: String, project: String) async throws -> CandidateResolution {
        try check()
        guard project == "fixture-enwiki", let candidate = entries.first(where: { $0.candidate.id == candidateID })?.candidate else {
            throw ExplorerProblem(.unknownCandidate, "Unknown fixture candidate.", recovery: "Search and use an exact returned candidate ID.")
        }
        // The page's latest revision published in the selected edition.
        let published = Revision.allCases.prefix(while: { $0 != revision }) + [revision]
        guard let revisions = articles[candidate.pageID],
              let seed = published.reversed().lazy.compactMap({ revisions[$0] }).first else {
            throw ExplorerProblem(.absentPage, "The selected candidate has no article seed.", recovery: "Choose another returned candidate; missing data is not an empty article.")
        }
        return .init(provider: Normalizer.provider, candidate: candidate, revisionID: seed.revisionID, normalizerVersion: seed.normalizerVersion, article: seed)
    }
    private func check() throws {
        try Task.checkCancellation()
        switch fault {
        case .none: return
        case .rateLimited: throw ExplorerProblem(.upstreamRateLimited, "Fixture rate-limit fault.", recovery: "Retry later; no automatic retry is performed in WRE1.")
        case .timedOut: throw ExplorerProblem(.upstreamTimedOut, "Fixture timeout fault.", recovery: "Retry explicitly; an empty result would hide the failure.")
        case .unavailable: throw ExplorerProblem(.upstreamUnavailable, "Fixture availability fault.", recovery: "Restore the provider before retrying.")
        }
    }
    private static func read<T: Decodable & Sendable>(_ name: String) throws -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else { throw invalid() }
        let handle = try FileHandle(forReadingFrom: url)
        // No size-then-unbounded-read race. An extra byte detects overflow.
        let data: Data
        do { data = try handle.read(upToCount: 4_194_305) ?? Data() }
        catch { try? handle.close(); throw error }
        try handle.close()
        guard data.count <= 4_194_304 else { throw invalid() }
        let parsed = try JSONParser(options: .init(limits: .balanced)).parseWithReport(Array(data)).result
        return try JSONValueDecoder(options: .init(limits: .balanced)).decodeWithReport(T.self, from: parsed).result
    }
    private static func invalid() -> ExplorerProblem {
        .init(.invalidFixture, "Invalid, oversized or missing normalized fixture.", recovery: "Restore the checked-in synthetic fixture resources.")
    }
}
