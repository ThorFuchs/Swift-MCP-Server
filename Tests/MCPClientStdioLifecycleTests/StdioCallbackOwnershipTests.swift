// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum OwnershipProbeError: Error, Sendable { case rendezvous, nestedDeadline }

private final class OwnershipSignal: Sendable {
    private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { channel.continuation.yield(()); channel.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.channel.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw OwnershipProbeError.rendezvous }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw OwnershipProbeError.rendezvous
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private final class OwnershipPeerLog: Sendable {
    let ready = OwnershipSignal()
    private let lines = Mutex<[String]>([])
    func append(_ line: String) {
        lines.withLock { $0.append(line) }
        print("A22B2_PEER \(line)")
        if line == "READY" { ready.send() }
    }
    var snapshot: [String] { lines.withLock { $0 } }
}

// A finite synthetic child. All accepted input is echoed, and the nested
// path sends the outer terminal BEFORE the nested response. The reader
// must continue routing the nested response while preserving outer order.
private let ownershipPeer = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"subscriptions/listen"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71},"notifications":{"toolsListChanged":true}}}' ;;
            *'"method":"probe/terminal"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{}}' ;;
            *'"method":"probe/nested"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                printf '%s\n' TX:outer-terminal >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":72,"result":{}}'
                printf '%s\n' TX:nested-terminal >&2 ;;
            *'"method":"probe/recover"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":73,"result":{}}' ;;
            *'"method":"notifications/cancelled"'*) : ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func ownershipRequest(_ method: String, id: Int = 71) -> OutgoingRequest {
    .init(id: .integer(JSONNumber(integer: id)), method: method, name: nil,
          body: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8))
}

private func ownershipObject(_ bytes: Data) throws -> JSONObject {
    try #require(try WireCodec.parse(Array(bytes), limits: .balanced).result.objectValue)
}

private func ownershipACK(_ bytes: Data) throws {
    let object = try ownershipObject(bytes)
    #expect(object["method"]?.stringValue == "notifications/subscriptions/acknowledged")
    #expect(object["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] == .number(JSONNumber(integer: 71)))
}

private func ownershipResponse(_ bytes: Data, id: Int) throws {
    let object = try ownershipObject(bytes)
    #expect(object["id"] == .number(JSONNumber(integer: id)))
    #expect(object["result"]?.objectValue != nil)
}

private func ownershipRecover(_ transport: StdioClientTransport) async throws {
    try await transport.exchange(ownershipRequest("probe/recover", id: 73)) { bytes in
        try ownershipResponse(bytes, id: 73)
    }
}

private func withOwnershipPeer(_ body: @Sendable (StdioClientTransport) async throws -> Void) async throws -> [String] {
    let log = OwnershipPeerLog()
    let transport = StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
        arguments: ["-c", ownershipPeer], maximumPendingRequests: 2,
        standardError: { log.append($0) }))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await transport.run() }
        do {
            try await log.ready.wait()
            try await body(transport)
        } catch {
            transport.shutdown()
            group.cancelAll()
            throw error
        }
        transport.shutdown()
        try await group.waitForAll()
    }
    let lines = log.snapshot
    #expect(lines.first == "READY" && lines.last == "CLEAN")
    return lines
}

private func ownershipRequests(_ lines: [String]) throws -> [JSONObject] {
    try lines.filter { $0.hasPrefix("RX:") }.map { try ownershipObject(Data($0.dropFirst(3).utf8)) }
}

