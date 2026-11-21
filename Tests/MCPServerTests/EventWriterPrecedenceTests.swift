// SPDX-License-Identifier: Apache-2.0
// Error precedence between an event channel's writer (the transport sink) and
// the producer: a failed delivery is reported as the sink's own failure, while
// a producer-side event overflow remains `CoreFailure.eventOverflow` (#28, R3).
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

private struct SinkFault: Error, Equatable {}
private func precedenceJSON(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private let precedencePrincipal = VerifiedPrincipal(subject: ScalarText("alice"), issuer: ScalarText("issuer"), resource: ScalarText("server"), scopes: [])
private func precedenceServer(_ tool: ToolRegistration, events: EventPolicy? = nil) async throws -> Server {
    try await Server.make(info: precedenceJSON(#"{"name":"precedence","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("cursor"), material: Data(repeating: 9, count: 32))],
            active: ScalarText("cursor"), epoch: ScalarText("cursor"), clock: { 1000 }), events: events)
}
private func precedenceCall(_ name: String, id: Int, progress: Bool = false) -> Data {
    let meta = progress ? #", "progressToken":"p""# : ""
    return Data(("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}\(meta)},\"name\":\"\(name)\",\"arguments\":{}}}").utf8)
}
private func precedenceIdle(_ server: Server) async {
    let a = await server.activity
    #expect(a.active == 0 && a.queued == 0 && a.requests == 0 && a.leases == 0 && a.bufferedBytes == 0 && a.subscriptions == 0 && a.eventBytes == 0)
}

@Suite(.serialized) struct EventWriterPrecedence {
    /// The producer completes first and the terminal write then fails. Whichever
    /// child the group returns first, the caller sees the sink's failure, never an
    /// invented overflow. Before the fix this interleaving surfaced as
    /// `eventOverflow` (observed on Linux as `brokenPipe` → `eventOverflow`).
    @Test(arguments: [DeliveryMode.stdio, DeliveryMode.http])
    func terminalSinkFailureIsReportedAsItself(mode: DeliveryMode) async throws {
        let tool = ToolRegistration(definition: try precedenceJSON(#"{"name":"done","inputSchema":{"type":"object"}}"#)) { _, _ in
            try precedenceJSON(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await precedenceServer(tool)
        // Repetition widens the race window; every iteration must hold.
        for id in 1...200 {
            let attempts = Mutex(0)
            do {
                try await server.dispatchEvents(precedenceCall("done", id: id), principal: precedencePrincipal,
                    origin: ScalarText("origin"), mode: mode) { _ in attempts.withLock { $0 += 1 }; throw SinkFault() }
                Issue.record("A failed terminal write must not succeed (iteration \(id))")
            } catch let error as SinkFault { #expect(error == SinkFault()) }
            catch { Issue.record("Iteration \(id): expected the sink failure, got \(error)"); break }
            #expect(attempts.withLock { $0 } == 1)
        }
        await precedenceIdle(server)
    }

    /// Producer-side overflow with a healthy (merely slow) sink: the writer ends
    /// normally and the request still reports `eventOverflow`, cancelling the
    /// handler instead of waiting for it.
    @Test func producerOverflowWithHealthySinkStaysOverflow() async throws {
        let clock = Mutex(Int64(1000)), entered = Mutex(false), overflowed = Mutex(false), handlerCancelled = Mutex(false)
        let tool = ToolRegistration(definition: try precedenceJSON(#"{"name":"burst","inputSchema":{"type":"object"}}"#)) { _, context in
            _ = try await context.progress(JSONNumber(integer: 1))
            // The writer holds frame 1 in the sink, so the next frame cannot
            // replace it in the queue and must overflow the one-event bound.
            while !entered.withLock({ $0 }) { try Task.checkCancellation(); await Task.yield() }
            do {
                for n in 2...10 {
                    clock.withLock { $0 += 100 }
                    _ = try await context.progress(JSONNumber(integer: n))
                }
            } catch { overflowed.withLock { $0 = true } }
            // Swallow the overflow and keep running: only cancellation ends it.
            do { try await Task.sleep(for: .seconds(600)) } catch { handlerCancelled.withLock { $0 = true }; throw error }
            return try precedenceJSON(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await precedenceServer(tool, events: EventPolicy(queuedEvents: 1, clock: { clock.withLock { $0 } }))
        let writes = Mutex(0)
        await #expect(throws: CoreFailure.eventOverflow) {
            try await server.dispatchEvents(precedenceCall("burst", id: 1, progress: true), principal: precedencePrincipal,
                origin: ScalarText("origin"), mode: .stdio) { _ in
                writes.withLock { $0 += 1 }; entered.withLock { $0 = true }
                // Hold the first frame until the producer has overflowed, then succeed.
                while !overflowed.withLock({ $0 }) { try Task.checkCancellation(); await Task.yield() }
            }
        }
        #expect(overflowed.withLock { $0 } && handlerCancelled.withLock { $0 })
        #expect(writes.withLock { $0 } == 1)
        await precedenceIdle(server)
    }
}
