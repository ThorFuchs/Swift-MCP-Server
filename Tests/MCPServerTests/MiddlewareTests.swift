// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private func mwJSON(_ s: String) throws -> JSON { try WireCodec.parse(Array(s.utf8), limits: .balanced).result }
private let mwPrincipal = VerifiedPrincipal(subject: ScalarText("host"), issuer: ScalarText("issuer"), resource: ScalarText("resource"), scopes: [])
private func mwRequest(_ arguments: String = "{}", id: Int = 1) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"tool\",\"arguments\":\(arguments),\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}".utf8)
}
private func mwServer(_ middleware: [RequestMiddleware], handler: @escaping @Sendable (JSONPresence<JSON>, RequestContext) async throws -> JSON) async throws -> Server {
    try await Server.make(info: mwJSON(#"{"name":"middleware","version":"1"}"#),
        catalog: ServerCatalog(tools: [.init(definition: mwJSON(#"{"name":"tool","inputSchema":{"type":"object"}}"#), handler: handler)]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 1, count: 32))], active: ScalarText("test"), clock: { 1000 }), middleware: middleware)
}
private func mwResult(_ server: Server, _ data: Data = mwRequest()) async throws -> JSON {
    try mwJSON(String(decoding: #require(await server.handle(data, principal: mwPrincipal, origin: ScalarText("host"))), as: UTF8.self))
}
private func mwClean(_ server: Server) async {
    let a = await server.activity
    #expect(a.active == 0 && a.requests == 0 && a.leases == 0 && a.bufferedBytes == 0 && a.eventBytes == 0)
}
@Suite(.serialized) struct MiddlewareCases {
    @Test func orderedAdmissionProviderAndReverseCompletionDoNotReplaceCheckedValues() async throws {
        let trace = Mutex<[String]>([])
        let registrations = ["a", "b"].map { name in RequestMiddleware(admit: { request, next in
            #expect(request.context.principal.subject == mwPrincipal.subject)
            trace.withLock { $0.append("enter-" + name) }
            return try await next.proceed(for: request)
        }, didFinish: { _, outcome in
            if case .returned = outcome { trace.withLock { $0.append("exit-" + name) } }
        }) }
        let server = try await mwServer(registrations) { _, _ in trace.withLock { $0.append("provider") }; return try mwJSON(#"{"resultType":"complete","content":[]}"#) }
        #expect(try await mwResult(server).objectValue?["result"] != nil)
        #expect(trace.withLock { $0 } == ["enter-a", "enter-b", "provider", "exit-b", "exit-a"])
        await mwClean(server)
    }
    @Test func intentionalRejectionAndSchemaFailureNeverInvokeProvider() async throws {
        let calls = Mutex(0), middlewareCalls = Mutex(0)
        let deny = RequestMiddleware { _, _ in middlewareCalls.withLock { $0 += 1 }; return .reject(.standard(.invalidParams)) }
        let server = try await mwServer([deny]) { _, _ in calls.withLock { $0 += 1 }; return try mwJSON(#"{"resultType":"complete","content":[]}"#) }
        #expect(try await mwResult(server).objectValue?["error"] != nil)
        #expect(try await mwResult(server, mwRequest("null")).objectValue?["error"] != nil)
        #expect(calls.withLock { $0 } == 0 && middlewareCalls.withLock { $0 } == 1)
        await mwClean(server)
    }
    @Test func caughtDuplicateAndForeignOrEscapedAdmissionCannotExecuteEffects() async throws {
        let calls = Mutex(0), saved = Mutex<(MiddlewareRequest, MiddlewareContinuation, MiddlewareDecision)?>(nil)
        let mode = Mutex(0)
        let middleware = RequestMiddleware { view, next in
            if mode.withLock({ $0 }) == 1, let old = saved.withLock({ $0 }) {
                do { _ = try await next.proceed(for: old.0) } catch {}
                return old.2
            }
            let decision = try await next.proceed(for: view)
            saved.withLock { $0 = (view, next, decision) }
            if mode.withLock({ $0 }) == 2 { do { _ = try await next.proceed(for: view) } catch {} }
            return decision
        }
        let server = try await mwServer([middleware]) { _, _ in calls.withLock { $0 += 1 }; return try mwJSON(#"{"resultType":"complete","content":[]}"#) }
        #expect(try await mwResult(server).objectValue?["result"] != nil)
        let old = try #require(saved.withLock { $0 })
        await #expect(throws: CoreFailure.duplicate) { _ = try await old.1.proceed(for: old.0) }
        mode.withLock { $0 = 1 }
        #expect(try await mwResult(server, mwRequest(id: 2)).objectValue?["error"] != nil)
        mode.withLock { $0 = 2 }
        #expect(try await mwResult(server, mwRequest(id: 3)).objectValue?["error"] != nil)
        #expect(calls.withLock { $0 } == 1)
        await mwClean(server)
    }
    @Test func swallowedWorkFailureCannotTurnIntoIntentionalDenialOrSuccess() async throws {
        let calls = Mutex(0)
        let middleware = RequestMiddleware { view, _ in
            do { try await view.context.budget.consume(UInt64.max) } catch {}
            return .reject(.standard(.methodNotFound))
        }
        let server = try await mwServer([middleware]) { _, _ in calls.withLock { $0 += 1 }; return try mwJSON(#"{"resultType":"complete","content":[]}"#) }
        let value = try await mwResult(server)
        #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32603)
        #expect(calls.withLock { $0 } == 0)
        await mwClean(server)
    }
    @Test func cancellationDuringAdmissionJoinsOwnerAndSinkFailureDoesNotReplayProvider() async throws {
        let entered = Mutex(false), cancelled = Mutex(false), mode = Mutex(false), calls = Mutex(0)
        let middleware = RequestMiddleware { view, next in
            if !mode.withLock({ $0 }) {
                entered.withLock { $0 = true }
                do { while true { try view.context.checkCancellation(); await Task.yield() } }
                catch { cancelled.withLock { $0 = true }; throw error }
            }
            return try await next.proceed(for: view)
        }
        let server = try await mwServer([middleware]) { _, _ in calls.withLock { $0 += 1 }; return try mwJSON(#"{"resultType":"complete","content":[]}"#) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await #expect(throws: CancellationError.self) { _ = try await mwResult(server) } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !entered.withLock({ $0 }) { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; await Task.yield() }
            try await server.cancel(id: RequestID(.number(JSONNumber(integer: 1))), principal: mwPrincipal, origin: ScalarText("host"))
            try await group.waitForAll()
        }
        #expect(cancelled.withLock { $0 } && calls.withLock { $0 } == 0)
        mode.withLock { $0 = true }
        await #expect(throws: CoreFailure.disconnected) {
            try await server.dispatch(mwRequest(id: 2), principal: mwPrincipal, origin: ScalarText("host")) { _ in throw CoreFailure.disconnected }
        }
        #expect(calls.withLock { $0 } == 1)
        await mwClean(server)
    }
    @Test func admissionSuspensionRetainsSelectedGenerationAcrossCatalogReplacement() async throws {
        let waiting = Mutex(false), release = Mutex(false), seen = Mutex<[UInt64]>([])
        let middleware = RequestMiddleware { request, next in
            seen.withLock { $0.append(request.context.generation) }
            if request.context.generation == 1 {
                waiting.withLock { $0 = true }
                while !release.withLock({ $0 }) { try request.context.checkCancellation(); await Task.yield() }
            }
            return try await next.proceed(for: request)
        }
        let server = try await mwServer([middleware]) { _, _ in try mwJSON(#"{"resultType":"complete","content":[],"structuredContent":"old"}"#) }
        try await withThrowingTaskGroup(of: JSON.self) { group in
            group.addTask { try await mwResult(server) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !waiting.withLock({ $0 }) { guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; await Task.yield() }
            let replacement = ToolRegistration(definition: try mwJSON(#"{"name":"tool","inputSchema":{"type":"object"}}"#)) { _, _ in try mwJSON(#"{"resultType":"complete","content":[],"structuredContent":"new"}"#) }
            try await server.replaceCatalog(ServerCatalog(tools: [replacement]))
            #expect(try await mwResult(server, mwRequest(id: 2)).objectValue?["result"]?.objectValue?["structuredContent"]?.stringValue == "new")
            release.withLock { $0 = true }
            #expect(try await group.next()?.objectValue?["result"]?.objectValue?["structuredContent"]?.stringValue == "old")
        }
        #expect(seen.withLock { $0 } == [1, 2]); await mwClean(server)
    }

}
