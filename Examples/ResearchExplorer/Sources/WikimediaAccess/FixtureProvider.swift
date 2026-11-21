// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import ExplorerDomain

/// Loads three capped, owned seeds at startup, never inside a request budget.
/// No Wikimedia request or credential is used. Parsing uses public Swift-JSON.
public actor FixtureProvider: ExplorerProvider {
    public enum Revision: String, Sendable { case r1, r2 }
    public enum Fault: Sendable { case none, rateLimited, timedOut, unavailable }
    private struct SearchSeed: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let id, project, pageID, title: String
            let description: String?
            enum CodingKeys: String, CodingKey { case id, project, pageID = "page_id", title, description }
        }
        let fixtureKind, query: String
        let candidates: [Item]
        let truncated: Bool
        enum CodingKeys: String, CodingKey {
            case fixtureKind = "fixture_kind", query, candidates, truncated
        }
    }
    private let candidates: [Candidate]
    private let articles: [Revision: ArticleSeed]
    private var revision: Revision
    private var fault: Fault
    private init(candidates: [Candidate], articles: [Revision: ArticleSeed], revision: Revision, fault: Fault) {
        self.candidates = candidates; self.articles = articles; self.revision = revision; self.fault = fault
    }
    public static func load(revision: Revision = .r1, fault: Fault = .none) throws -> FixtureProvider {
        let search: SearchSeed = try read("search.normalized")
        guard search.fixtureKind == "synthetic_normalized_example_not_upstream_payload",
              search.query == "Riverglass", !search.truncated,
              search.candidates.count <= 20 else { throw invalid() }
        var seen = Set<String>()
        let candidates = try search.candidates.map { c -> Candidate in
            guard Normalizer.component(c.id), seen.insert(c.id).inserted,
                  c.project == "fixture-enwiki", Normalizer.component(c.pageID),
                  c.title.utf8.count <= 512, (c.description?.utf8.count ?? 0) <= 1024 else { throw invalid() }
            return .init(id: c.id, project: c.project, pageID: c.pageID, title: c.title, description: c.description)
        }
        let r1: ArticleSeed = try read("observatory-r1.normalized")
        let r2: ArticleSeed = try read("observatory-r2.normalized")
        let limits = try ExplorerLimits()
        // Validate startup data once. These seeds are not claimed upstream data.
        for seed in [r1, r2] { _ = try Normalizer.normalize(seed, retrievedAt: Date(timeIntervalSince1970: 0), limits: limits) }
        guard r1.revisionID == "r1", r2.revisionID == "r2", r1.pageID == "observatory", r2.pageID == "observatory" else { throw invalid() }
        return .init(candidates: candidates, articles: [.r1: r1, .r2: r2], revision: revision, fault: fault)
    }
    public func select(_ revision: Revision) { self.revision = revision }
    public func setFault(_ fault: Fault) { self.fault = fault }
    public func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        try check()
        guard project == "fixture-enwiki", (1...20).contains(limit), query.utf8.count <= 256 else { throw Self.invalid() }
        let needle = query.lowercased()
        let matches = candidates.filter { $0.project == project && $0.title.lowercased().contains(needle) }
        return .init(candidates: Array(matches.prefix(limit)), truncated: matches.count > limit, provider: Normalizer.provider, query: query)
    }
    public func resolve(candidateID: String, project: String) async throws -> CandidateResolution {
        try check()
        guard project == "fixture-enwiki", let candidate = candidates.first(where: { $0.id == candidateID }) else {
            throw ExplorerProblem(.unknownCandidate, "Unknown fixture candidate.", recovery: "Search and use an exact returned candidate ID.")
        }
        guard candidate.pageID == "observatory", let seed = articles[revision] else {
            throw ExplorerProblem(.absentPage, "The selected candidate has no article seed.", recovery: "Choose fixture-observatory; missing data is not an empty article.")
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
