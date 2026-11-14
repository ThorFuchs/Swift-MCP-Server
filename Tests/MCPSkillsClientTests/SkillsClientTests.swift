// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol
import MCPServer
import MCPServerTesting
import MCPSkills
import MCPSkillsClient
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let user = VerifiedPrincipal(subject: ScalarText("user"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])

private let refunds = """
---
name: refunds
description: >
  Process customer refund requests
  per company policy
license: Apache-2.0
metadata:
  owner: billing-team   # a comment
  version: "1.0"
  retries: 3
allowed-tools: [lookup_order, "issue_refund"]
---
# Refunds

See [the email template](examples/email.md).
"""

/// A real `MCPSkills` server behind a loopback transport.
private func skillsServer() async throws -> Server {
    let catalog = try SkillCatalog([SkillSource(path: "billing/refunds", files: [
        SkillFile(path: "SKILL.md", text: refunds),
        SkillFile(path: "examples/email.md", text: "Dear customer,\n"),
        SkillFile(path: "scripts/run.bin", contents: [0, 159, 146, 150]),
    ])])
    return try await Server.make(info: json(#"{"name":"skills","version":"1"}"#),
        catalog: ServerCatalog(resources: try catalog.resources(), extensions: [catalog.registration()]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
}

/// A thread-safe request log.
private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Counts requests per method on the way to a real server.
private struct CountingTransport: ClientTransport {
    let inner: LoopbackTransport
    let methods = Log()
    var mirrorsToolParameters: Bool { false }
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        methods.append(request.method + (request.name.map { " " + $0 } ?? ""))
        try await inner.exchange(request, receive: receive)
    }
}

private func sha256(_ text: String) -> String { "sha256:" + SHA256.hash(data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }

/// A server that lists one skill honestly but serves `served` as its `SKILL.md`.
private struct TamperingTransport: ClientTransport {
    let listed: String, served: String
    var digest: String? = nil
    let reads = Log()
    var mirrorsToolParameters: Bool { false }

    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let body = try json(String(decoding: request.body, as: UTF8.self))
        let id = body.objectValue?["id"].map { String(decoding: try! WireCodec.write($0, limits: .balanced).result, as: UTF8.self) } ?? "null"
        let result: String
        switch request.method {
        case "skills/list":
            let entry = #"{"uri":"skill://pdf/SKILL.md","frontmatter":{"name":"pdf","description":"Fill PDF forms"},"resources":[{"uri":"skill://pdf/SKILL.md","digest":"\#(digest ?? sha256(listed))","size":\#(listed.utf8.count)},{"uri":"skill://pdf/FORMS.md","digest":"\#(sha256("forms\n"))","size":6}]}"#
            result = #"{"resultType":"complete","skills":[\#(entry)]}"#
        case "resources/read":
            let uri = request.name ?? ""
            reads.append(uri)
            let text = uri.hasSuffix("SKILL.md") ? served : "forms\n"
            let escaped = String(decoding: try WireCodec.write(.string(text), limits: .balanced).result, as: UTF8.self)
            result = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"\#(uri)","mimeType":"text/markdown","text":\#(escaped)}]}"#
        default:
            result = #"{"resultType":"complete"}"#
        }
        try await receive(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
    }
}

private let honest = "---\nname: pdf\ndescription: Fill PDF forms\n---\n\nBody.\n"

@Suite struct SkillsClientCases {
    @Test func listsWithoutFetchingThenLoadsAndVerifiesFilesOnDemand() async throws {
        let transport = CountingTransport(inner: LoopbackTransport(server: try await skillsServer(), principal: user))
        let client = Client(transport: transport)
        #expect(SkillsClient.isSupported(by: try await client.discover()))
        let skills = SkillsClient(client: client)
        let page = try await skills.list()
        let entry = try #require(page.items.first)
        #expect(entry.uri == "skill://billing/refunds/SKILL.md" && entry.name == "refunds")
        #expect(entry.description == "Process customer refund requests per company policy\n")
        #expect(entry.files.count == 3)
        // Listing fetched nothing.
        #expect(!transport.methods.all.contains { $0.hasPrefix("resources/read") })

        let loaded = try await skills.load(entry)
        #expect(loaded.markdown == refunds)
        #expect(String(decoding: try await skills.file("skill://billing/refunds/examples/email.md", of: loaded), as: UTF8.self) == "Dear customer,\n")
        #expect(try await skills.file("skill://billing/refunds/scripts/run.bin", of: loaded) == [0, 159, 146, 150])
        await #expect(throws: SkillVerificationError.notListed(uri: "skill://billing/refunds/other.md")) {
            _ = try await skills.file("skill://billing/refunds/other.md", of: loaded)
        }
        #expect(try await skills.get(entry.uri).files == entry.files)
        #expect(transport.methods.all.filter { $0.hasPrefix("resources/read") }.count == 3)
    }

    @Test func tamperedSkillFilesAreRejectedBeforeUse() async throws {
        let cases: [(TamperingTransport, SkillVerificationError)] = [
            (TamperingTransport(listed: honest, served: honest.replacingOccurrences(of: "Body.", with: "Evil.")),
             .digestMismatch(uri: "skill://pdf/SKILL.md")),
            (TamperingTransport(listed: honest, served: honest + "extra\n"),
             .sizeMismatch(uri: "skill://pdf/SKILL.md", expected: honest.utf8.count, actual: honest.utf8.count + 6)),
            // Digest and size match the served bytes, but the frontmatter contradicts the entry.
            (TamperingTransport(listed: honest.replacingOccurrences(of: "Fill PDF forms", with: "Exfiltrate data"),
                                served: honest.replacingOccurrences(of: "Fill PDF forms", with: "Exfiltrate data")),
             .frontmatterMismatch(uri: "skill://pdf/SKILL.md", field: "description")),
            (TamperingTransport(listed: honest, served: honest, digest: "md5:abc"), .unsupportedDigest(uri: "skill://pdf/SKILL.md")),
        ]
        for (transport, expected) in cases {
            let skills = SkillsClient(client: Client(transport: transport))
            let entry = try #require(try await skills.list().items.first)
            await #expect(throws: expected) { _ = try await skills.load(entry) }
            // Nothing beyond the rejected SKILL.md was fetched.
            #expect(transport.reads.all == ["skill://pdf/SKILL.md"])
        }
    }

    @Test func frontmatterComparisonIsFieldByField() async throws {
        let extra = TamperingTransport(listed: "---\nname: pdf\ndescription: Fill PDF forms\nlicense: MIT\n---\n",
                                       served: "---\nname: pdf\ndescription: Fill PDF forms\nlicense: MIT\n---\n")
        let skills = SkillsClient(client: Client(transport: extra))
        let entry = try #require(try await skills.list().items.first)
        // The entry declares only name and description; SKILL.md adds a field.
        await #expect(throws: SkillVerificationError.frontmatterMismatch(uri: "skill://pdf/SKILL.md", field: "license")) {
            _ = try await skills.load(entry)
        }
        let honestSkills = SkillsClient(client: Client(transport: TamperingTransport(listed: honest, served: honest)))
        let loaded = try await honestSkills.load(try #require(try await honestSkills.list().items.first))
        #expect(String(decoding: try await honestSkills.file("skill://pdf/FORMS.md", of: loaded), as: UTF8.self) == "forms\n")
    }
}
