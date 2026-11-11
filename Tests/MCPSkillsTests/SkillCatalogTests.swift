// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import JSON
import MCPProtocol
import MCPServer
@testable import MCPSkills
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let reader = VerifiedPrincipal(subject: ScalarText("reader"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [ScalarText("skills")])
private let stranger = VerifiedPrincipal(subject: ScalarText("stranger"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])

/// Requests exactly as the Skills specification shows them: no client extension declaration.
private func request(_ method: String, id: Int, fields: String = "") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}\(fields)}}".utf8)
}
private func respond(_ server: Server, _ data: Data, as principal: VerifiedPrincipal = reader) async throws -> JSON {
    try json(String(decoding: #require(await server.handle(data, principal: principal, origin: ScalarText("host"))), as: UTF8.self))
}
private func code(_ value: JSON) -> Int? { try? value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) }
private func result(_ value: JSON) -> JSONObject? { value.objectValue?["result"]?.objectValue }
private func integer(_ value: JSON?) -> Int? { try? value?.numberValue?.integer(as: Int.self, limits: .balanced) }

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
allowed-tools: [lookup_order, "issue_refund"]
---
# Refunds

See [the email template](examples/email.md).
"""
private let workflow = "---\nname: git-workflow\ndescription: 'Follow this team''s Git conventions'\n---\nUse feature branches.\n"
private let chargebacks = "---\nname: chargebacks\ndescription: Dispute handling\n---\nNested skill.\n"

private func sources() -> [SkillSource] {
    [SkillSource(path: "acme/billing/refunds", files: [
        SkillFile(path: "SKILL.md", text: refunds),
        SkillFile(path: "examples/email.md", text: "Dear customer,\n"),
        SkillFile(path: "scripts/run.bin", contents: [0, 159, 146, 150]),
        SkillFile(path: "chargebacks/SKILL.md", text: chargebacks),
     ]),
     SkillSource(path: "acme/billing/refunds/chargebacks", files: [SkillFile(path: "SKILL.md", text: chargebacks)]),
     SkillSource(path: "git-workflow", files: [SkillFile(path: "SKILL.md", text: workflow)])]
}

private func makeServer(_ catalog: SkillCatalog) async throws -> Server {
    try await Server.make(info: json(#"{"name":"skills","version":"1"}"#),
        catalog: ServerCatalog(resources: catalog.resources(), extensions: [catalog.registration()]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 2, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
}

@Suite struct FrontmatterCases {
    @Test func agentSkillsFrontmatterParsesToTheAuthorsValues() throws {
        let value = try Frontmatter.parse(refunds)
        #expect(value["name"]?.string == "refunds")
        #expect(value["description"]?.string == "Process customer refund requests per company policy\n")
        #expect(value["license"]?.string == "Apache-2.0")
        #expect(value["metadata"]?["owner"]?.string == "billing-team" && value["metadata"]?["version"]?.string == "1.0")
        #expect(value["allowed-tools"] == .sequence([.string("lookup_order"), .string("issue_refund")]))
        let scalars = try Frontmatter.parse("---\nname: x\ndescription: |-\n  line one\n  line two\ncount: 3\nratio: 0.5\nflag: true\nnothing:\nlist:\n  - a\n  - 'b'\n---\n")
        #expect(scalars["description"]?.string == "line one\nline two")
        #expect(scalars["count"] == .integer(3) && scalars["ratio"] == .double(0.5) && scalars["flag"] == .boolean(true) && scalars["nothing"] == .null)
        #expect(scalars["list"] == .sequence([.string("a"), .string("b")]))
    }

    @Test(arguments: [
        "name: x",                                         // no opening delimiter
        "---\nname: x\n",                                   // not closed
        "---\nname: &a x\n---\n",                           // anchor
        "---\nname: x\nname: y\n---\n",                     // duplicate key
        "---\nmeta: {a: 1}\n---\n",                         // flow mapping
        "---\nname: x\n\tdescription: y\n---\n",            // tab indentation
        "---\nlist:\n  - key: value\n---\n",                // mapping in sequence
        "---\nvalue: 0x1F\n---\n",                          // non-decimal number
        "---\nvalue: \"unterminated\n---\n",               // multi-line quoted scalar
    ])
    func unsupportedOrInvalidYAMLIsRejectedNotGuessed(_ text: String) {
        #expect(throws: Frontmatter.Failure.self) { try Frontmatter.parse(text) }
    }
}

@Suite struct CatalogValidationCases {
    @Test func skillsThatBreakTheSpecificationAreRejectedWhenTheCatalogIsBuilt() throws {
        func rejects(_ source: SkillSource) { #expect(throws: SkillDefinitionError.self) { try SkillCatalog([source]) } }
        rejects(SkillSource(path: "no-manifest", files: [SkillFile(path: "README.md", text: "x")]))
        rejects(SkillSource(path: "other-name", files: [SkillFile(path: "SKILL.md", text: workflow)]))
        rejects(SkillSource(path: "Bad--Name", files: [SkillFile(path: "SKILL.md", text: "---\nname: Bad--Name\ndescription: d\n---\n")]))
        rejects(SkillSource(path: "empty-description", files: [SkillFile(path: "SKILL.md", text: "---\nname: empty-description\ndescription: \"\"\n---\n")]))
        rejects(SkillSource(path: "reserved", files: [SkillFile(path: "SKILL.md",
            text: "---\nname: reserved\ndescription: d\nmetadata:\n  io.modelcontextprotocol/x: y\n---\n")]))
        rejects(SkillSource(path: "escape", files: [SkillFile(path: "SKILL.md", text: "---\nname: escape\ndescription: d\n---\n"),
                                                    SkillFile(path: "../secret", text: "x")]))
        rejects(SkillSource(path: "too-many", files: [SkillFile(path: "SKILL.md", text: "---\nname: too-many\ndescription: d\n---\n")]
            + (0..<512).map { SkillFile(path: "f\($0).txt", text: "x") }))
        rejects(SkillSource(path: "too-big", files: [SkillFile(path: "SKILL.md", text: "---\nname: too-big\ndescription: d\n---\n"),
                                                     SkillFile(path: "big.bin", contents: [UInt8](repeating: 0, count: 16 * 1024 * 1024))]))
        // Completeness extends to nested skills: the enclosing skill must list their files.
        #expect(throws: SkillDefinitionError.self) {
            try SkillCatalog([SkillSource(path: "outer", files: [SkillFile(path: "SKILL.md", text: "---\nname: outer\ndescription: d\n---\n")]),
                              SkillSource(path: "outer/inner", files: [SkillFile(path: "SKILL.md", text: "---\nname: inner\ndescription: d\n---\n")])])
        }
    }

    @Test func directoriesAreLoadedWithNestedSkillsAndWithoutHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("refunds/SKILL.md", refunds)
        try write("refunds/examples/email.md", "Dear customer,\n")
        try write("refunds/chargebacks/SKILL.md", chargebacks)
        try write("refunds/.DS_Store", "ignored")
        let catalog = try SkillCatalog.load(directory: root, prefix: "acme/billing")
        #expect(catalog.skills.map(\.uri) == ["skill://acme/billing/refunds/SKILL.md", "skill://acme/billing/refunds/chargebacks/SKILL.md"].sorted())
        #expect(catalog.files.keys.contains { $0.hasSuffix(".DS_Store") } == false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("refunds/link.md"), withDestinationURL: root.appendingPathComponent("refunds/SKILL.md"))
        #expect(throws: SkillDefinitionError.self) { try SkillCatalog.load(directory: root) }
    }
}

@Suite(.serialized) struct SkillProtocolCases {
    @Test func listedManifestsMatchTheBytesResourcesReadServes() async throws {
        let catalog = try SkillCatalog(sources())
        let server = try await makeServer(catalog)
        // Declared in server/discover with directoryRead, alongside the resources capability.
        let discovered = try #require(result(try await respond(server, request("server/discover", id: 1))))
        let capabilities = discovered["capabilities"]?.objectValue
        #expect(capabilities?["extensions"]?.objectValue?["io.modelcontextprotocol/skills"]?.objectValue?["directoryRead"]?.booleanValue == true)
        #expect(capabilities?["resources"] != nil)

        let listed = try #require(result(try await respond(server, request("skills/list", id: 2))))
        #expect(listed["resultType"]?.stringValue == "complete" && integer(listed["ttlMs"]) == 300_000 && listed["cacheScope"]?.stringValue == "public")
        let skills = try #require(listed["skills"]?.arrayValue)
        #expect(skills.compactMap { $0.objectValue?["uri"]?.stringValue } == [
            "skill://acme/billing/refunds/SKILL.md", "skill://acme/billing/refunds/chargebacks/SKILL.md", "skill://git-workflow/SKILL.md"])
        let entry = try #require(skills.first?.objectValue)
        let frontmatter = try #require(entry["frontmatter"]?.objectValue)
        #expect(frontmatter["name"]?.stringValue == "refunds" && frontmatter["license"]?.stringValue == "Apache-2.0")
        #expect(frontmatter["allowed-tools"]?.arrayValue?.count == 2)
        let resources = (try #require(entry["resources"]?.arrayValue)).compactMap { $0.objectValue }
        #expect(resources.count == 4)
        var id = 10
        for resource in resources {
            id += 1
            let uri = try #require(resource["uri"]?.stringValue)
            let read = try #require(result(try await respond(server, request("resources/read", id: id, fields: ", \"uri\":\"\(uri)\""))))
            let content = try #require(read["contents"]?.arrayValue?.first?.objectValue)
            let bytes: [UInt8]
            if let text = content["text"]?.stringValue { bytes = Array(text.utf8) }
            else {
                let blob = try #require(content["blob"]?.stringValue)
                bytes = Array(try #require(Data(base64Encoded: blob)))
            }
            // Hosts verify every file against the entry: digest and size of the raw bytes.
            #expect(resource["digest"]?.stringValue == "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            #expect(integer(resource["size"]) == bytes.count)
        }
        // The SKILL.md resource carries the frontmatter name and description as metadata.
        let page = try #require(result(try await respond(server, request("resources/list", id: 30))))
        let manifest = page["resources"]?.arrayValue?.compactMap(\.objectValue).first { $0["uri"]?.stringValue == "skill://acme/billing/refunds/SKILL.md" }
        #expect(manifest?["name"]?.stringValue == "refunds" && manifest?["mimeType"]?.stringValue == "text/markdown")
        #expect(manifest?["description"]?.stringValue == "Process customer refund requests per company policy\n")
    }

    @Test func getAnswersForEveryServedSkillAndRejectsOthers() async throws {
        let server = try await makeServer(try SkillCatalog(sources()))
        let found = try #require(result(try await respond(server, request("skills/get", id: 1, fields: #", "uri":"skill://git-workflow/SKILL.md""#))))
        #expect(found["skill"]?.objectValue?["frontmatter"]?.objectValue?["description"]?.stringValue == "Follow this team's Git conventions")
        #expect(found["nextCursor"] == nil && found["ttlMs"] != nil && found["cacheScope"] != nil)
        for uri in ["skill://acme/billing/chargebacks/SKILL.md", "skill://git-workflow", "skill://acme/billing/refunds/examples/email.md"] {
            #expect(code(try await respond(server, request("skills/get", id: 2, fields: ", \"uri\":\"\(uri)\""))) == -32602)
        }
    }

    @Test func directoriesListDirectChildrenAtEveryLevel() async throws {
        let server = try await makeServer(try SkillCatalog(sources()))
        func children(_ uri: String) async throws -> [(String, String?)] {
            let page = try #require(result(try await respond(server, request("resources/directory/read", id: 1, fields: ", \"uri\":\"\(uri)\""))))
            #expect(page["ttlMs"] != nil && page["cacheScope"] != nil)
            return (page["resources"]?.arrayValue ?? []).compactMap(\.objectValue).map { ($0["uri"]?.stringValue ?? "", $0["mimeType"]?.stringValue) }
        }
        let skillRoot = try await children("skill://acme/billing/refunds")
        #expect(skillRoot.map(\.0) == ["skill://acme/billing/refunds/SKILL.md", "skill://acme/billing/refunds/chargebacks",
                                       "skill://acme/billing/refunds/examples", "skill://acme/billing/refunds/scripts"])
        #expect(skillRoot.first { $0.0.hasSuffix("/examples") }?.1 == "inode/directory")
        #expect(try await children("skill://acme").map(\.0) == ["skill://acme/billing"])
        #expect(try await children("skill://acme/billing/refunds/examples").map(\.1) == ["text/markdown"])
        for uri in ["skill://acme/billing/refunds/SKILL.md", "skill://missing", "skill://acme/billing/refunds/"] {
            #expect(code(try await respond(server, request("resources/directory/read", id: 2, fields: ", \"uri\":\"\(uri)\""))) == -32602)
        }
    }

    @Test func listingPagesAreAtomicAndCursorsAreChecked() async throws {
        let server = try await makeServer(try SkillCatalog(sources(), configuration: .init(pageSize: 1)))
        var uris: [String] = [], cursor: String?, id = 0
        repeat {
            id += 1
            let fields = cursor.map { ", \"cursor\":\"\($0)\"" } ?? ""
            let page = try #require(result(try await respond(server, request("skills/list", id: id, fields: fields))))
            let skills = try #require(page["skills"]?.arrayValue)
            #expect(skills.count == 1)
            // A skill's resources set is never split across pages.
            #expect(skills.allSatisfy { $0.objectValue?["resources"]?.arrayValue?.isEmpty == false })
            uris += skills.compactMap { $0.objectValue?["uri"]?.stringValue }
            cursor = page["nextCursor"]?.stringValue
        } while cursor != nil
        #expect(uris.count == 3 && Set(uris).count == 3)
        for bad in ["0", "3", "-1", "abc"] {
            #expect(code(try await respond(server, request("skills/list", id: 99, fields: ", \"cursor\":\"\(bad)\""))) == -32602)
        }
    }

    @Test func requiredScopesProtectMethodsAndFiles() async throws {
        let catalog = try SkillCatalog(sources(), configuration: .init(requiredScopes: [ScalarText("skills")]))
        let server = try await makeServer(catalog)
        #expect(result(try await respond(server, request("skills/list", id: 1))) != nil)
        // Missing scopes are access failures the transport answers (HTTP 403), not JSON-RPC results.
        await #expect(throws: CoreFailure.insufficientScopes) { _ = try await respond(server, request("skills/list", id: 2), as: stranger) }
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await respond(server, request("resources/read", id: 3, fields: #", "uri":"skill://git-workflow/SKILL.md""#), as: stranger)
        }
        // Scoped catalogs default to private caching.
        #expect(result(try await respond(server, request("skills/list", id: 4)))?["cacheScope"]?.stringValue == "private")
    }
}
