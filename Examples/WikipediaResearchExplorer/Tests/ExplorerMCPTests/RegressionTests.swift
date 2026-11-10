// SPDX-License-Identifier: Apache-2.0
// Source-only WRE2 regressions; Swift Testing NOT_RUN.
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting
@testable import ExplorerMCP
@testable import ExplorerDomain
import WikimediaAccess

private actor FaultProvider: ExplorerProvider {
    enum Mode: Sendable { case problem, unknown, budget, json, healthy, cancelled, deadline }
    struct Unknown: Error { let privatePayload = "PRIVATE_SENTINEL do-not-echo" }
    var mode: Mode
    private(set) var calls = 0
    init(_ mode: Mode) { self.mode = mode }
    func set(_ mode: Mode) { self.mode = mode }
    func search(query: String, project: String, limit: Int) async throws -> SearchPage {
        calls += 1
        switch mode {
        case .problem: throw ExplorerProblem(.upstreamRateLimited, String(repeating: "PRIVATE_SENTINEL\u{0001}", count: 10000), recovery: "secret://PRIVATE_SENTINEL")
        case .unknown: throw Unknown()
        case .budget: throw RequestBudget.Failure.exhausted
        case .json: throw JSONFailure(.resource, code: .limitExceeded)
        case .cancelled: throw CancellationError()
        case .deadline: throw CoreFailure.deadline
        case .healthy: return .init(candidates: [], truncated: false, provider: Normalizer.provider, query: query)
        }
    }
    func resolve(candidateID: String, project: String) async throws -> CandidateResolution { throw Unknown() }
}
private func faultHarness(_ p: FaultProvider, ceiling: Int = 131072) async throws -> InProcessHarness {
    let service = ExplorerService(provider: p, limits: try ExplorerLimits())
    let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: Data(repeating: 8, count: 32), clock: { 0 }, responseBytes: ceiling)
    return try InProcessHarness(server: server)
}
private func errorCode(_ response: JSON) throws -> Int? {
    try response.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced)
}
private func passage(_ text: String) -> SectionPassage {
    let id = SnapshotID(provider: "synthetic-fixture", project: "fixture-enwiki", pageID: "observatory", revisionID: "r1", normalizerVersion: "fixture-1")
    return .init(snapshot: id, provenance: .init(identity: id, title: "Synthetic", sourceURL: "fixture://riverglass/observatory/r1", retrievedAt: "1970-01-01T00:00:00Z", modifiedAt: nil, language: nil, license: "Apache-2.0 synthetic", synthetic: true), selectedPartID: "p", includedPartIDs: ["p"], text: text, textAvailable: true, truncated: false, continuationSupported: false)
}
struct RegressionTests {
    @Test func independentUnknownFieldAxis_T10() async throws {
        struct Extra: Encodable, Sendable { let query = "Riverglass", project = "fixture-enwiki", limit = 10, extra = true }
        let p = FaultProvider(.unknown), h = try await faultHarness(p)
        #expect(try errorCode(await invoke(h, "search_articles", Extra())) == -32602)
        #expect(await p.calls == 0)
    }
    @Test func independentLimitAndTypeAxes_T11() async throws {
        struct TooMany: Encodable, Sendable { let query = "Riverglass", project = "fixture-enwiki", limit = 21 }
        struct WrongType: Encodable, Sendable { let query = "Riverglass", project = "fixture-enwiki", limit = "10" }
        let p = FaultProvider(.unknown), h = try await faultHarness(p)
        #expect(try errorCode(await invoke(h, "search_articles", TooMany())) == -32602)
        #expect(try errorCode(await invoke(h, "search_articles", WrongType())) == -32602)
        #expect(await p.calls == 0)
        await p.set(.healthy)
        let page = try success(SearchPage.self, await invoke(h, "search_articles", SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: 10)))
        #expect(page.candidates.isEmpty && !page.truncated)
    }
    @Test func controlCharactersDeniedByPreflightBeforeSerialization_T12() {
        let value = passage(String(repeating: "\u{0001}", count: 32768))
        let bound = ToolAdmission.measure(value, problem: nil, summary: "synthetic", ceiling: 98304)
        #expect(!bound.admitted && bound.upper <= 98304)
        #expect(bound.visitedWork < 1_048_576)
        // Existing escapedTextCannotExceedSerializedResponseCap separately
        // asserts the exact budget_exceeded result through the real dispatcher.
    }
    @Test func quotesBackslashesUnicodeAndLoweredCaps_T13() throws {
        struct Outcome: Encodable { let status = "ok"; let value: SectionPassage }
        struct Text: Encodable { let type = "text"; let text = "synthetic" }
        struct Envelope: Encodable { let resultType = "complete"; let content = [Text()]; let structuredContent: Outcome; let isError = false }
        for text in ["a\"b\\c", "α — π", String(repeating: "x", count: 4000)] {
            let value = passage(text)
            let estimate = ToolAdmission.measure(value, problem: nil, summary: "synthetic", ceiling: 4096)
            if text.utf8.count < 32 {
                #expect(estimate.admitted)
                let encoded = try JSONValueEncoder(options: .init(limits: .balanced)).encodeWithReport(Envelope(structuredContent: .init(value: value))).result
                var limits = JSONLimits.balanced; limits[.outputBytes] = 4096
                let actual = try WireCodec.write(encoded, limits: limits).result
                #expect(actual.count <= estimate.upper && actual.count <= 4096)
            } else { #expect(!estimate.admitted) }
        }
    }
    @Test func headingsProvenanceAndReferencesCannotBypassAdmission_T14() {
        let value = passage("short"), id = value.snapshot
        let provenance = Provenance(identity: id, title: String(repeating: "q", count: 2048), sourceURL: value.provenance.sourceURL, retrievedAt: value.provenance.retrievedAt, modifiedAt: nil, language: nil, license: String(repeating: "x", count: 2048), synthetic: true)
        let rows = (0..<128).map { OutlineSection(location: .init(snapshot: id, partID: "p\($0)"), parentPartID: nil, depth: 1, heading: String(repeating: "h", count: 512)) }
        let outline = Outline(snapshot: id, provenance: provenance, introduction: "short", sections: rows, totalSections: 128, introductionTruncated: false, referenceCount: 20, tableCount: 0, truncated: false)
        #expect(!ToolAdmission.measure(outline, problem: nil, summary: "synthetic", ceiling: 98304).admitted)
        let refs = (0..<20).map { ReferenceEntry(id: "r\($0)", title: String(repeating: "r", count: 512), url: String(repeating: "u", count: 2048), synthetic: true) }
        let references = SectionReferences(snapshot: id, provenance: value.provenance, references: refs, associations: [], unresolvedIDs: [], truncated: false, independentlyVerified: false)
        #expect(!ToolAdmission.measure(references, problem: nil, summary: "synthetic", ceiling: 98304).admitted)
    }
    @Test func hostileProblemsAndUnknownFailuresAreSanitized_T15() async throws {
        let p = FaultProvider(.problem), h = try await faultHarness(p, ceiling: 4096)
        let args = SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: nil)
        for (mode, code) in [(FaultProvider.Mode.problem, "upstream_rate_limited"), (.unknown, "upstream_unavailable")] {
            await p.set(mode)
            let result = try await invoke(h, "search_articles", args)
            let raw = try WireCodec.write(result, limits: .balanced).result
            #expect(!String(decoding: raw, as: UTF8.self).contains("PRIVATE_SENTINEL"))
            #expect(result.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["problem"]?.objectValue?["code"]?.stringValue == code)
            #expect(raw.count < 4096)
        }
        await p.set(.healthy)
        #expect(try success(SearchPage.self, await invoke(h, "search_articles", args)).candidates.isEmpty)
    }
    @Test func cancellationAndOperationalFailuresRetainSDKOwnership_T16() async throws {
        let p = FaultProvider(.budget), h = try await faultHarness(p)
        let args = SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: nil)
        for mode in [FaultProvider.Mode.budget, .json] {
            await p.set(mode)
            let response = try await invoke(h, "search_articles", args)
            #expect(try errorCode(response) == -32603)
            #expect(response.objectValue?["result"] == nil)
        }
        await p.set(.cancelled)
        do { _ = try await invoke(h, "search_articles", args); Issue.record("Must throw cancellation") }
        catch is CancellationError { }
        await p.set(.deadline)
        do { _ = try await invoke(h, "search_articles", args); Issue.record("Must retain SDK deadline") }
        catch let failure as CoreFailure { #expect(failure == .deadline) }
        let budget = try RequestBudget(workUnits: 1024)
        var limits = JSONLimits.balanced; limits[.outputBytes] = 1
        do { _ = try await budget.performJSON(limits: limits) { try WireCodec.write(.string("too large"), limits: $0) }; Issue.record("Must hit writer resource failure") }
        catch let failure as JSONFailure { #expect(failure.category == .resource) }
        #expect(await budget.snapshot.isTerminal)
        do { try await budget.consume(1); Issue.record("A failed account must not replenish") }
        catch let failure as RequestBudget.Failure { #expect(failure == .exhausted) }
    }
}
