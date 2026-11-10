// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

@Test func invalidTraceMetadataCannotReachTheProviderOrBecomeVerifiedIdentity() async throws {
    let calls = Mutex(0)
    let principal = VerifiedPrincipal(subject: ScalarText("verified-host-user"), issuer: ScalarText("host"), resource: ScalarText("server"), scopes: [])
    let tool = ToolRegistration(definition: try JSONParser().parse(#"{"name":"trace-check","inputSchema":{"type":"object"}}"#)) { _, context in
        #expect(context.principal.subject == principal.subject)
        calls.withLock { $0 += 1 }
        return try JSONParser().parse(#"{"resultType":"complete","content":[]}"#)
    }
    let server = try await Server.make(info: JSONParser().parse(#"{"name":"trace-admission","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 7, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
    for extra in [#""traceparent":null"#, #""traceparent":"00-00000000000000000000000000000000-0123456789abcdef-01""#,
        #""tracestate":"vendor=x,vendor=y""#, #""baggage":"key=%xz""#] {
        let request = Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"trace-check","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"# + extra + "}}}").utf8)
        let response = try #require(await server.handle(request, principal: principal, origin: ScalarText("origin")))
        let value = try JSONParser().parseWithReport(Array(response)).result
        #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(calls.withLock { $0 } == 0)
    }
    let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"trace-check","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"traceparent":"00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01","baggage":"user=untrusted"}}}"#.utf8)
    let response = try #require(await server.handle(request, principal: principal, origin: ScalarText("origin")))
    #expect(try JSONParser().parseWithReport(Array(response)).result.objectValue?["result"] != nil)
    #expect(calls.withLock { $0 } == 1)
    let state = await server.activity
    #expect(state.active == 0 && state.queued == 0 && state.requests == 0 && state.bufferedBytes == 0 && state.leases == 0)
}

@Test func invalidOutboundTraceMetadataDoesNotBecomeASuccessfulResult() async throws {
    let calls = Mutex(0)
    let tool = ToolRegistration(definition: try JSONParser().parse(#"{"name":"trace-output","inputSchema":{"type":"object"}}"#)) { _, _ in
        calls.withLock { $0 += 1 }
        return try JSONParser().parse(#"{"resultType":"complete","content":[],"_meta":{"traceparent":null}}"#)
    }
    let principal = VerifiedPrincipal(subject: ScalarText("host-user"), issuer: ScalarText("host"), resource: ScalarText("server"), scopes: [])
    let server = try await Server.make(info: JSONParser().parse(#"{"name":"trace-output","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 7, count: 32))], active: ScalarText("cursor"), clock: { 1000 }))
    let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"trace-output","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
    let response = try #require(await server.handle(request, principal: principal, origin: ScalarText("origin")))
    let value = try JSONParser().parseWithReport(Array(response)).result
    #expect(value.objectValue?["result"] == nil)
    #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32603)
    #expect(calls.withLock { $0 } == 1)
    let state = await server.activity
    #expect(state.active == 0 && state.requests == 0 && state.bufferedBytes == 0 && state.leases == 0)
}

@Test func traceRegexExhaustionTerminatesTheSharedAccountWithoutSettlementReuse() async throws {
    let document = try FrozenWireSchema.parse(FrozenWireSchema.read(maximumBytes: 262_144), limits: .balanced).result
    let plan = try WireDefinitionPlan.compile(document.root(at: .MetaObject, limits: .balanced).result, limits: .balanced).result
    let value = try JSONParser().parse(#"{"tracestate":"a=x,b=y,a=z"}"#)
    let budget = try RequestBudget(workUnits: 8_000_000)
    var limits = JSONLimits.balanced
    limits[.aggregateRegexWorkUnits] = 1
    let restricted = limits
    await #expect(throws: JSONFailure.self) {
        _ = try await budget.performJSON(limits: restricted) { try plan.validate(value, limits: $0) }
    }
    let failed = await budget.snapshot
    #expect(failed.isTerminal && failed.remaining == 0 && failed.activeReservations == 0 && failed.terminalTransitions == 1)
    await #expect(throws: RequestBudget.Failure.exhausted) { try await budget.consume(1) }
    #expect(await budget.snapshot.terminalTransitions == 1)
}
