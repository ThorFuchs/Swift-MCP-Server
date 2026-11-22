// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import MCPClient
import MCPHTTPClient
import ExplorerDomain
import ExplorerMCP

/// One step of a guided MCP journey: bounded, owned metadata only. No arguments, result
/// bodies, headers or credentials are retained.
public struct MCPJourneyStep: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case succeeded = "Succeeded", failed = "Failed", cancelled = "Cancelled" }
    public let id: Int
    public let method: String
    public let tool: String?
    public let status: Status
    /// The SDK checked structuredContent against the tool's outputSchema and the adapter checked identity.
    public let validated: Bool
    public let milliseconds: Int
    /// Revision of the snapshot this step returned or read, when it has one.
    public let revisionID: String?
    /// Owned description of a failure category; never server-supplied text.
    public let failure: String?
}

public enum MCPJourneyPhase: String, Sendable { case idle = "Ready", running = "Running", completed = "Completed", failed = "Failed", cancelled = "Cancelled" }

/// The "Explore MCP" journey: after an explicit user action against an already running local
/// server, a public-SDK `Client` over `HTTPClientTransport` performs discover → tools/list → the
/// four tools. One finite owned task; `cancelAndJoin()` returns only after it ended.
@MainActor @Observable public final class MCPJourneyController {
    public private(set) var phase = MCPJourneyPhase.idle
    public private(set) var steps: [MCPJourneyStep] = []
    public private(set) var serverName: String?
    public private(set) var outline: Outline?
    public private(set) var passage: SectionPassage?
    public private(set) var references: SectionReferences?
    public private(set) var problem: ExplorerProblem?
    public var isRunning: Bool { task != nil }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let makeTransport: @Sendable (ServerEndpoint) throws -> any ClientTransport
    @ObservationIgnored private var closed = false

    public init(makeTransport: @escaping @Sendable (ServerEndpoint) throws -> any ClientTransport = MCPJourneyController.httpTransport) {
        self.makeTransport = makeTransport
    }
    public nonisolated static func httpTransport(_ endpoint: ServerEndpoint) throws -> any ClientTransport {
        guard let url = URL(string: endpoint.url), url.host == "127.0.0.1" else { throw HostFailure.invalidConfiguration }
        return HTTPClientTransport(endpoint: url, timeout: .seconds(20))
    }

    /// Runs only for a running server with a concrete loopback endpoint; otherwise nothing is sent.
    public func start(endpoint: ServerEndpoint?, running: Bool, source: SourceProfile) {
        guard !closed, task == nil else { return }
        guard running, let endpoint else {
            phase = .failed; steps = []; problem = nil
            steps = [.init(id: 0, method: "server/discover", tool: nil, status: .failed, validated: false, milliseconds: 0, revisionID: nil,
                           failure: "The local server is not running. Start it first; the journey never starts it.")]
            return
        }
        phase = .running; steps = []; serverName = nil; outline = nil; passage = nil; references = nil; problem = nil
        let makeTransport = self.makeTransport
        task = Task { [weak self] in
            await self?.run(endpoint: endpoint, source: source, makeTransport: makeTransport)
            self?.task = nil
        }
    }
    public func cancel() { task?.cancel() }
    /// Cancels and joins; afterwards no client request of this journey is in flight.
    public func cancelAndJoin() async { task?.cancel(); await task?.value }
    public func shutdown() async { closed = true; await cancelAndJoin() }
    public func waitUntilFinished() async { await task?.value }

    private func record(_ method: String, _ tool: String?, _ start: ContinuousClock.Instant, revision: String? = nil, error: (any Error)? = nil) {
        guard steps.count < 8 else { return }
        let elapsed = start.duration(to: .now).components
        let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let status: MCPJourneyStep.Status = error == nil ? .succeeded : (error is CancellationError ? .cancelled : .failed)
        steps.append(.init(id: steps.count, method: method, tool: tool, status: status, validated: error == nil, milliseconds: ms,
                           revisionID: revision, failure: error.map(Self.describe)))
    }
    static func describe(_ error: any Error) -> String {
        switch error {
        case is CancellationError: return "Cancelled by the user; the exchange was closed."
        case let problem as ExplorerProblem: return "Tool problem: \(problem.code.rawValue). \(problem.recovery)"
        case let failure as MCPResearchFailure:
            switch failure {
            case .notPrepared: return "Tool called before the catalog was loaded."
            case .missingTools(let names): return "Server does not offer: \(names.joined(separator: ", "))."
            case .unsupportedServer: return "Server does not offer MCP 2026-07-28."
            case .rejected(let code): return "Server rejected the request (JSON-RPC \(code))."
            case .invalidResponse: return "Response failed protocol or outputSchema validation."
            case .identityMismatch: return "Response named a different snapshot or part than requested."
            case .transport: return "Transport failed: connection refused, closed or timed out."
            }
        default: return "Unexpected failure."
        }
    }

    private func run(endpoint: ServerEndpoint, source: SourceProfile, makeTransport: @Sendable (ServerEndpoint) throws -> any ClientTransport) async {
        var method = "server/discover + tools/list", tool: String? = nil, start = ContinuousClock.now
        do {
            let client = MCPResearchClient(client: Client(transport: try makeTransport(endpoint)), profile: source)
            // One hop as the user sees it: server/discover, then every tools/list page with outputSchemas.
            method = "server/discover + tools/list"
            let (server, _) = try await client.prepare()
            serverName = server.serverInfo?.name
            record(method, nil, start)
            method = "tools/call"; tool = "search_articles"; start = .now
            let query = source == .offlineDemo ? OfflineTour.query : "Noether's theorem"
            let page = try await client.search(.init(query: query, project: source.project, limit: 5))
            record(method, tool, start)
            guard let candidate = page.candidates.first else { throw PublicProblems.project(.absentPage) }
            tool = "get_article_outline"; start = .now
            let outline = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
            self.outline = outline; record(method, tool, start, revision: outline.snapshot.revisionID)
            guard let part = outline.sections.first(where: { $0.location.partID == OfflineTour.partID })?.location ?? outline.sections.first?.location
            else { throw PublicProblems.project(.absentSection) }
            tool = "read_article_section"; start = .now
            passage = try await client.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: 4096))
            record(method, tool, start, revision: outline.snapshot.revisionID)
            tool = "get_section_references"; start = .now
            references = try await client.references(.init(snapshot: outline.snapshot, part: part))
            record(method, tool, start, revision: outline.snapshot.revisionID)
            phase = .completed
        } catch {
            let failure = MCPResearchClient.classify(error)
            record(method, tool, start, error: failure)
            if let p = failure as? ExplorerProblem { problem = p }
            phase = failure is CancellationError ? .cancelled : .failed
        }
    }
}
