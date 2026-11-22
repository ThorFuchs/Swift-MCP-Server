// SPDX-License-Identifier: Apache-2.0
// RE-02 (#34): a real MCP client over stdio against the actual `research-explorer --stdio` child.
// The binary path comes from RE_CLI (set by Scripts/test.sh); without it these tests fail.
import Foundation
import Testing
import System
import MCPClient
import MCPClientStdio
import ExplorerDomain
import WikimediaAccess
import ExplorerMCP

private func cli() throws -> String { try #require(ProcessInfo.processInfo.environment["RE_CLI"], "Set RE_CLI to the built research-explorer") }
private func stdio() throws -> StdioClientTransport {
    StdioClientTransport(configuration: .init(executable: .path(FilePath(try cli())), arguments: ["--stdio"],
        maximumPendingRequests: 4, maximumMessageBytes: 1_048_576, terminationGrace: .seconds(2)))
}
private func ready(_ client: Client) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        do { _ = try await client.discover(); return }
        catch StdioClientTransportError.notRunning where ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@Suite(.serialized) struct StdioMCPClientTests {
    @Test func cliMCPClientModeDrivesItsOwnStdioChildAndJoins() throws {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: try cli()); process.arguments = ["--mcp-client"]
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(["RE_FD_AUDIT": "3"]) { _, new in new }
        try process.run(); process.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "stderr: \(err)")
        // Measured inside the isolated client process over three launch/join cycles. The first
        // launch creates the process launcher's lasting infrastructure once; after that, every
        // joined child must leave the descriptor count exactly where it was (no per-run leak).
        let audits = out.split(separator: "\n").filter { $0.hasPrefix("Descriptors before launch: ") }
            .map { $0.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        #expect(audits.count == 3 && audits.allSatisfy { $0.count == 2 }, "\(audits)")
        if audits.count == 3 {
            #expect(audits[1][0] == audits[0][1] && audits[1][1] == audits[1][0] && audits[2][1] == audits[2][0], "\(audits)")
        }
        #expect(out.components(separatedBy: "Child exited; transport joined.").count == 4)
        #expect(out.hasPrefix("MCP over stdio: child `research-explorer --stdio`"))
        #expect(out.contains("tools/list: get_article_outline, get_section_references, read_article_section, search_articles"))
        #expect(out.contains("revision r1") && out.contains("get_section_references: ref-instrument-notes; unresolved: ref-lost-ledger"))
        #expect(out.contains("Child exited; transport joined.\n") && err.isEmpty)
    }

    @Test func walkthroughIsLabelledDirectNotMCP() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: try cli()); process.arguments = ["--walkthrough"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && out.hasPrefix("DIRECT (not MCP)"))
    }

    @Test func stdioClientMatchesDirectServiceAcrossRepeatedStarts() async throws {
        let direct = ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        let expectedOutline = try await direct.outline(.init(project: "fixture-enwiki", candidateID: "fixture-expedition"))
        for _ in 0..<2 {
            let transport = try stdio()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await transport.run() }
                do {
                    let sdk = Client(transport: transport); try await ready(sdk)
                    let client = MCPResearchClient(client: sdk, profile: .offlineDemo)
                    try await client.prepare()
                    let outline = try await client.outline(.init(project: "fixture-enwiki", candidateID: "fixture-expedition"))
                    // Separate processes, same pinned identity and structure (retrieval time differs).
                    #expect(outline.snapshot == expectedOutline.snapshot && outline.sections.map(\.location.partID) == expectedOutline.sections.map(\.location.partID))
                    for section in outline.sections {
                        let viaMCP = try await client.section(.init(snapshot: outline.snapshot, part: section.location, maxTextBytes: nil)).text
                        let local = try await direct.section(.init(snapshot: expectedOutline.snapshot, part: .init(snapshot: expectedOutline.snapshot, partID: section.location.partID), maxTextBytes: nil)).text
                        #expect(viaMCP == local)
                    }
                    transport.shutdown(); try await group.waitForAll()
                } catch { group.cancelAll(); _ = try? await group.waitForAll(); throw error }
            }
        }
    }

    @Test func cancellingTheRunEndsInFlightCallsAndTheChild() async throws {
        let transport = try stdio()
        let run = Task { try await transport.run() }
        let sdk = Client(transport: transport); try await ready(sdk)
        let client = MCPResearchClient(client: sdk, profile: .offlineDemo)
        try await client.prepare()
        run.cancel() // SIGTERM, then SIGKILL after the grace period
        _ = await run.result
        do { _ = try await client.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 10)); Issue.record("call after cancel must fail") }
        catch { #expect(error as? MCPResearchFailure == .transport || error is CancellationError) }
    }
}
