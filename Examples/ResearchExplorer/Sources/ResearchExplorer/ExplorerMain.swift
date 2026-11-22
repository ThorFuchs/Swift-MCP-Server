// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP
import MCPClient
import MCPClientStdio
import System

@main struct ResearchExplorer {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] { usage(); return }
        guard args == ["--walkthrough"] || args == ["--stdio"] || args == ["--mcp-client"] else {
            usage(); Darwin.exit(64)
        }
        if args == ["--mcp-client"] {
            // A real MCP client: this executable launches itself as `--stdio` and drives it over pipes.
            // RE_FD_AUDIT=n (1–5, used by tests) repeats the journey n times and reports this process's
            // open descriptors around each run, to show that a joined child leaves nothing behind.
            let runs = Int(ProcessInfo.processInfo.environment["RE_FD_AUDIT"] ?? "").map { min(max($0, 1), 5) }
            do { for _ in 0..<(runs ?? 1) { try await mcpClientJourney(audit: runs != nil) }; return }
            catch is CancellationError { FixtureStdioHost.diagnostic("MCP client journey cancelled.\n"); Darwin.exit(1) }
            catch { FixtureStdioHost.diagnostic("MCP client journey failed: \(MCPClientJourneyFailure.describe(error))\n"); Darwin.exit(1) }
        }
        do {
            // Same service and catalog in both modes, no network credential.
            let provider = try FixtureProvider.load()
            let service = ExplorerService(provider: provider, limits: try ExplorerLimits())
            let policy = try FixtureStdioHost.policy()
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let server = try await ExplorerTools.makeServer(service: service, catalogKeyMaterial: key,
                clock: { Int64(Date().timeIntervalSince1970 * 1000) })
            if args == ["--stdio"] {
                try await FixtureStdioHost.run(server: server, policy: policy)
            } else {
                do { try await walkthrough(service) }
                catch { await server.stopAdmission(); await server.closeSubscriptions(); throw error }
                await server.stopAdmission(); await server.closeSubscriptions()
            }
        } catch is CancellationError {
            FixtureStdioHost.diagnostic("WRE cancelled.\n"); Darwin.exit(1)
        } catch {
            // Do not print arbitrary NSError/ExplorerProblem/provider payloads.
            FixtureStdioHost.diagnostic("WRE failed. Check fixture resources, mode and pipe configuration.\n")
            Darwin.exit(1)
        }
    }
    private static func usage() {
        FixtureStdioHost.diagnostic("Research Explorer (synthetic fixtures)\nChoose --walkthrough for human output or --stdio for MCP frames over pipes.\n--mcp-client runs a real MCP client against a `--stdio` child of this executable.\n--help exits 0; missing or invalid mode exits 64.\n")
    }
    private static func walkthrough(_ service: ExplorerService) async throws {
        let search = try await service.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10))
        guard let candidate = search.candidates.first else { throw PublicProblems.project(.absentPage) }
        let outline = try await service.outline(.init(project: candidate.project, candidateID: candidate.id))
        guard let selected = outline.sections.first(where: { $0.location.partID == "p2" }) else { throw PublicProblems.project(.absentSection) }
        let section = try await service.section(.init(snapshot: outline.snapshot, part: selected.location, maxTextBytes: 32768))
        let references = try await service.references(.init(snapshot: outline.snapshot, part: selected.location))
        print("DIRECT (not MCP): ExplorerService called in-process. Use --mcp-client for the MCP journey.")
        print("SYNTHETIC FIXTURE — \(outline.provenance.title), revision \(outline.snapshot.revisionID), normalizer \(outline.snapshot.normalizerVersion)")
        print(section.text)
        print("Introduction truncated: \(outline.introductionTruncated); any outline omission: \(outline.truncated)")
        print("References: \(references.references.count); unresolved: \(references.unresolvedIDs.joined(separator: ", ")); UNVERIFIED CITATIONS")
    }
}

enum MCPClientJourneyFailure {
    static func describe(_ error: any Error) -> String {
        switch error {
        case let problem as ExplorerProblem: return "tool problem \(problem.code.rawValue)"
        case let failure as MCPResearchFailure: return "\(failure)"
        case let failure as StdioClientTransportError: return "stdio \(failure)"
        default: return "unexpected failure"
        }
    }
}
extension ResearchExplorer {
    /// Launches `<this executable> --stdio` with the public `StdioClientTransport`, then runs
    /// server/discover → tools/list → the four tools through `MCPResearchClient`. The child is
    /// shut down gracefully and its run joined before returning; on failure the run is cancelled
    /// (SIGTERM, then SIGKILL after the grace period) and joined.
    static func mcpClientJourney(audit: Bool) async throws {
        guard let path = Bundle.main.executablePath else { throw MCPResearchFailure.transport }
        func descriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let before = audit ? descriptors() : 0
        let transport = StdioClientTransport(configuration: .init(executable: .path(FilePath(path)), arguments: ["--stdio"],
            maximumPendingRequests: 4, maximumMessageBytes: 1_048_576, terminationGrace: .seconds(2)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            do {
                let sdk = Client(transport: transport)
                // run() becomes active asynchronously; wait for it (bounded), never for the server forever.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while true {
                    do { _ = try await sdk.discover(); break }
                    catch StdioClientTransportError.notRunning where ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                }
                let client = MCPResearchClient(client: sdk, profile: .offlineDemo)
                let (server, tools) = try await client.prepare()
                print("MCP over stdio: child `research-explorer --stdio`, server \(server.serverInfo?.name ?? "unnamed"), protocol \(Client.protocolVersion)")
                print("tools/list: \(tools.map(\.name).sorted().joined(separator: ", ")) (outputSchemas enforced)")
                let page = try await client.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10))
                print("search_articles: \(page.candidates.count) candidates")
                guard let candidate = page.candidates.first else { throw PublicProblems.project(.absentPage) }
                let outline = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
                print("get_article_outline: \(outline.provenance.title), revision \(outline.snapshot.revisionID), \(outline.sections.count) sections")
                guard let part = outline.sections.first(where: { $0.location.partID == "p2" })?.location else { throw PublicProblems.project(.absentSection) }
                let passage = try await client.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: 32768))
                print("read_article_section \(part.partID): \(passage.text.utf8.count) bytes from revision \(passage.snapshot.revisionID)")
                let references = try await client.references(.init(snapshot: outline.snapshot, part: part))
                print("get_section_references: \(references.references.map(\.id).joined(separator: ", ")); unresolved: \(references.unresolvedIDs.joined(separator: ", ")); UNVERIFIED CITATIONS")
                transport.shutdown()               // graceful: close the child's stdin
                try await group.waitForAll()       // joined: the child exited and run() returned
                print("Child exited; transport joined.")
                if audit { print("Descriptors before launch: \(before); after join: \(descriptors())") }
            } catch {
                group.cancelAll(); _ = try? await group.waitForAll()
                throw error
            }
        }
    }
}
