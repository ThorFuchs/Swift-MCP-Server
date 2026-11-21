// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import ExplorerDomain
import WikimediaAccess

public protocol ExplorerToolObserver: Sendable {
    func withToolCall(_ name: String, operation: @escaping @Sendable () async throws -> JSON) async throws -> JSON
}

public enum ExplorerTools {
    public static let names = ["search_articles", "get_article_outline", "read_article_section", "get_section_references"]
    public static func catalog(service: ExplorerService, responseBytes: Int = 131_072, observer: (any ExplorerToolObserver)? = nil) throws -> ServerCatalog {
        guard (4096...131_072).contains(responseBytes) else { throw CoreFailure.invalidPolicy }
        return try ServerCatalog(tools: [
            registration("search_articles", input: SearchInput.self, responseBytes: responseBytes, observer: observer, profile: service.profile) {
                try await service.search($0)
            },
            registration("get_article_outline", input: OutlineInput.self, responseBytes: responseBytes, observer: observer, profile: service.profile) {
                try await service.outline($0)
            },
            registration("read_article_section", input: SectionInput.self, responseBytes: responseBytes, observer: observer, profile: service.profile) {
                try await service.section($0)
            },
            registration("get_section_references", input: ReferencesInput.self, responseBytes: responseBytes, observer: observer, profile: service.profile) {
                try await service.references($0)
            },
        ])
    }
    /// Host-supplied key material is ONLY for SDK catalog cursors. Application
    /// section continuation is unsupported. No transport or credential is owned.
    public static func makeServer(service: ExplorerService, catalogKeyMaterial: Data,
                                  clock: @escaping @Sendable () -> Int64, responseBytes: Int = 131_072, observer: (any ExplorerToolObserver)? = nil) async throws -> Server {
        let key = try CursorProtector.Key(identifier: ScalarText("wre"), material: catalogKeyMaterial)
        let cursors = try CursorProtector(keys: [key], active: ScalarText("wre"), clock: clock)
        let info = try WireCodec.parse(Array(#"{"name":"wikipedia-research-explorer","version":"0.1.0-source"}"#.utf8), limits: .balanced).result
        let configuration = try ServerConfiguration(activeRequests: 4, queuedRequests: 4, requestsPerPrincipal: 2,
            terminalWork: 524_288, messageBytes: 65_536, resultBytes: 131_072, catalogEntries: 4, pageEntries: 4,
            deadlineMilliseconds: 15_000, bufferedBytes: 71_303_168,
            // Keep catalog preparation finite and cumulative, using the SDK fixture's host policy.
            preparation: ServerPreparationPolicy(work: 512_000_000, compilation: 256_000_000, evaluation: 128_000_000))
        return try await Server.make(info: info, catalog: catalog(service: service, responseBytes: responseBytes, observer: observer), cursors: cursors, configuration: configuration)
    }
    private static func definition(_ name: String, profile: SourceProfile) throws -> JSON {
        guard names.contains(name), let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: profile == .offlineDemo ? "Contracts" : "Contracts/Live-v1") else { throw CoreFailure.invalidInput }
        let file = try FileHandle(forReadingFrom: url)
        let bytes: Data
        do { bytes = try file.read(upToCount: 65_537) ?? Data() }
        catch { try? file.close(); throw error }
        try file.close()
        guard bytes.count <= 65_536 else { throw CoreFailure.limit }
        return try WireCodec.parse(Array(bytes), limits: .balanced).result
    }
    private struct Outcome<Value: Encodable & Sendable>: Encodable, Sendable {
        let status: String
        let value: Value?
        let problem: ExplorerProblem?
    }
    private struct Text: Encodable, Sendable { let type = "text"; let text: String }
    private struct Envelope<Value: Encodable & Sendable>: Encodable, Sendable {
        let resultType = "complete"
        let content: [Text]
        let structuredContent: Outcome<Value>
        let isError: Bool
    }
    private static func registration<Input: Decodable & Sendable, Output: ResponseShape>(
        _ name: String, input: Input.Type, responseBytes: Int, observer: (any ExplorerToolObserver)?, profile: SourceProfile,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) throws -> ToolRegistration {
        let handler: ProviderHandler = { presence, context in
            try context.checkCancellation()
            guard case .value(let raw) = presence else { throw CoreFailure.invalidInput }
            let arguments = try await context.budget.performJSON {
                try JSONValueDecoder(options: .init(limits: $0)).decodeWithReport(Input.self, from: raw)
            }
            let outcome: Outcome<Output>
            do {
                let value = try await operation(arguments)
                try context.checkCancellation()
                outcome = .init(status: "ok", value: value, problem: nil)
            } catch let problem as ExplorerProblem {
                try context.checkCancellation()
                outcome = .init(status: "error", value: nil, problem: profile.problem(problem.code))
            } catch let error as CancellationError { throw error }
            catch let error as CoreFailure { throw error }
            catch let error as any RequestAccessFailure { throw error }
            catch let error as RequestMirrorFailure { throw error }
            catch let error as RequestBudget.Failure { throw error }
            catch let error as JSONFailure { throw error }
            catch let error as WireFailure { throw error }
            catch let error as DecodingError { throw error }
            catch let error as EncodingError { throw error }
            catch {
                try context.checkCancellation()
                outcome = .init(status: "error", value: nil, problem: PublicProblems.project(.upstreamUnavailable))
            }
            // Cancellation, deadline and operational JSON errors propagate to
            // the SDK terminal owner. They are never disguised as no results.
            return try await envelope(outcome, name: name, maximumBytes: responseBytes, context: context, profile: profile)
        }
        return ToolRegistration(definition: try definition(name, profile: profile)) { presence, context in
            if let observer { return try await observer.withToolCall(name) { try await handler(presence, context) } }
            return try await handler(presence, context)
        }
    }
    private static func humanSummary<Value>(_ value: Value?, profile: SourceProfile) -> String {
        if profile == .wikipediaEnglish {
            if let page = value as? SearchPage { return "Wikipedia English: showing up to \(page.candidates.count) candidates. Refine your query at the cap; total matches are unknown." }
            return "Wikipedia English fetched snapshot; plain text only. Inspect exact revision, retrieval and license in structuredContent. Citations are not independently verified."
        }
        guard let value else { return "Synthetic fixture result; inspect structuredContent." }
        switch value {
        case let page as SearchPage:
            return "Synthetic search: \(page.candidates.count) candidate(s); truncated: \(page.truncated). Use a candidate ID for an outline."
        case let outline as Outline:
            return "Synthetic revision \(outline.snapshot.revisionID): \(outline.sections.count) of \(outline.totalSections) section locators; introduction truncated: \(outline.introductionTruncated); any omission: \(outline.truncated)."
        case let passage as SectionPassage:
            return "Synthetic section: \(passage.text.utf8.count) UTF8 bytes from \(passage.includedPartIDs.count) part(s); text supplied: \(passage.textAvailable); truncated: \(passage.truncated)."
        case let refs as SectionReferences:
            return "Synthetic citations: \(refs.references.count) reference record(s), \(refs.unresolvedIDs.count) unresolved; not independently verified; truncated: \(refs.truncated)."
        default: return "Synthetic fixture result; inspect structuredContent."
        }
    }
    private static func envelope<Value: ResponseShape>(_ outcome: Outcome<Value>, name: String,
        maximumBytes: Int, context: RequestContext, profile: SourceProfile) async throws -> JSON {
        // Pay BEFORE examining output fields. This covers both candidate and
        // fallback bounds (bounded model proof in RESPONSE_ADMISSION.md).
        try await context.budget.consume(ExplorerResponsePolicy.preflightWork)
        try context.checkCancellation()
        let ceiling = ExplorerResponsePolicy.toolCeiling(requested: maximumBytes)
        var selected = outcome
        var summary = outcome.problem.map { "\(name): \($0.code.rawValue). \($0.recovery)" }
            ?? humanSummary(outcome.value, profile: profile)
        let bound = ToolAdmission.measure(outcome.value, problem: outcome.problem, summary: summary, ceiling: ceiling)
        if !bound.admitted {
            selected = .init(status: "error", value: nil, problem: PublicProblems.project(.budgetExceeded))
            summary = "\(name): budget_exceeded. Select a narrower section or smaller limit."
        }
        let finalBound = bound.admitted ? bound : ToolAdmission.measure(selected.value, problem: selected.problem, summary: summary, ceiling: ceiling)
        guard finalBound.admitted, (bound.admitted ? bound.visitedWork : bound.visitedWork + finalBound.visitedWork) <= ExplorerResponsePolicy.preflightWork else { throw CoreFailure.limit }
        let result = Envelope(content: [Text(text: summary)], structuredContent: selected, isError: selected.problem != nil)
        var limits = JSONLimits.balanced
        limits[.outputBytes] = UInt64(ceiling)
        let encoded = try await context.budget.performJSON(limits: limits) {
            try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(result)
        }
        let bytes = try await context.budget.performJSON(limits: limits) { try WireCodec.write(encoded, limits: $0) }
        guard bytes.count <= finalBound.upper, bytes.count <= ceiling else { throw CoreFailure.limit }
        return encoded
    }
}
