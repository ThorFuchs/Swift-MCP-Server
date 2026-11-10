// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

// Authored RC1-S07 acceptance, not compiled or run. These use the public server
// boundary; retained URI-template corpus and real HTTP tests stay separate.
@Suite(.serialized) struct S07CatalogAcceptance {
    @Test func resourceMetadataUsesRawBytesAndLeavesUnknownMetadataAbsent() async throws {
        let bytes = Data([0, 255, 128]), text = "é🧪"
        let binary = ResourceProvider(definition: try StateFixture.json(
            #"{"name":"binary","uri":"fixture://binary","size":3,"mimeType":"application/octet-stream"}"#)) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[{"uri":"fixture://binary","mimeType":"application/octet-stream","blob":"AP+A"}]}"#)
        }
        let textual = ResourceProvider(definition: try StateFixture.json(
            #"{"name":"text","uri":"fixture://text","size":6,"mimeType":"text/plain"}"#)) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[{"uri":"fixture://text","mimeType":"text/plain","text":"é🧪"}]}"#)
        }
        let unknown = ResourceProvider(definition: try StateFixture.json(
            #"{"name":"unknown","uri":"fixture://unknown"}"#)) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[{"uri":"fixture://unknown","text":"dynamic"}]}"#)
        }
        let server = try await StateFixture.make(ServerCatalog(resources: [unknown, textual, binary]))
        let listed = try #require(await StateFixture.response(server, StateFixture.request("resources/list"))
            .objectValue?["result"]?.objectValue?["resources"]?.arrayValue)
        let binaryDefinition = try #require(listed.first { $0.objectValue?["name"]?.stringValue == "binary" })
        let textDefinition = try #require(listed.first { $0.objectValue?["name"]?.stringValue == "text" })
        let unknownDefinition = try #require(listed.first { $0.objectValue?["name"]?.stringValue == "unknown" })
        #expect(try binaryDefinition.objectValue?["size"]?.numberValue?.integer(as: Int.self, limits: .balanced) == bytes.count)
        #expect(try textDefinition.objectValue?["size"]?.numberValue?.integer(as: Int.self, limits: .balanced) == text.utf8.count)
        #expect(unknownDefinition.objectValue?["size"] == nil && unknownDefinition.objectValue?["mimeType"] == nil)
        let binaryRead = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://binary""#))
        let binaryContent = try #require(binaryRead.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first)
        let encoded = try #require(binaryContent.objectValue?["blob"]?.stringValue)
        #expect(encoded.utf8.count == 4 && Data(base64Encoded: encoded) == bytes)
        #expect(binaryContent.objectValue?["mimeType"]?.stringValue == "application/octet-stream")
        let textRead = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://text""#))
        let textContent = try #require(textRead.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first)
        #expect(textContent.objectValue?["text"]?.stringValue == text && text.utf8.count == 6)
        #expect(textContent.objectValue?["mimeType"]?.stringValue == "text/plain")
        // The host advertises known sizes. The SDK preserves optional metadata;
        // it does not fetch resources to compute size or invent an unknown size.
        await StateFixture.clean(server)
    }

    @Test func templateAuthorizationPrecedesMatcherAndPreservesSelectedURI() async throws {
        let matches = Mutex(0), reads = Mutex(0)
        let template = ResourceTemplateProvider(definition: try StateFixture.json(
            #"{"name":"private-template","uriTemplate":"fixture://private/{id}","mimeType":"text/plain"}"#),
            requiredScopes: [ScalarText("read")], matches: { uri, _ in
                matches.withLock { $0 += 1 }; return uri == "fixture://private/42"
            }) { input, context in
                reads.withLock { $0 += 1 }
                guard case .value(let uri) = input else { throw CoreFailure.invalidInput }
                #expect(uri.stringValue == "fixture://private/42")
                #expect(context.principal.scopes.contains(ScalarText("read")))
                return try StateFixture.json(#"{"resultType":"complete","contents":[{"uri":"fixture://private/42","mimeType":"text/plain","text":"authorized"}]}"#)
            }
        let server = try await StateFixture.make(ServerCatalog(templates: [template]))
        let deniedList = try await StateFixture.response(server, StateFixture.request("resources/templates/list"))
        #expect(deniedList.objectValue?["result"]?.objectValue?["resourceTemplates"]?.arrayValue?.isEmpty == true)
        let deniedRead = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://private/42""#))
        #expect(try deniedRead.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(matches.withLock { $0 } == 0 && reads.withLock { $0 } == 0)
        let reader = VerifiedPrincipal(subject: StateFixture.principal.subject, issuer: StateFixture.principal.issuer,
            resource: StateFixture.principal.resource, scopes: [ScalarText("read")])
        let listed = try await StateFixture.response(server, StateFixture.request("resources/templates/list"), principal: reader)
        #expect(listed.objectValue?["result"]?.objectValue?["resourceTemplates"]?.arrayValue?.first?.objectValue?["uriTemplate"]?.stringValue == "fixture://private/{id}")
        let accepted = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://private/42""#), principal: reader)
        #expect(accepted.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first?.objectValue?["uri"]?.stringValue == "fixture://private/42")
        #expect(matches.withLock { $0 } == 1 && reads.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }

    @Test(arguments: ["bad!", "YQ==\n", "YR=="])
    func invalidBinaryAndMissingResourceHaveDifferentErrors(blob: String) async throws {
        // Invalid alphabet, line break and noncanonical padding bits. The JSON
        // encoder escapes the line break, so each reaches the provider result.
        struct Content: Encodable { let uri = "fixture://bad"; let blob: String }
        struct Output: Encodable { let resultType = "complete"; let contents: [Content] }
        let output = try JSONValueEncoder().encodeWithReport(Output(contents: [Content(blob: blob)])).result
        let calls = Mutex(0)
        let resource = ResourceProvider(definition: try StateFixture.json(#"{"name":"bad","uri":"fixture://bad"}"#)) { _, _ in
            calls.withLock { $0 += 1 }; return output
        }
        let server = try await StateFixture.make(ServerCatalog(resources: [resource]))
        let invalid = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://bad""#))
        #expect(try invalid.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32603)
        #expect(invalid.objectValue?["result"] == nil && calls.withLock { $0 } == 1)
        let absent = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://missing""#))
        #expect(try absent.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(absent.objectValue?["result"] == nil && calls.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }

    @Test func privateReadOverridesProviderHintsAndReauthorizesEachRequest() async throws {
        let subjects = Mutex([String]())
        let resource = ResourceProvider(definition: try StateFixture.json(#"{"name":"private","uri":"fixture://private"}"#),
            requiredScopes: [ScalarText("read")]) { _, context in
                let subject = context.principal.subject.description
                subjects.withLock { $0.append(subject) }
                struct Content: Encodable { let uri = "fixture://private"; let text: String }
                struct Output: Encodable {
                    let resultType = "complete"; let contents: [Content]
                    let ttlMs = 999; let cacheScope = "public"
                }
                return try JSONValueEncoder().encodeWithReport(Output(contents: [Content(text: subject)])).result
            }
        let server = try await StateFixture.make(ServerCatalog(resources: [resource], cache: CacheHints(ttlMilliseconds: 42)))
        for name in ["alice", "bob"] {
            let reader = VerifiedPrincipal(subject: ScalarText(name), issuer: StateFixture.principal.issuer,
                resource: StateFixture.principal.resource, scopes: [ScalarText("read")])
            let response = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://private""#), principal: reader)
            let result = try #require(response.objectValue?["result"]?.objectValue)
            #expect(result["contents"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == name)
            #expect(result["cacheScope"]?.stringValue == "private")
            #expect(try result["ttlMs"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 42)
        }
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://private""#))
        }
        #expect(subjects.withLock { $0 } == ["alice", "bob"])
        await StateFixture.clean(server)
    }

    @Test func privatePagesKeepScopeAndRejectForeignOrChangedAuthorization() async throws {
        let resources = try ["a", "b", "c"].map { name in
            ResourceProvider(definition: try StateFixture.json("{\"name\":\"\(name)\",\"uri\":\"fixture://\(name)\"}"),
                requiredScopes: name == "c" ? [ScalarText("read")] : []) { _, _ in
                try StateFixture.json(#"{"resultType":"complete","contents":[]}"#)
            }
        }
        let server = try await StateFixture.make(ServerCatalog(resources: resources, cache: CacheHints(ttlMilliseconds: 42)),
            configuration: ServerConfiguration(pageEntries: 1))
        let reader = VerifiedPrincipal(subject: StateFixture.principal.subject, issuer: StateFixture.principal.issuer,
            resource: StateFixture.principal.resource, scopes: [ScalarText("read")])
        let first = try #require(await StateFixture.response(server, StateFixture.request("resources/list"), principal: reader).objectValue?["result"]?.objectValue)
        let cursor = try #require(first["nextCursor"]?.stringValue)
        for changed in [StateFixture.principal,
            VerifiedPrincipal(subject: ScalarText("bob"), issuer: reader.issuer, resource: reader.resource, scopes: reader.scopes)] {
            let denied = try await StateFixture.response(server, StateFixture.request("resources/list", fields: ",\"cursor\":\"\(cursor)\""), principal: changed)
            #expect(try denied.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        }
        var page = first, names = [String]()
        // Three resources give a finite page bound; no unbounded cursor loop.
        for index in 0..<3 {
            #expect(page["cacheScope"]?.stringValue == "private")
            #expect(try page["ttlMs"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 42)
            let entry = try #require(page["resources"]?.arrayValue?.first?.objectValue?["name"]?.stringValue)
            names.append(entry)
            if index < 2 {
                let next = try #require(page["nextCursor"]?.stringValue)
                page = try #require(await StateFixture.response(server, StateFixture.request("resources/list", fields: ",\"cursor\":\"\(next)\""), principal: reader).objectValue?["result"]?.objectValue)
            } else { #expect(page["nextCursor"] == nil) }
        }
        #expect(names == ["a", "b", "c"])
        // Revoked identity gets a fresh filtered list; a previous positive TTL
        // never grants access or restores its old cursor authorization context.
        let revoked = try await StateFixture.response(server, StateFixture.request("resources/list"))
        #expect(revoked.objectValue?["result"]?.objectValue?["resources"]?.arrayValue?.first?.objectValue?["name"]?.stringValue == "a")
        let revokedCursor = try #require(revoked.objectValue?["result"]?.objectValue?["nextCursor"]?.stringValue)
        let revokedLast = try await StateFixture.response(server, StateFixture.request("resources/list", fields: ",\"cursor\":\"\(revokedCursor)\""))
        #expect(revokedLast.objectValue?["result"]?.objectValue?["resources"]?.arrayValue?.first?.objectValue?["name"]?.stringValue == "b")
        #expect(revokedLast.objectValue?["result"]?.objectValue?["nextCursor"] == nil)
        #expect(revokedLast.objectValue?["result"]?.objectValue?["cacheScope"]?.stringValue == "private")
        try await server.replaceCatalog(ServerCatalog(resources: resources))
        let stale = try await StateFixture.response(server, StateFixture.request("resources/list", fields: ",\"cursor\":\"\(cursor)\""), principal: reader)
        #expect(try stale.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        await StateFixture.clean(server)
    }

    @Test func publicCacheOptInIsForPrincipalIndependentUnpaginatedData() async throws {
        let resource = ResourceProvider(definition: try StateFixture.json(#"{"name":"public","uri":"fixture://public"}"#)) { _, _ in
            try StateFixture.json(#"{"resultType":"complete","contents":[{"uri":"fixture://public","text":"same for everyone"}]}"#)
        }
        let server = try await StateFixture.make(ServerCatalog(resources: [resource], cache: CacheHints(ttlMilliseconds: 42, scope: .public)))
        let bob = VerifiedPrincipal(subject: ScalarText("bob"), issuer: StateFixture.principal.issuer, resource: StateFixture.principal.resource, scopes: [])
        // All six cache-bearing methods. Public policy is deliberately limited
        // to data independent of principal and without principal-bound cursors.
        for method in ["server/discover", "tools/list", "resources/list", "resources/templates/list", "prompts/list", "resources/read"] {
            let fields = method == "resources/read" ? #", "uri":"fixture://public""# : ""
            let aliceResult = try #require(await StateFixture.response(server, StateFixture.request(method, fields: fields)).objectValue?["result"])
            let bobResult = try #require(await StateFixture.response(server, StateFixture.request(method, fields: fields), principal: bob).objectValue?["result"])
            #expect(aliceResult == bobResult)
            #expect(aliceResult.objectValue?["cacheScope"]?.stringValue == "public")
            #expect(try aliceResult.objectValue?["ttlMs"]?.numberValue?.integer(as: Int.self, limits: .balanced) == 42)
            #expect(aliceResult.objectValue?["nextCursor"] == nil)
        }
        await StateFixture.clean(server)
    }
}
