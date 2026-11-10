// SPDX-License-Identifier: Apache-2.0
// WRE1 public-consumer test SOURCE; no Swift invocation occurred in WRE1.
import Foundation
import JSON
import Testing
import MCPProtocol
import MCPServer
import MCPServerTesting
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP

func json(_ value: String) throws -> JSON { try WireCodec.parse(Array(value.utf8), limits: .balanced).result }
func harness() async throws -> (InProcessHarness, FixtureProvider) {
    let provider = try FixtureProvider.load()
    let service = ExplorerService(provider: provider, limits: try ExplorerLimits(), clock: { Date(timeIntervalSince1970: 0) })
    let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: Data(repeating: 7, count: 32), clock: { 0 })
    return (try InProcessHarness(server: server, maximumExchanges: 16, maximumRecordedBytes: 1_048_576), provider)
}
private struct Call<Arguments: Encodable & Sendable>: Encodable {
    let jsonrpc = "2.0", id = 1, method = "tools/call"
    let params: Parameters
    struct Parameters: Encodable {
        let _meta: [String: JSON]
        let name: String
        let arguments: Arguments
    }
}
func invoke<A: Encodable & Sendable>(_ h: InProcessHarness, _ name: String, _ args: A) async throws -> JSON {
    let meta: [String: JSON] = [ProtocolMetadata.protocolVersion: .string("2026-07-28"), ProtocolMetadata.clientCapabilities: try json("{}")]
    let call = Call<A>(params: .init(_meta: meta, name: name, arguments: args))
    let value = try JSONValueEncoder(options: .init(limits: .balanced)).encodeWithReport(call).result
    let bytes = try WireCodec.write(value, limits: .balanced).result
    let principal = VerifiedPrincipal(subject: ScalarText("fixture"), issuer: ScalarText("test"), resource: ScalarText("wre"), scopes: [])
    let response = try #require(await h.exchange(bytes, principal: principal, origin: ScalarText("wre-source-test")))
    #expect(response.count <= 131_072)
    return try WireCodec.parse(Array(response), limits: .balanced).result
}
func success<Value: Decodable & Sendable>(_ type: Value.Type, _ response: JSON) throws -> Value {
    let result = try #require(response.objectValue?["result"])
    #expect(result.objectValue?["isError"]?.booleanValue == false)
    #expect(result.objectValue?["content"]?.arrayValue?.first?.objectValue?["type"]?.stringValue == "text")
    let structured = try #require(result.objectValue?["structuredContent"]?.objectValue)
    #expect(structured["status"]?.stringValue == "ok")
    return try JSONValueDecoder(options: .init(limits: .balanced)).decodeWithReport(type, from: #require(structured["value"])).result
}
struct PublicConsumerTests {
    @Test func fourToolJourneyUsesRealDispatcherAndValidatedStructuredResults() async throws {
        let (h, _) = try await harness()
        let search = try success(SearchPage.self, await invoke(h, "search_articles", SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: 10)))
        #expect(search.candidates.map(\.id) == ["fixture-observatory", "fixture-expedition"])
        let outline = try success(Outline.self, await invoke(h, "get_article_outline", OutlineInput(project: "fixture-enwiki", candidateID: "fixture-observatory")))
        let part = try #require(outline.sections.first(where: { $0.location.partID == "p2" })?.location)
        let passage = try success(SectionPassage.self, await invoke(h, "read_article_section", SectionInput(snapshot: outline.snapshot, part: part, maxTextBytes: 32768)))
        #expect(passage.text.contains("2-metre") && passage.text.contains("α — π"))
        let refs = try success(SectionReferences.self, await invoke(h, "get_section_references", ReferencesInput(snapshot: outline.snapshot, part: part)))
        #expect(refs.references.map(\.id) == ["ref-1"] && refs.unresolvedIDs == ["ref-unresolved"])
        #expect(!refs.independentlyVerified)
        let state = await h.server.activity
        #expect(state.active == 0 && state.requests == 0 && state.leases == 0 && state.bufferedBytes == 0)
    }
    @Test func inputSchemaRejectsUnknownFieldAndLimitBeforeProvider() async throws {
        struct Extra: Encodable, Sendable { let query = "Riverglass", project = "fixture-enwiki", limit = 10, injected = true }
        let (h, p) = try await harness(); await p.setFault(.unavailable)
        let response = try await invoke(h, "search_articles", Extra())
        #expect(try response.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
    }
    @Test func escapedTextCannotExceedSerializedResponseCap() async throws {
        struct QuotedProvider: ExplorerProvider {
            let seed: ArticleSeed
            func search(query: String, project: String, limit: Int) async throws -> SearchPage {
                .init(candidates: [], truncated: false, provider: Normalizer.provider, query: query)
            }
            func resolve(candidateID: String, project: String) async throws -> CandidateResolution {
                .init(provider: Normalizer.provider, candidate: .init(id: candidateID, project: project, pageID: seed.pageID, title: seed.title, description: nil), revisionID: seed.revisionID, normalizerVersion: seed.normalizerVersion, article: seed)
            }
        }
        // 32768 control characters expand to 196608 escaped JSON bytes.
        let text = String(repeating: "\u{0001}", count: 32768)
        let encodedText = try JSONValueEncoder(options: .init(limits: .balanced)).encodeWithReport(text).result
        let textJSON = String(decoding: try WireCodec.write(encodedText, limits: .balanced).result, as: UTF8.self)
        let raw = #"{"fixture_kind":"synthetic_normalized_example_not_upstream_payload","format_version":"wre-fixture-1","project":"fixture-enwiki","page_id":"observatory","revision_id":"r1","title":"Synthetic","source_url":"fixture://riverglass/observatory/r1","normalizer_version":"fixture-1","license":"Apache-2.0 synthetic","parts":[{"id":"p","text":\#(textJSON)}],"references":[]}"#
        let seed = try JSONValueDecoder(options: .init(limits: .balanced)).decodeWithReport(ArticleSeed.self, from: json(raw)).result
        let service = ExplorerService(provider: QuotedProvider(seed: seed), limits: try ExplorerLimits())
        let outline = try await service.outline(.init(project: "fixture-enwiki", candidateID: "quoted"))
        let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: Data(repeating: 9, count: 32), clock: { 0 })
        let h = try InProcessHarness(server: server)
        let part = try #require(outline.sections.first?.location)
        let response = try await invoke(h, "read_article_section", SectionInput(snapshot: outline.snapshot, part: part, maxTextBytes: 32768))
        #expect(response.objectValue?["result"]?.objectValue?["isError"]?.booleanValue == true)
        #expect(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["problem"]?.objectValue?["code"]?.stringValue == "budget_exceeded")
    }

    @Test func operationalProviderFailureIsStructuredToolErrorNotEmptySearch() async throws {
        let (h, p) = try await harness(); await p.setFault(.rateLimited)
        let response = try await invoke(h, "search_articles", SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: nil))
        let result = try #require(response.objectValue?["result"]?.objectValue)
        #expect(result["isError"]?.booleanValue == true)
        #expect(result["structuredContent"]?.objectValue?["problem"]?.objectValue?["code"]?.stringValue == "upstream_rate_limited")
        #expect(result["structuredContent"]?.objectValue?["value"] == nil)
    }
}
