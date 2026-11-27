// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum PrecancelDiagnosticError: Error { case rendezvous }

private final class PrecancelSignal: Sendable {
    private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { channel.continuation.yield(()); channel.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.channel.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw PrecancelDiagnosticError.rendezvous }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw PrecancelDiagnosticError.rendezvous
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

// The parent cancels the parked task BEFORE opening the gate. The gate is
// intentionally cancellation-insensitive and is opened on every cleanup path.
private final class PrecancelGate: Sendable {
    private struct State: Sendable {
        var opened = false
        var parked: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    let entered = PrecancelSignal()
    func park() async {
        await withCheckedContinuation { continuation in
            let opened = state.withLock { state in
                if state.opened { return true }
                state.parked = continuation
                return false
            }
            entered.send()
            if opened { continuation.resume() }
        }
    }
    func open() {
        let parked = state.withLock { state in
            state.opened = true
            let continuation = state.parked
            state.parked = nil
            return continuation
        }
        parked?.resume()
    }
}

private let precancelPeer = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"probe/pre-cancelled"'*)
                printf '%s\n' ADMITTED >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{}}'
                break ;;
            *'"method":"probe/recover"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":72,"result":{}}' ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func diagnosticRequest(_ method: String, id: Int) -> OutgoingRequest {
    .init(id: .integer(JSONNumber(integer: id)), method: method, name: nil,
          body: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8))
}

private struct PrecancelObservation: Sendable {
    let cancelledAtEntry: Bool
    let outcome: String
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioPrecancelDiagnosticCases {
    @Test func ordinaryExchangeReachesFinitePeer() async throws { try await probe(cancelBeforeEntry: false) }
    @Test func externallyPrecancelledExchangeNeverReachesPeer() async throws { try await probe(cancelBeforeEntry: true) }

    private func probe(cancelBeforeEntry: Bool) async throws {
        let ready = PrecancelSignal()
        let gate = PrecancelGate()
        let lines = Mutex<[String]>([])
        let callbacks = Mutex<[JSON]>([])
        let guardFired = Mutex(false)
        let transport = StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
            arguments: ["-c", precancelPeer], maximumPendingRequests: 1, standardError: { line in
                lines.withLock { $0.append(line) }
                print("A22B_PRE_PEER \(line)")
                if line == "READY" { ready.send() }
            }))
        let observation = try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.run() }
            do { try await ready.wait() }
            catch { transport.shutdown(); group.cancelAll(); throw error }
            let exchange = Task {
                await gate.park()
                let cancelledAtEntry = Task.isCancelled
                print("A22B_PRE_ENTRY cancelled=\(cancelledAtEntry)")
                let outcome: String
                do {
                    try await transport.exchange(diagnosticRequest("probe/pre-cancelled", id: 71)) { bytes in
                        let message = try WireCodec.parse(Array(bytes), limits: .balanced).result
                        callbacks.withLock { $0.append(message) }
                    }
                    outcome = "complete"
                } catch is CancellationError { outcome = "CancellationError" }
                catch { outcome = String(describing: error) }
                return PrecancelObservation(cancelledAtEntry: cancelledAtEntry, outcome: outcome)
            }
            do { try await gate.entered.wait() }
            catch {
                exchange.cancel(); gate.open(); transport.shutdown(); group.cancelAll()
                _ = await exchange.value
                throw error
            }
            if cancelBeforeEntry { exchange.cancel() }
            // The independent guard only forces EOF if the exchange fails to
            // return; firing is an explicit failing diagnostic, never PASS.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guardFired.withLock { $0 = true }
                print("A22B_PRE_GUARD fired")
                transport.shutdown()
            }
            gate.open()
            let result = await exchange.value
            var recovered = false
            if cancelBeforeEntry && result.outcome == "CancellationError" && !guardFired.withLock({ $0 }) {
                do {
                    try await transport.exchange(diagnosticRequest("probe/recover", id: 72)) { bytes in
                        let message = try WireCodec.parse(Array(bytes), limits: .balanced).result
                        #expect(message.objectValue?["id"] == .number(JSONNumber(integer: 72)))
                    }
                    recovered = true
                } catch { print("A22B_PRE_RECOVERY_ERROR \(error)") }
            }
            watchdog.cancel()
            await watchdog.value
            transport.shutdown()
            try await group.waitForAll()
            print("A22B_PRE_RESULT cancelled=\(result.cancelledAtEntry) outcome=\(result.outcome) guard=\(guardFired.withLock { $0 }) recovery=\(recovered)")
            #expect(recovered == cancelBeforeEntry)
            return result
        }
        let wire = lines.withLock { $0 }
        let received = wire.filter { $0.hasPrefix("RX:") }
        let methods = try received.map { line in
            let message = try WireCodec.parse(Array(line.dropFirst(3).utf8), limits: .balanced).result
            return try #require(message.objectValue?["method"]?.stringValue)
        }
        #expect(wire.first == "READY" && wire.last == "CLEAN")
        #expect(!guardFired.withLock { $0 })
        #expect(observation.cancelledAtEntry == cancelBeforeEntry)
        #expect(observation.outcome == (cancelBeforeEntry ? "CancellationError" : "complete"))
        #expect(methods == [cancelBeforeEntry ? "probe/recover" : "probe/pre-cancelled"])
        #expect(wire.contains("ADMITTED") == !cancelBeforeEntry)
        let seen = callbacks.withLock { $0 }
        #expect(seen.count == (cancelBeforeEntry ? 0 : 1))
        if !cancelBeforeEntry { #expect(seen.first?.objectValue?["id"] == .number(JSONNumber(integer: 71))) }
    }
}
