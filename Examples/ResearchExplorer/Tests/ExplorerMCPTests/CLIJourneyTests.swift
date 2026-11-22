// SPDX-License-Identifier: Apache-2.0
// End-to-end checks of the real `research-explorer --stdio` executable over pipes.
// The binary path comes from RE_CLI (set by Scripts/test.sh); without it these tests fail
// on purpose instead of being skipped.
import Foundation
import Testing
import JSON
import MCPProtocol
import ExplorerDomain

private struct CLIFailure: Error, CustomStringConvertible { let description: String }

private final class CLIChild {
    let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(arguments: [String]) throws {
        let binary = try #require(ProcessInfo.processInfo.environment["RE_CLI"], "Set RE_CLI to the built research-explorer")
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try process.run()
    }

    func send(_ frame: Data) throws { try input.fileHandleForWriting.write(contentsOf: frame) }

    func exchange(_ frame: Data) async throws -> JSON {
        try send(frame)
        guard let line = try await lines.next() else { throw CLIFailure(description: "stdout closed before a response") }
        return try Frames.parse(Data(line.utf8))
    }

    /// Closes stdin, then collects the remaining stdout lines, stderr and the exit status.
    func finish() async throws -> (exit: Int32, extraStdoutLines: Int, stderr: String) {
        try input.fileHandleForWriting.close()
        var extra = 0
        while try await lines.next() != nil { extra += 1 }
        let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, extra, String(decoding: diagnostics, as: UTF8.self))
    }
}

private enum Frames {
    struct Empty: Encodable, Sendable {}
    private struct Parameters<A: Encodable & Sendable>: Encodable {
        let _meta: [String: JSON]
        let name: String?
        let arguments: A?
    }
    private struct Request<A: Encodable & Sendable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Parameters<A>
    }
    static func list(id: Int) throws -> Data {
        try encoded(Request<Empty>(id: id, method: "tools/list", params: .init(_meta: meta(), name: nil, arguments: nil)))
    }
    static func call<A: Encodable & Sendable>(_ name: String, _ arguments: A, id: Int) throws -> Data {
        try encoded(Request(id: id, method: "tools/call", params: .init(_meta: meta(), name: name, arguments: arguments)))
    }
    static func value<T: Decodable & Sendable>(_ type: T.Type, _ response: JSON) throws -> T {
        guard let result = response.objectValue?["result"]?.objectValue, result["isError"]?.booleanValue == false,
              let structured = result["structuredContent"]?.objectValue, structured["status"]?.stringValue == "ok",
              let value = structured["value"] else { throw CLIFailure(description: "unexpected tool result") }
        return try JSONValueDecoder().decodeWithReport(T.self, from: value).result
    }
    static func parse(_ bytes: Data) throws -> JSON {
        var limits = JSONLimits.balanced; limits[.inputBytes] = 131_072
        return try WireCodec.parse(Array(bytes), limits: limits).result
    }
    private static func meta() throws -> [String: JSON] {
        [ProtocolMetadata.protocolVersion: .string("2026-07-28"),
         ProtocolMetadata.clientCapabilities: try WireCodec.parse(Array("{}".utf8), limits: .balanced).result]
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONValueEncoder(options: .init(limits: .balanced)).encodeWithReport(value).result
        var data = try WireCodec.write(json, limits: .balanced).result
        data.append(10)
        return data
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct CLIJourneyTests {
    @Test func stdioJourneyListsToolsAndReadsOneRevision() async throws {
        let child = try CLIChild(arguments: ["--stdio"])
        let listed = try await child.exchange(Frames.list(id: 1))
        let tools = try #require(listed.objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        #expect(Set(tools.compactMap { $0.objectValue?["name"]?.stringValue })
            == ["search_articles", "get_article_outline", "read_article_section", "get_section_references"])

        let search = try Frames.value(SearchPage.self, await child.exchange(Frames.call("search_articles",
            SearchInput(query: "Riverglass", project: "fixture-enwiki", limit: 10), id: 2)))
        let candidate = try #require(search.candidates.first)
        let outline = try Frames.value(Outline.self, await child.exchange(Frames.call("get_article_outline",
            OutlineInput(project: candidate.project, candidateID: candidate.id), id: 3)))
        let location = try #require(outline.sections.first(where: { $0.location.partID == "p2" })?.location)
        #expect(location.snapshot == outline.snapshot && outline.snapshot.revisionID == "r1")

        let passage = try Frames.value(SectionPassage.self, await child.exchange(Frames.call("read_article_section",
            SectionInput(snapshot: outline.snapshot, part: location, maxTextBytes: 32768), id: 4)))
        let references = try Frames.value(SectionReferences.self, await child.exchange(Frames.call("get_section_references",
            ReferencesInput(snapshot: outline.snapshot, part: location), id: 5)))
        #expect(passage.snapshot == location.snapshot && passage.text.contains("α — π"))
        #expect(references.references.map(\.id) == ["ref-instrument-notes"] && references.unresolvedIDs == ["ref-lost-ledger"])

        // EOF on stdin ends the server cleanly: no extra frames, no diagnostics.
        let end = try await child.finish()
        #expect(end.exit == 0 && end.extraStdoutLines == 0 && end.stderr.isEmpty)
    }

    @Test(arguments: [(["--help"], 0), ([], 64), (["--invalid"], 64)] as [([String], Int32)])
    func modeSelection(arguments: [String], exit: Int32) async throws {
        let child = try CLIChild(arguments: arguments)
        let end = try await child.finish()
        #expect(end.exit == exit && end.extraStdoutLines == 0)
        #expect(end.stderr.hasPrefix("Research Explorer (synthetic fixtures)\n"))
    }
}