private func ownershipMethods(_ lines: [String]) throws -> [String] {
    try ownershipRequests(lines).map { try #require($0["method"]?.stringValue) }
}

private func ownershipCancellationIDs(_ lines: [String]) throws -> [JSON] {
    try ownershipRequests(lines).filter { $0["method"]?.stringValue == "notifications/cancelled" }
        .map { try #require($0["params"]?.objectValue?["requestId"]) }
}

private struct CallbackSnapshot: Sendable {
    var entered = 0
    var exited = 0
    var cancelled = false
}

private final class ParkedReceiver: Sendable {
    let entered = OwnershipSignal()
    private let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let state = Mutex(CallbackSnapshot())
    func receive(_ bytes: Data, terminal: Bool) async throws {
        if terminal { try ownershipResponse(bytes, id: 71) }
        else { try ownershipACK(bytes) }
        state.withLock { $0.entered += 1 }
        defer {
            state.withLock { $0.exited += 1; $0.cancelled = Task.isCancelled }
            print("A22B2_CALLBACK_EXIT terminal=\(terminal) cancelled=\(Task.isCancelled)")
        }
        entered.send()
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }
    var snapshot: CallbackSnapshot { state.withLock { $0 } }
    func release() { gate.continuation.finish() }
}

private struct OwnershipReturn: Sendable {
    let outcome: String
    let callback: CallbackSnapshot
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioCallbackOwnershipCases {
    @Test func ordinaryTerminalAndRecoveryPreserveWireOrder() async throws {
        let lines = try await withOwnershipPeer { transport in
            try await transport.exchange(ownershipRequest("probe/terminal")) { bytes in
                try ownershipResponse(bytes, id: 71)
            }
            try await ownershipRecover(transport)
        }
        #expect(try ownershipMethods(lines) == ["probe/terminal", "probe/recover"])
        #expect(try ownershipCancellationIDs(lines).isEmpty)
    }

    @Test func cancelledNonterminalExchangeJoinsSuspendedReceiver() async throws {
        try await checkCancellationJoin(terminal: false)
    }

    @Test func cancelledTerminalExchangeJoinsSuspendedReceiverWithoutWireCancel() async throws {
        try await checkCancellationJoin(terminal: true)
    }

    private func checkCancellationJoin(terminal: Bool) async throws {
        let receiver = ParkedReceiver()
        let guardFired = Mutex(false)
        let method = terminal ? "probe/terminal" : "subscriptions/listen"
        let lines = try await withOwnershipPeer { transport in
            let caller = Task {
                let outcome: String
                do {
                    try await transport.exchange(ownershipRequest(method)) { bytes in
                        try await receiver.receive(bytes, terminal: terminal)
                    }
                    outcome = "complete"
                } catch is CancellationError { outcome = "CancellationError" }
                catch { outcome = String(describing: error) }
                // Snapshot BEFORE releasing the gate: no timing-based inference
                // from how long a callback happened to remain suspended.
                let callback = receiver.snapshot
                print("A22B2_RETURN terminal=\(terminal) outcome=\(outcome) entered=\(callback.entered) exited=\(callback.exited) cancelled=\(callback.cancelled)")
                receiver.release()
                return OwnershipReturn(outcome: outcome, callback: callback)
            }
            do { try await receiver.entered.wait() }
            catch {
                caller.cancel(); receiver.release(); transport.shutdown()
                _ = await caller.value
                throw error
            }
            caller.cancel()
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guardFired.withLock { $0 = true }
                print("A22B2_JOIN_GUARD fired terminal=\(terminal)")
                receiver.release()
                transport.shutdown()
            }
            let result = await caller.value
            watchdog.cancel()
            await watchdog.value
            #expect(!guardFired.withLock { $0 })
            #expect(result.outcome == "CancellationError")
            #expect(result.callback.entered == 1)
            #expect(result.callback.exited == 1)
            #expect(result.callback.cancelled)
            if !guardFired.withLock({ $0 }) { try await ownershipRecover(transport) }
        }
        #expect(receiver.snapshot.entered == 1 && receiver.snapshot.exited == 1)
        #expect(try ownershipMethods(lines) == (terminal ? [method, "probe/recover"] : [method, "notifications/cancelled", "probe/recover"]))
        #expect(try ownershipCancellationIDs(lines) == (terminal ? [] : [.number(JSONNumber(integer: 71))]))
    }

    @Test func reentrantExchangeProgressesWhileOuterFramesRemainOrdered() async throws {
        let trace = Mutex<[String]>([])
        let guardFired = Mutex(false)
        let lines = try await withOwnershipPeer { transport in
            let outcome: String
            do {
                try await transport.exchange(ownershipRequest("subscriptions/listen")) { bytes in
                    let object = try ownershipObject(bytes)
                    if object["method"] != nil {
                        try ownershipACK(bytes)
                        trace.withLock { $0.append("outer-enter") }
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                try await transport.exchange(ownershipRequest("probe/nested", id: 72)) { bytes in
                                    try ownershipResponse(bytes, id: 72)
                                    trace.withLock { $0.append("nested-response") }
                                }
                            }
                            group.addTask {
                                try await Task.sleep(for: .seconds(10))
                                guardFired.withLock { $0 = true }
                                print("A22B2_NESTED_GUARD fired")
                                throw OwnershipProbeError.nestedDeadline
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                        trace.withLock { $0.append("outer-exit") }
                    } else {
                        try ownershipResponse(bytes, id: 71)
                        trace.withLock { $0.append("outer-terminal") }
                    }
                }
                outcome = "complete"
                trace.withLock { $0.append("outer-return") }
            } catch { outcome = String(describing: error) }
            print("A22B2_REENTRANT outcome=\(outcome) guard=\(guardFired.withLock { $0 }) trace=\(trace.withLock { $0 })")
            #expect(outcome == "complete")
            #expect(!guardFired.withLock { $0 })
            #expect(trace.withLock { $0 } == ["outer-enter", "nested-response", "outer-exit", "outer-terminal", "outer-return"])
            try await ownershipRecover(transport)
        }
        #expect(lines.contains("TX:outer-terminal") && lines.contains("TX:nested-terminal"))
        #expect(try ownershipMethods(lines) == ["subscriptions/listen", "probe/nested", "probe/recover"])
        #expect(try ownershipCancellationIDs(lines).isEmpty)
    }
}
