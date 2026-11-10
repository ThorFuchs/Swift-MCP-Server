// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting
import ExplorerDomain
import WikimediaAccess
@testable import ExplorerMCP

private actor NoNetworkLive: ExplorerProvider {
    nonisolated let profile = SourceProfile.wikipediaEnglish
    private(set) var count = 0
    func search(query: String, project: String, limit: Int) -> SearchPage {
        count += 1; return .init(candidates: [], truncated: false, provider: profile.provider, query: query)
    }
    func resolve(candidateID: String, project: String) throws -> CandidateResolution { throw profile.problem(.unknownCandidate) }
}
@Suite struct LiveCatalogTests {
    @Test func liveCatalogUsesRealProfileAndWrongProjectNeverEntersProvider() async throws {
        let provider = NoNetworkLive(), service = ExplorerService(provider: provider, limits: try ExplorerLimits())
        let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: Data(repeating: 7, count: 32), clock: { 0 })
        let h = try InProcessHarness(server: server)
        let bad = try await invoke(h, "search_articles", SearchInput(query: "x", project: "fixture-enwiki", limit: 1))
        #expect(bad.objectValue?["error"] != nil)
        #expect(await provider.count == 0)
        let value = try await invoke(h, "search_articles", SearchInput(query: "x", project: "enwiki", limit: 1))
        let page = try success(SearchPage.self, value)
        #expect(page.provider == "mediawiki-rest" && page.candidates.isEmpty)
        #expect(await provider.count == 1)
    }
}
