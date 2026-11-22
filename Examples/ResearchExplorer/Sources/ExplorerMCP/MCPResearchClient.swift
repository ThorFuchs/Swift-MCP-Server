// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPClient
import ExplorerDomain

/// Why an MCP research call failed, kept distinct from a tool's own domain problem (which is
/// rethrown as the owned `ExplorerProblem`). Cases carry no server-supplied text.
public enum MCPResearchFailure: Error, Sendable, Equatable {
    /// A tool was called before `prepare()` loaded the catalog and its output schemas.
    case notPrepared
    /// The server does not list all four Research Explorer tools, or one lacks an outputSchema.
    case missingTools([String])
    /// `server/discover` did not offer MCP 2026-07-28.
    case unsupportedServer
    /// The server answered with a JSON-RPC error (`code`), for example invalid params.
    case rejected(code: Int)
    /// A response that failed protocol, outputSchema or envelope validation.
    case invalidResponse
    /// A schema-valid result whose identity does not match what was asked for.
    case identityMismatch
    /// The transport failed: refused connection, closed stream, child exit, deadline.
    case transport
}

/// `ResearchClient`-shaped adapter over the public SDK `Client`. Every result is the server's
/// exact `structuredContent`, checked by the SDK against the tool's `outputSchema` (from
/// `tools/list`), then decoded strictly and checked against the requested identity.
/// The transport (HTTP or stdio) and its lifetime belong to the caller.
public actor MCPResearchClient {
    public static let toolNames = ["search_articles", "get_article_outline", "read_article_section", "get_section_references"]
    public nonisolated let profile: SourceProfile
    private let client: Client
    private var prepared = false
    public init(client: Client, profile: SourceProfile) { self.client = client; self.profile = profile }

    /// `server/discover` then `tools/list` (bounded to 8 pages). Required before any tool call, so
    /// structuredContent is always validated against the advertised outputSchema.
    @discardableResult
    public func prepare() async throws -> (server: ServerDescription, tools: [Tool]) {
        let server: ServerDescription
        do { server = try await client.discover() }
        catch { throw Self.classify(error) }
        var tools: [Tool] = [], cursor: String?, pages = 0
        repeat {
            let page: Page<Tool>
            do { page = try await client.listTools(cursor: cursor) } catch { throw Self.classify(error) }
            tools += page.items; cursor = page.nextCursor; pages += 1
            guard pages < 8 || cursor == nil else { throw MCPResearchFailure.invalidResponse }
        } while cursor != nil
        let usable = Set(tools.filter { $0.outputSchema != nil }.map(\.name))
        let missing = Self.toolNames.filter { !usable.contains($0) }
        guard missing.isEmpty else { throw MCPResearchFailure.missingTools(missing) }
        prepared = true
        return (server, tools.filter { Self.toolNames.contains($0.name) })
    }

    public func search(_ input: SearchInput) async throws -> SearchPage {
        let page = try await call("search_articles", input, SearchPage.self)
        guard page.provider == profile.provider, page.candidates.count <= (input.limit ?? 10),
              page.candidates.allSatisfy({ $0.project == input.project }) else { throw MCPResearchFailure.identityMismatch }
        return page
    }
    public func outline(_ input: OutlineInput) async throws -> Outline {
        let outline = try await call("get_article_outline", input, Outline.self)
        guard profile.admits(outline.snapshot), outline.snapshot.project == input.project,
              outline.provenance.identity == outline.snapshot, outline.provenance.synthetic == profile.synthetic,
              outline.sections.allSatisfy({ $0.location.snapshot == outline.snapshot }) else { throw MCPResearchFailure.identityMismatch }
        return outline
    }
    public func section(_ input: SectionInput) async throws -> SectionPassage {
        let passage = try await call("read_article_section", input, SectionPassage.self)
        guard passage.snapshot == input.snapshot, passage.provenance.identity == input.snapshot,
              passage.selectedPartID == input.part.partID else { throw MCPResearchFailure.identityMismatch }
        return passage
    }
    public func references(_ input: ReferencesInput) async throws -> SectionReferences {
        let refs = try await call("get_section_references", input, SectionReferences.self)
        guard refs.snapshot == input.snapshot, refs.provenance.identity == input.snapshot,
              refs.associations.allSatisfy({ !$0.partID.isEmpty }) else { throw MCPResearchFailure.identityMismatch }
        return refs
    }

    private func call<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ name: String, _ input: Input, _: Output.Type) async throws -> Output {
        guard prepared else { throw MCPResearchFailure.notPrepared }
        let arguments = try JSONValueEncoder(options: .init(limits: .balanced)).encodeWithReport(input).result
        let result: ToolResult
        do { result = try await client.callTool(name, arguments: arguments) } catch { throw Self.classify(error) }
        try Task.checkCancellation()
        guard result.resultType == "complete", let envelope = result.structuredContent?.objectValue,
              let status = envelope["status"]?.stringValue else { throw MCPResearchFailure.invalidResponse }
        let decoder = JSONValueDecoder(options: .init(limits: .balanced))
        switch status {
        case "ok":
            guard !result.isError, envelope["problem"] == nil, let value = envelope["value"] else { throw MCPResearchFailure.invalidResponse }
            do { return try decoder.decodeWithReport(Output.self, from: value).result }
            catch { throw MCPResearchFailure.invalidResponse }
        case "error":
            guard result.isError, envelope["value"] == nil, let raw = envelope["problem"],
                  let problem = try? decoder.decodeWithReport(ExplorerProblem.self, from: raw).result else { throw MCPResearchFailure.invalidResponse }
            // Re-derive the owned public wording from the code; never surface server text.
            throw profile.problem(problem.code)
        default:
            throw MCPResearchFailure.invalidResponse
        }
    }

    /// Maps an SDK or transport error to its owned failure category (cancellation stays cancellation).
    public static func classify(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is MCPResearchFailure || error is ExplorerProblem { return error }
        if let client = error as? ClientError {
            if let code = client.serverCode { return MCPResearchFailure.rejected(code: code) }
            switch client {
            case .unsupportedProtocol: return MCPResearchFailure.unsupportedServer
            case .invalidResponse, .unsupportedInput, .tooManyInputRounds: return MCPResearchFailure.invalidResponse
            case .noResponse, .server: return MCPResearchFailure.transport
            }
        }
        return MCPResearchFailure.transport
    }
}
