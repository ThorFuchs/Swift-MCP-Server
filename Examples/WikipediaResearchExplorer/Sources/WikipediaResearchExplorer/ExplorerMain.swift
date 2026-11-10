// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP

@main struct WikipediaResearchExplorer {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] { usage(); return }
        guard args == ["--walkthrough"] || args == ["--stdio"] else {
            usage(); Darwin.exit(64)
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
        FixtureStdioHost.diagnostic("Wikipedia Research Explorer (synthetic fixtures)\nChoose --walkthrough for human output or --stdio for MCP frames over pipes.\n--help exits 0; missing or invalid mode exits 64.\n")
    }
    private static func walkthrough(_ service: ExplorerService) async throws {
        let search = try await service.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10))
        guard let candidate = search.candidates.first else { throw PublicProblems.project(.absentPage) }
        let outline = try await service.outline(.init(project: candidate.project, candidateID: candidate.id))
        guard let selected = outline.sections.first(where: { $0.location.partID == "p2" }) else { throw PublicProblems.project(.absentSection) }
        let section = try await service.section(.init(snapshot: outline.snapshot, part: selected.location, maxTextBytes: 32768))
        let references = try await service.references(.init(snapshot: outline.snapshot, part: selected.location))
        print("SYNTHETIC FIXTURE — \(outline.provenance.title), revision \(outline.snapshot.revisionID), normalizer \(outline.snapshot.normalizerVersion)")
        print(section.text)
        print("Introduction truncated: \(outline.introductionTruncated); any outline omission: \(outline.truncated)")
        print("References: \(references.references.count); unresolved: \(references.unresolvedIDs.joined(separator: ", ")); UNVERIFIED CITATIONS")
    }
}
