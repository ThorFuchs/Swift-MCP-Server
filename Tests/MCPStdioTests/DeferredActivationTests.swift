// SPDX-License-Identifier: Apache-2.0
// D28 source tests only. NOT_COMPILED / NOT_RUN.
import Foundation
import JSON
import MCPProtocol
import MCPServer
import SystemPackage
import Testing
@testable import MCPStdio

private func deferredServer() async throws -> Server {
    let info = try JSONParser().parseWithReport(Array(#"{"name":"construction","version":"1"}"#.utf8)).result
    let cursors = try CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:1,count:32))],active:ScalarText("k"),clock:{1000})
    return try await Server.make(info:info,catalog:ServerCatalog(),cursors:cursors)
}
private let deferredPrincipal = VerifiedPrincipal(subject:ScalarText("construction"),issuer:ScalarText("host"),resource:ScalarText("stdio"),scopes:[])
private actor DeferredStartGate {
    private var ready = false
    private var waiter: CheckedContinuation<Void,Never>?
    func wait() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
    func open() { ready = true; waiter?.resume(); waiter = nil }
}
private func observed(_ events: ConstructionObservations, _ prefix: String) async throws {
    let deadline = ContinuousClock.now.advanced(by:.seconds(5))
    while events.count(prefix) == 0 {
        guard ContinuousClock.now < deadline else { throw StdioFailure.readDeadline }
        try await Task.sleep(for:.milliseconds(1))
    }
}

@Suite(.serialized) @MainActor struct DeferredActivation {
    @Test func shutdownAndCancellationBeforeActivation() async throws { // G01-S06
        let server = try await deferredServer()
        let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(); let t = try p.make(events,owned:true)
        t.shutdown()
        try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("shutdown"))
        #expect(events.count("activated.") == 0 && events.count("joined.") == 2)
        #expect(t.statistics.phase == .stopped && events.count("closed.") == 6)
        let q = try ConstructionPipes(); defer { q.close() }
        let cancelledEvents = ConstructionObservations(); let cancelled = try q.make(cancelledEvents)
        let gate = DeferredStartGate()
        let task = Task { await gate.wait(); try await cancelled.run(server:server,principal:deferredPrincipal,origin:ScalarText("cancel-before")) }
        task.cancel(); await gate.open()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(cancelledEvents.count("activated.") == 0 && cancelledEvents.count("joined.") == 2)
        #expect(cancelled.statistics.phase == .stopped)
    }
    @Test func partialActivationStopsAndJoinsBothEndpoints() async throws { // G01-S07
        let server = try await deferredServer(); let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(["activate.output"]); let t = try p.make(events,owned:true)
        await #expect(throws:ConstructionFault.injected("activate.output")) {
            try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("partial"))
        }
        #expect(events.count("activated.input") == 1 && events.count("activated.output") == 0)
        #expect(events.count("joined.input") == 1 && events.count("joined.output") == 1)
        #expect(events.count("closed.") == 6 && t.statistics.phase == .stopped)
    }
    @Test func eofCancellationAndBrokenOutputSettle() async throws { // G01-S08
        let server = try await deferredServer()
        do {
            let p = try ConstructionPipes(); defer { p.close() }
            let events = ConstructionObservations(); let t = try p.make(events)
            try p.closeInputPeer()
            try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("EOF"))
            #expect(events.count("joined.") == 2 && events.count("closed.") == 6)
            #expect(t.statistics.writerBytes == 0 && t.statistics.phase == .stopped)
        }
        do {
            let p = try ConstructionPipes(); defer { p.close() }
            let events = ConstructionObservations(); let t = try p.make(events)
            let task = Task { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("cancel-active")) }
            do { try await observed(events,"activated.output") }
            catch { task.cancel(); _ = try? await task.value; throw error }
            task.cancel()
            do { try await task.value; Issue.record("Cancelled run unexpectedly succeeded") }
            catch { #expect(error is CancellationError || (error as? StdioFailure) == .closed) }
            #expect(events.count("joined.") == 2 && events.count("closed.") == 6)
            #expect(t.statistics.phase == .stopped)
        }
        do {
            let p = try ConstructionPipes(); defer { p.close() }
            let events = ConstructionObservations(); let t = try p.make(events)
            let request = Array((#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"# + "\n").utf8)
            _ = try request.withUnsafeBytes { try p.incoming.writeEnd.write($0) }
            try p.closeInputPeer(); try p.closeOutputPeer()
            await #expect(throws:StdioFailure.brokenPipe) { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("broken")) }
            #expect(events.count("joined.") == 2 && events.count("closed.") == 6)
        }
    }
    @Test func cleanupFailurePreservesPrimaryAndSecondJoin() async throws { // G01-S09
        let server = try await deferredServer(); let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(["activate.output","join.input","join.output"])
        let t = try p.make(events)
        do { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("cleanup")); Issue.record("Expected lifecycle failure") }
        catch let error as StdioLifecycleFailure {
            #expect((error.operation as? ConstructionFault) == .injected("activate.output"))
            #expect(error.cleanup.map(\.stage) == ["join.input","join.output"])
        }
        #expect(events.count("joined.input") == 1 && events.count("joined.output") == 1)
        #expect(events.count("closed.") == 6 && !events.overflow)
    }
    @Test func repeatedConcurrentRunAndStopKeepSingleOwner() async throws { // G01-S10
        let server = try await deferredServer(); let p = try ConstructionPipes(); defer { p.close() }
        let events = ConstructionObservations(); let t = try p.make(events)
        let first = Task { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("single")) }
        do { try await observed(events,"activated.output") }
        catch { first.cancel(); _ = try? await first.value; throw error }
        await #expect(throws:StdioFailure.alreadyRunning) { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("second")) }
        t.shutdown(); try await first.value
        await #expect(throws:StdioFailure.alreadyRunning) { try await t.run(server:server,principal:deferredPrincipal,origin:ScalarText("third")) }
        #expect(events.count("activated.input") == 1 && events.count("activated.output") == 1)
        for index in 0..<8 {
            let q = try ConstructionPipes(); defer { q.close() }
            let e = ConstructionObservations(); let transport = try q.make(e)
            let run = Task { try await transport.run(server:server,principal:deferredPrincipal,origin:ScalarText("race"+String(index))) }
            let stop = Task { transport.shutdown() }
            await stop.value; try await run.value
            #expect(e.count("activated.input") <= 1 && e.count("activated.output") <= 1)
            #expect(e.count("closed.") == 6 && e.count("joined.") == 2)
        }
    }
}
