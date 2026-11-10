// SPDX-License-Identifier: Apache-2.0
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private struct S08Contents: Encodable, Sendable {
    struct Item: Encodable, Sendable { let uri: String; let text: String }
    let resultType = "complete"
    let contents: [Item]
}
private struct S08Arguments: Decodable, Sendable { let name: String? }
private struct S08PromptResult: Encodable, Sendable {
    struct Text: Encodable, Sendable { let type = "text"; let text: String }
    struct Message: Encodable, Sendable { let role = "user"; let content: Text }
    let resultType = "complete"
    let messages: [Message]
}

@Suite(.serialized) struct S08TypedRegistration {
    @Test func typedResourcesAndTemplatesRetainURIAndAuthorizeBeforeEffects() async throws {
        let calls = Mutex([String]())
        let direct = ResourceProvider.typed(definition: try StateFixture.json(#"{"name":"direct","uri":"fixture://direct"}"#), requiredScopes: [ScalarText("read")]) { uri, context in
            #expect(context.principal.scopes.contains(ScalarText("read")))
            calls.withLock { $0.append(uri) }
            return S08Contents(contents: [.init(uri: uri, text: "direct")])
        }
        let template = ResourceTemplateProvider.typed(definition: try StateFixture.json(#"{"name":"template","uriTemplate":"fixture://item/{id}"}"#),
            matches: { uri, _ in uri.hasPrefix("fixture://item/") }) { uri, _ in
            calls.withLock { $0.append(uri) }
            return S08Contents(contents: [.init(uri: uri, text: "template")])
        }
        let server = try await StateFixture.make(ServerCatalog(resources: [direct], templates: [template]))
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://direct""#))
        }
        #expect(calls.withLock { $0 }.isEmpty)
        let p = StateFixture.principal
        let reader = VerifiedPrincipal(subject: p.subject, issuer: p.issuer, resource: p.resource, scopes: [ScalarText("read")])
        let a = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://direct""#), principal: reader)
        let b = try await StateFixture.response(server, StateFixture.request("resources/read", fields: #", "uri":"fixture://item/42""#))
        #expect(a.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first?.objectValue?["uri"]?.stringValue == "fixture://direct")
        #expect(b.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first?.objectValue?["uri"]?.stringValue == "fixture://item/42")
        #expect(calls.withLock { $0 } == ["fixture://direct", "fixture://item/42"])
        await StateFixture.clean(server)
    }

    @Test func typedPromptDecodesAbsentAndSuppliedArgumentsOnTheRequestAccount() async throws {
        let calls = Mutex(0)
        let prompt = PromptProvider.typed(definition: try StateFixture.json(#"{"name":"greet","arguments":[{"name":"name"}]}"#), input: S08Arguments.self) { args, context in
            calls.withLock { $0 += 1 }
            #expect(await context.budget.snapshot.settledWork > 0)
            return S08PromptResult(messages: [.init(content: .init(text: args.name ?? "anonymous"))])
        }
        let server = try await StateFixture.make(ServerCatalog(prompts: [prompt]))
        let empty = try await StateFixture.response(server, StateFixture.request("prompts/get", fields: #", "name":"greet""#))
        let named = try await StateFixture.response(server, StateFixture.request("prompts/get", fields: #", "name":"greet", "arguments":{"name":"Ada"}"#))
        #expect(empty.objectValue?["result"]?.objectValue?["messages"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.stringValue == "anonymous")
        #expect(named.objectValue?["result"]?.objectValue?["messages"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.stringValue == "Ada")
        #expect(calls.withLock { $0 } == 2)
        await StateFixture.clean(server)
    }

    @Test func invalidTypedResultAndTerminatedAccountCannotBecomeSuccess() async throws {
        struct Bad: Encodable, Sendable { let unexpected = true }
        let bad = ResourceProvider.typed(definition: try StateFixture.json(#"{"name":"bad","uri":"fixture://bad"}"#)) { _, _ in Bad() }
        let poison = ResourceProvider.typed(definition: try StateFixture.json(#"{"name":"poison","uri":"fixture://poison"}"#)) { uri, context in
            await context.budget.terminate()
            return S08Contents(contents: [.init(uri: uri, text: "must not succeed")])
        }
        let server = try await StateFixture.make(ServerCatalog(resources: [bad, poison]))
        for uri in ["fixture://bad", "fixture://poison"] {
            let value = try await StateFixture.response(server, StateFixture.request("resources/read", fields: ",\"uri\":\"\(uri)\""))
            #expect(value.objectValue?["error"] != nil && value.objectValue?["result"] == nil)
            await StateFixture.clean(server)
        }
    }
}
