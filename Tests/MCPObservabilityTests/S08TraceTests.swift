// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPObservability

@Suite(.serialized) struct S08TracePropagation {
    @Test func validatedMetadataIsOptInScopedAndNeverChangesPrincipal() async throws {
        let principal = VerifiedPrincipal(subject: ScalarText("trusted"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
        let calls = Mutex(0)
        let tool = ToolRegistration(definition: try JSONParser().parse(#"{"name":"trace","inputSchema":{"type":"object"}}"#)) { _, context in
            calls.withLock { $0 += 1 }
            #expect(context.principal == principal)
            #expect(context.traceContext?.traceparent == "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01")
            #expect(context.traceContext?.tracestate == "vendor=value")
            #expect(context.traceContext?.baggage == "user=untrusted")
            #expect(RequestTraceScope.current == nil)
            try await RequestTraceScope.withTrace(context) {
                #expect(RequestTraceScope.current?.traceparent == context.traceContext?.traceparent)
                #expect(RequestTraceScope.current?.baggage == "user=untrusted")
                try Task.checkCancellation()
            }
            #expect(RequestTraceScope.current == nil)
            enum FixtureFailure: Error, Equatable { case stop }
            await #expect(throws: FixtureFailure.stop) {
                try await RequestTraceScope.withTrace(context) {
                    #expect(RequestTraceScope.current?.traceparent == context.traceContext?.traceparent)
                    throw FixtureFailure.stop
                }
            }
            #expect(RequestTraceScope.current == nil)
            return try JSONParser().parse(#"{"resultType":"complete","content":[]}"#)
        }
        let info = try JSONParser().parse(#"{"name":"trace-host","version":"1"}"#)
        let cursor = try CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 5, count: 32))], active: ScalarText("test"), clock: { 1000 })
        let server = try await Server.make(info: info, catalog: ServerCatalog(tools: [tool]), cursors: cursor)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"trace","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"traceparent":"00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01","tracestate":"vendor=value","baggage":"user=untrusted"}}}"#.utf8)
        let response = try #require(await server.handle(request, principal: principal, origin: ScalarText("origin")))
        #expect(try JSONParser().parseWithReport(Array(response)).result.objectValue?["result"] != nil)
        #expect(!String(decoding: response, as: UTF8.self).contains("user=untrusted"))
        #expect(calls.withLock { $0 } == 1 && RequestTraceScope.current == nil)
        let activity = await server.activity
        #expect(activity.active == 0 && activity.requests == 0 && activity.leases == 0)
    }

    @Test func invalidTraceNeverReachesTheProvider() async throws {
        let calls = Mutex(0)
        let tool = ToolRegistration(definition: try JSONParser().parse(#"{"name":"trace","inputSchema":{"type":"object"}}"#)) { _, context in
            calls.withLock { $0 += 1 }
            #expect(context.traceContext == nil)
            await RequestTraceScope.withTrace(context) { #expect(RequestTraceScope.current == nil) }
            return try JSONParser().parse(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await Server.make(info: JSONParser().parse(#"{"name":"trace-host","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
            cursors: CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 5, count: 32))], active: ScalarText("test"), clock: { 1000 }))
        let p = VerifiedPrincipal(subject: ScalarText("trusted"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"trace","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"traceparent":null}}}"#.utf8)
        let response = try #require(await server.handle(request, principal: p, origin: ScalarText("origin")))
        let result = try JSONParser().parseWithReport(Array(response)).result
        #expect(try result.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(calls.withLock { $0 } == 0 && RequestTraceScope.current == nil)
        let withoutTrace = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"trace","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
        let accepted = try #require(await server.handle(withoutTrace, principal: p, origin: ScalarText("origin")))
        #expect(try JSONParser().parseWithReport(Array(accepted)).result.objectValue?["result"] != nil)
        #expect(calls.withLock { $0 } == 1 && RequestTraceScope.current == nil)
    }
}
