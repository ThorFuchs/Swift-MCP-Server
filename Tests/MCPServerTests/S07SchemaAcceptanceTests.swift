// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

@Suite(.serialized) struct S07SchemaAcceptance {
    @Test func omittedDialectUses202012AndDiscoveryKeepsTheRawSchemas() async throws {
        // Tool arguments require an object root. The nested tuple exercises
        // 2020-12 prefixItems semantics without violating that wire contract.
        let input = try StateFixture.json(#"{"type":"object","properties":{"values":{"type":"array","prefixItems":[{"type":"integer"}],"items":false,"minItems":1}},"required":["values"],"org.example/note":{"kept":null}}"#)
        let output = try StateFixture.json(#"{"type":"null"}"#)
        let definition = try StateFixture.json(#"{"name":"tuple","inputSchema":{"type":"object","properties":{"values":{"type":"array","prefixItems":[{"type":"integer"}],"items":false,"minItems":1}},"required":["values"],"org.example/note":{"kept":null}},"outputSchema":{"type":"null"}}"#)
        let calls = Mutex(0)
        let tool = ToolRegistration(definition: definition) { _, _ in
            calls.withLock { $0 += 1 }
            return try StateFixture.json(#"{"resultType":"complete","content":[],"structuredContent":null}"#)
        }
        let server = try await StateFixture.make(ServerCatalog(tools: [tool]))
        let discovery = try await StateFixture.response(server, StateFixture.request("tools/list"))
        let advertised = try #require(discovery.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.first?.objectValue)
        #expect(advertised["inputSchema"] == input && advertised["outputSchema"] == output)
        #expect(advertised["inputSchema"]?.objectValue?["$schema"] == nil)
        #expect(advertised["inputSchema"]?.objectValue?["org.example/note"]?.objectValue?["kept"]?.isNull == true)
        for arguments in [#"{"values":["bad"]}"#, #"{"values":[7,8]}"#, #"{"values":[]}"#] {
            let rejected = try await StateFixture.response(server, StateFixture.request("tools/call", fields: ",\"name\":\"tuple\",\"arguments\":\(arguments)"))
            #expect(try rejected.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        }
        #expect(calls.withLock { $0 } == 0)
        let accepted = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"tuple","arguments":{"values":[7]}"#))
        #expect(accepted.objectValue?["result"]?.objectValue?["structuredContent"]?.isNull == true)
        #expect(calls.withLock { $0 } == 1)
        await StateFixture.clean(server)
    }

    @Test(arguments: ["null", "false", "9007199254740993", #""scalar""#, "[1,true,null]", #"{"answer":42}"#])
    func outputSchemasValidateEveryJSONValueKindAndRejectTheWrongResult(literal: String) async throws {
        let expected = try StateFixture.json(literal)
        let calls = Mutex(0)
        let definition = try StateFixture.json("{\"name\":\"shape\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{\"const\":\(literal)}}")
        let tool = ToolRegistration(definition: definition) { input, _ in
            calls.withLock { $0 += 1 }
            let bad: Bool
            if case .value(let value) = input { bad = value.objectValue?["wrong"]?.booleanValue == true } else { bad = false }
            // true differs from every positive case, including false and null.
            return try StateFixture.json("{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":\(bad ? "true" : literal)}")
        }
        let server = try await StateFixture.make(ServerCatalog(tools: [tool]))
        let good = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"shape","arguments":{}"#))
        #expect(good.objectValue?["result"]?.objectValue?["structuredContent"] == expected)
        #expect(good.objectValue?["error"] == nil)
        let bad = try await StateFixture.response(server, StateFixture.request("tools/call", fields: #", "name":"shape","arguments":{"wrong":true}"#))
        #expect(try bad.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32603)
        #expect(bad.objectValue?["result"] == nil && calls.withLock { $0 } == 2)
        await StateFixture.clean(server)
    }
}
