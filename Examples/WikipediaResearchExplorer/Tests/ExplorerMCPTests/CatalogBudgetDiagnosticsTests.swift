// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP

private actor BudgetProbeProvider: ExplorerProvider {
    nonisolated let profile = SourceProfile.wikipediaEnglish
    func search(query: String, project: String, limit: Int) -> SearchPage {
        .init(candidates: [], truncated: false, provider: profile.provider, query: query)
    }
    func resolve(candidateID: String, project: String) throws -> CandidateResolution { throw profile.problem(.unknownCandidate) }
}
@Suite struct CatalogBudgetDiagnosticsTests {
    @Test func validLiveSearchProducesResult() async throws {
        let service = ExplorerService(provider: BudgetProbeProvider(), limits: try ExplorerLimits())
        let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: Data(repeating: 7, count: 32), clock: { 0 })
        let h = try InProcessHarness(server: server)
        let value = try await invoke(h, "search_articles", SearchInput(query: "x", project: "enwiki", limit: 1))
        if value.objectValue?["result"] == nil {
            let bytes = try WireCodec.write(value, limits: .balanced).result
            print("Catalog budget diagnostic response: \(String(decoding: bytes, as: UTF8.self))")
        }
        _ = try success(SearchPage.self, value)
    }
}
