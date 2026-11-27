// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum BoundaryError: Error { case missingSignal, nestedDeadline }
private final class BoundarySignal: Sendable {
    private let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { pair.continuation.yield(()); pair.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.pair.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw BoundaryError.missingSignal }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw BoundaryError.missingSignal
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

// Intentionally noncooperative until the test opens it. This witnesses
// retained capacity while a cancelled callback is still unwinding.
private final class BoundaryGate: Sendable {
    private struct State: Sendable {
        var opened = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let opened = state.withLock { state in
                if state.opened { return true }
                state.waiter = continuation
                return false
            }
            if opened { continuation.resume() }
        }
    }
    func open() {
        let waiter = state.withLock { state in
            state.opened = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

private let boundaryPeer = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"subscriptions/listen"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71},"notifications":{"toolsListChanged":true}}}' ;;
            *'"method":"probe/flood-frames"'*|*'"method":"probe/flood-bytes"'*)
                case "$line" in
                    *'"method":"probe/flood-frames"'*) count=32; padding='' ;;
                    *) count=3; padding=$(printf '%0300d' 0) ;;
                esac
                i=0
                while [ "$i" -lt "$count" ]; do
                    printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71,"probe/padding":"%s"}}}\n' "$padding"
                    i=$((i+1))
                done
                printf 'TX:flood:%s\n' "$count" >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":72,"result":{}}' ;;
            *'"method":"probe/recover"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":73,"result":{}}' ;;
            *'"method":"probe/terminal-exit"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{}}'
                break ;;
            *'"method":"notifications/cancelled"'*) : ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func boundaryRequest(_ method: String, id: Int = 71) -> OutgoingRequest {
    .init(id: .integer(JSONNumber(integer: id)), method: method, name: nil,
        body: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8))
}
private func boundaryObject(_ bytes: Data) throws -> JSONObject {
    try #require(try WireCodec.parse(Array(bytes), limits: .balanced).result.objectValue)
}
private func boundaryResponse(_ bytes: Data, id: Int) throws {
    let object = try boundaryObject(bytes)
    #expect(object["id"] == .number(JSONNumber(integer: id)))
    #expect(object["result"]?.objectValue != nil)
}
private func boundaryACK(_ bytes: Data) throws {
    let object = try boundaryObject(bytes)
    #expect(object["method"]?.stringValue == "notifications/subscriptions/acknowledged")
    #expect(object["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] == .number(JSONNumber(integer: 71)))
}
private final class BoundaryLog: Sendable {
    let ready = BoundarySignal()
    private let storage = Mutex<[String]>([])
    func append(_ line: String) {
        storage.withLock { $0.append(line) }
        print("A22B2_BOUNDARY_PEER \(line)")
        if line == "READY" { ready.send() }
    }
    var lines: [String] { storage.withLock { $0 } }
    func transport(slots: Int, bytes: Int) -> StdioClientTransport {
        StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
            arguments: ["-c", boundaryPeer], maximumPendingRequests: slots,
            maximumMessageBytes: bytes, standardError: { self.append($0) }))
    }
    func methods() throws -> [String] {
        try requests().map { try #require($0["method"]?.stringValue) }
    }
    func cancellationIDs() throws -> [JSON] {
        try requests().filter { $0["method"]?.stringValue == "notifications/cancelled" }
            .map { try #require($0["params"]?.objectValue?["requestId"]) }
    }
    private func requests() throws -> [JSONObject] {
        try lines.filter { $0.hasPrefix("RX:") }.map { try boundaryObject(Data($0.dropFirst(3).utf8)) }
    }
}

private func withBoundaryPeer(slots: Int, bytes: Int = 4096,
    _ body: @Sendable (StdioClientTransport) async throws -> Void) async throws -> BoundaryLog {
    let log = BoundaryLog()
    let transport = log.transport(slots: slots, bytes: bytes)
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await transport.run() }
        do { try await log.ready.wait(); try await body(transport) }
        catch { transport.shutdown(); group.cancelAll(); throw error }
        transport.shutdown()
        try await group.waitForAll()
    }
    #expect(log.lines.first == "READY" && log.lines.last == "CLEAN")
    return log
}
private func boundaryRecover(_ transport: StdioClientTransport) async throws {
    try await transport.exchange(boundaryRequest("probe/recover", id: 73)) { try boundaryResponse($0, id: 73) }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioInboxBoundaryCases {
    @Test func cancelledReceiverRetainsSlotUntilItUnwinds() async throws {
        let entered = BoundarySignal(), cancelled = BoundarySignal(), gate = BoundaryGate()
        let exited = Mutex(false)
        let log = try await withBoundaryPeer(slots: 1) { transport in
            let owner = Task {
                try await transport.exchange(boundaryRequest("subscriptions/listen")) { bytes in
                    try boundaryACK(bytes)
                    defer { exited.withLock { $0 = true } }
                    await withTaskCancellationHandler {
                        entered.send()
                        await gate.wait()
                    } onCancel: { cancelled.send() }
                    try Task.checkCancellation()
                }
            }
            do {
                try await entered.wait()
                owner.cancel()
                try await cancelled.wait()
                #expect(!exited.withLock { $0 })
                await #expect(throws: StdioClientTransportError.busy) {
                    try await transport.exchange(boundaryRequest("probe/refused")) { _ in Issue.record("refused callback") }
                }
                await #expect(throws: StdioClientTransportError.busy) {
                    try await transport.exchange(boundaryRequest("probe/refused", id: 72)) { _ in Issue.record("refused callback") }
                }
                gate.open()
                await #expect(throws: CancellationError.self) { try await owner.value }
                #expect(exited.withLock { $0 })
                try await boundaryRecover(transport)
            } catch {
                owner.cancel(); gate.open(); transport.shutdown()
                _ = await owner.result
                throw error
            }
        }
        #expect(try log.methods() == ["subscriptions/listen", "notifications/cancelled", "probe/recover"])
        #expect(try log.cancellationIDs() == [.number(JSONNumber(integer: 71))])
        print("A22B2_BOUNDARY retained-slot joined=true")
    }

    @Test func frameOverflowFailsOnlyTheOverloadedExchange() async throws {
        try await checkOverflow(method: "probe/flood-frames", bytes: 65536, count: 32)
    }
    @Test func byteOverflowFailsOnlyTheOverloadedExchange() async throws {
        try await checkOverflow(method: "probe/flood-bytes", bytes: 512, count: 3)
    }
    private func checkOverflow(method: String, bytes: Int, count: Int) async throws {
        let seen = Mutex(0), nested = Mutex(false)
        let log = try await withBoundaryPeer(slots: 2, bytes: bytes) { transport in
            await #expect(throws: StdioClientTransportError.busy) {
                try await transport.exchange(boundaryRequest("subscriptions/listen")) { frame in
                    let n = seen.withLock { $0 += 1; return $0 }
                    guard n == 1 else { Issue.record("delivery after overflow"); return }
                    try boundaryACK(frame)
                    // The nested terminal is sent after all flood frames. Its
                    // delivery proves the shared reader progressed past them.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await transport.exchange(boundaryRequest(method, id: 72)) { bytes in
                                try boundaryResponse(bytes, id: 72)
                                nested.withLock { $0 = true }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(10))
                            throw BoundaryError.nestedDeadline
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                }
            }
            #expect(seen.withLock { $0 } == 1)
            #expect(nested.withLock { $0 })
            try await boundaryRecover(transport)
        }
        #expect(log.lines.contains("TX:flood:\(count)"))
        #expect(try log.methods() == ["subscriptions/listen", method, "notifications/cancelled", "probe/recover"])
        #expect(try log.cancellationIDs() == [.number(JSONNumber(integer: 71))])
        print("A22B2_BOUNDARY overflow=\(method) nested=\(nested.withLock { $0 }) delivered=\(seen.withLock { $0 })")
    }

    @Test func admittedTerminalSurvivesChildEOFWhileReceiverIsParked() async throws {
        let log = BoundaryLog(), entered = BoundarySignal(), done = BoundarySignal(), gate = BoundaryGate()
        let transport = log.transport(slots: 1, bytes: 4096)
        let run = Task { try await transport.run(); done.send() }
        do { try await log.ready.wait() }
        catch { run.cancel(); transport.shutdown(); _ = await run.result; throw error }
        let owner = Task {
            try await transport.exchange(boundaryRequest("probe/terminal-exit")) { bytes in
                try boundaryResponse(bytes, id: 71)
                entered.send()
                await gate.wait()
            }
        }
        do {
            try await entered.wait()
            try await done.wait() // Process joined, but caller owns parked receiver.
            // A new run must not overtake an outstanding receiver from the old run.
            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await transport.run()
                    Issue.record("new run started before old receiver retired")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw BoundaryError.missingSignal
                }
                defer { group.cancelAll() }
                await #expect(throws: StdioClientTransportError.alreadyRunning) { _ = try await group.next() }
            }
            gate.open()
            try await owner.value
            try await run.value
        } catch {
            gate.open(); owner.cancel(); run.cancel(); transport.shutdown()
            _ = await owner.result; _ = await run.result
            throw error
        }
        #expect(log.lines.first == "READY" && log.lines.last == "CLEAN")
        #expect(try log.methods() == ["probe/terminal-exit"])
        #expect(try log.cancellationIDs().isEmpty)
        print("A22B2_BOUNDARY terminal-before-eof completed=true")
    }
}
