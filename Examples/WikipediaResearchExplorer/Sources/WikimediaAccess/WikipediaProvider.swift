// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Two provider operations at most. No startup request, implicit cache refresh,
/// crawl, latest-page substitution or fixture fallback.
public actor WikipediaProvider: ExplorerProvider {
    public nonisolated let profile = SourceProfile.wikipediaEnglish
    private struct Mapping { let candidate: Candidate; let key: String; let expires: Date; let bytes: Int }
    private let transport: any LiveTransport
    private let normalizer = MediaWikiNormalizer()
    private let now: @Sendable () -> Date
    private var mappings: [String: Mapping] = [:]
    private var order: [String] = []
    private var bytes = 0, inFlight = 0
    public private(set) var lastRender: RenderEvidence?
    public init(transport: any LiveTransport = WikipediaHTTPTransport(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = clock
    }
    private func admit(_ project: String) throws -> ContinuousClock.Instant {
        guard project == profile.project else { throw profile.problem(.projectNotAllowed) }
        guard inFlight < 2 else { throw profile.problem(.budgetExceeded) }
        try Task.checkCancellation(); inFlight += 1
        return ContinuousClock.now.advanced(by: .seconds(15))
    }
    public func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        let url = try WikipediaRoute.search(query, limit: limit), deadline = try admit(project)
        defer { inFlight -= 1 }
        do {
            let response = try await response(url, deadline: deadline)
            let decoded = try RESTCodec.decode(RESTSearch.self, response.body)
            guard decoded.pages.count <= limit else { throw LiveFailure.malformed }
            var candidates: [Candidate] = [], pageIDs = Set<Int64>()
            var pending: [(String, Mapping)] = []
            for page in decoded.pages {
                guard page.id > 0, pageIDs.insert(page.id).inserted, !page.key.isEmpty, page.key.utf8.count <= 1024,
                      !page.title.isEmpty, page.title.utf8.count <= 512, (page.description?.utf8.count ?? 0) <= 1024 else { throw LiveFailure.malformed }
                _ = try WikipediaRoute.page(page.key)
                let id = "c_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let candidate = Candidate(id: id, project: "enwiki", pageID: String(page.id), title: page.title, description: page.description)
                let size = id.utf8.count + page.key.utf8.count + page.title.utf8.count + (page.description?.utf8.count ?? 0) + 256
                candidates.append(candidate); pending.append((id, .init(candidate: candidate, key: page.key, expires: now().addingTimeInterval(300), bytes: size)))
            }
            try finish(deadline)
            expire()
            for (id, mapping) in pending {
                while mappings.count >= 128 || mapping.bytes > 1_048_576 - bytes { evictFirst() }
                mappings[id] = mapping; order.append(id); bytes += mapping.bytes
            }
            return .init(candidates: candidates, truncated: candidates.count == limit, provider: profile.provider, query: query)
        } catch { throw sanitized(error) }
    }
    public func resolve(candidateID: String, project: String) async throws -> CandidateResolution {
        let deadline = try admit(project); defer { inFlight -= 1 }
        expire()
        guard let mapping = mappings[candidateID] else { throw profile.problem(.unknownCandidate) }
        do {
            let response = try await response(WikipediaRoute.page(mapping.key), deadline: deadline)
            let page = try RESTCodec.decode(RESTPage.self, response.body)
            guard String(page.id) == mapping.candidate.pageID, page.key == mapping.key else { throw LiveFailure.identity }
            let (snapshot, evidence) = try await normalizer.normalize(page, retrievedAt: now(), limits: ExplorerLimits())
            try finish(deadline)
            guard let stillCurrent = mappings[candidateID], stillCurrent.expires > now(), stillCurrent.key == mapping.key else { throw profile.problem(.unknownCandidate) }
            lastRender = evidence
            return CandidateResolution(candidate: mapping.candidate, liveSnapshot: snapshot)
        } catch { throw sanitized(error) }
    }
    private func response(_ url: URL, deadline: ContinuousClock.Instant) async throws -> LiveHTTPResponse {
        for attempt in 0..<2 {
            try finish(deadline)
            let value = try await transport.get(url, deadline: deadline)
            try finish(deadline)
            guard value.body.count <= 4_194_304 else { throw LiveFailure.bodyLimit }
            if value.status == 200 {
                guard value.headers["Content-Type"]?.lowercased().split(separator: ";").first == "application/json" else { throw LiveFailure.malformed }
                return value
            }
            if value.status == 404 { throw profile.problem(.absentPage) }
            if value.status == 429 || value.status == 503 {
                if attempt == 0, let value = value.headers["Retry-After"], let seconds = Self.retryDelay(value, now: now()), (0...2).contains(seconds),
                   ContinuousClock.now.advanced(by: .seconds(seconds)) < deadline {
                    try await Task.sleep(for: .seconds(seconds)); continue
                }
                throw profile.problem(value.status == 429 ? .upstreamRateLimited : .upstreamUnavailable)
            }
            throw profile.problem(.upstreamUnavailable)
        }
        throw profile.problem(.upstreamUnavailable)
    }
    static func retryDelay(_ value: String, now: Date) -> Int? {
        if let number = Int(value), (0...2).contains(number) { return number }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard value.utf8.count <= 128, let date = formatter.date(from: value) else { return nil }
        let remaining = date.timeIntervalSince(now)
        guard remaining >= 0, remaining <= 2 else { return nil }; return Int(remaining.rounded(.up))
    }
    private func finish(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw profile.problem(.upstreamTimedOut) }
    }
    private func expire() {
        let expired = Set(order.filter { mappings[$0].map { $0.expires <= now() } ?? true })
        for id in expired { if let removed = mappings.removeValue(forKey: id) { bytes -= removed.bytes } }
        order.removeAll(where: { expired.contains($0) })
    }
    private func evictFirst() {
        guard !order.isEmpty else { return }
        if let removed = mappings.removeValue(forKey: order.removeFirst()) { bytes -= removed.bytes }
    }
    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let problem = error as? ExplorerProblem { return profile.problem(problem.code) }
        if let url = error as? URLError, url.code == .timedOut { return profile.problem(.upstreamTimedOut) }
        if let failure = error as? LiveFailure {
            return profile.problem(failure == .bodyLimit ? .budgetExceeded : failure == .identity ? .unknownCandidate : .unsupportedVariant)
        }
        return profile.problem(.upstreamUnavailable)
    }
}
