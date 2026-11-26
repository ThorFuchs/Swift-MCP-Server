// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum ExchangeProbeError: Error, Equatable, Sendable {
    case callback
    case missingRendezvous
}

/// Single-use readiness/ACK rendezvous. Deadline bounds missing evidence;
/// it never chooses the order of a successful test.
private final class ExchangeSignal: Sendable {
    private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { channel.continuation.yield(()); channel.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.channel.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw ExchangeProbeError.missingRendezvous }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ExchangeProbeError.missingRendezvous
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private final class ExchangePeerLog: Sendable {
    let ready = ExchangeSignal()
    private let lines = Mutex<[String]>([])
    func append(_ line: String) {
        lines.withLock { $0.append(line) }
        if line == "READY" { ready.send() }
    }
    var snapshot: [String] { lines.withLock { $0 } }
}

// Finite synthetic child, not a real MCP server. It records the complete
// received wire lines on stderr, ACKs a listen without completing it, and
// answers terminal/recovery requests. EOF is the normal shutdown handshake.
private let exchangePeerScript = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"subscriptions/listen"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71},"notifications":{"toolsListChanged":true}}}' ;;
            *'"method":"probe/pre-cancelled"'*|*'"method":"probe/terminal"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{}}' ;;
            *'"method":"probe/recover"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":72,"result":{}}' ;;
            *'"method":"notifications/cancelled"'*) : ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func exchangeRequest(_ method: String, id: Int = 71) -> OutgoingRequest {
    .init(id: .integer(JSONNumber(integer: id)), method: method, name: nil,
          body: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8))
}

private func exchangeJSON(_ bytes: Data) throws -> JSON {
    try WireCodec.parse(Array(bytes), limits: .balanced).result
}

private func checkACK(_ bytes: Data) throws {
    let object = try #require(try exchangeJSON(bytes).objectValue)
    #expect(object["method"]?.stringValue == "notifications/subscriptions/acknowledged")
    #expect(object["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] == .number(JSONNumber(integer: 71)))
}

private func checkResponse(_ bytes: Data, id: Int) throws {
    let object = try #require(try exchangeJSON(bytes).objectValue)
    #expect(object["id"] == .number(JSONNumber(integer: id)))
    #expect(object["result"]?.objectValue != nil)
}

private func recover(_ transport: StdioClientTransport) async throws {
    try await transport.exchange(exchangeRequest("probe/recover", id: 72)) { bytes in
        try checkResponse(bytes, id: 72)
    }
}

private func withExchangePeer(_ body: @Sendable (StdioClientTransport) async throws -> Void) async throws -> [JSON] {
    let log = ExchangePeerLog()
    let transport = StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
        arguments: ["-c", exchangePeerScript], maximumPendingRequests: 1,
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
    #expect(lines.dropFirst().dropLast().allSatisfy { $0.hasPrefix("RX:") })
    return try lines.filter { $0.hasPrefix("RX:") }.map { try exchangeJSON(Data($0.dropFirst(3).utf8)) }
}

private func methods(_ requests: [JSON]) -> [String] {
    requests.compactMap { $0.objectValue?["method"]?.stringValue }
}

private func cancellationIDs(_ requests: [JSON]) -> [JSON] {
    requests.filter { $0.objectValue?["method"]?.stringValue == "notifications/cancelled" }
        .compactMap { $0.objectValue?["params"]?.objectValue?["requestId"] }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioExchangeCancellationCases {
    @Test func terminalResponseDoesNotSendCancellation() async throws {
        let wire = try await withExchangePeer { transport in
            try await transport.exchange(exchangeRequest("probe/terminal")) { try checkResponse($0, id: 71) }
            try await recover(transport)
        }
        #expect(methods(wire) == ["probe/terminal", "probe/recover"])
    }

    @Test func terminalCallbackFailureDoesNotCancelCompletedRequest() async throws {
        let wire = try await withExchangePeer { transport in
            await #expect(throws: ExchangeProbeError.callback) {
                try await transport.exchange(exchangeRequest("probe/terminal")) { bytes in
                    try checkResponse(bytes, id: 71)
                    throw ExchangeProbeError.callback
                }
            }
            try await recover(transport)
        }
        #expect(methods(wire) == ["probe/terminal", "probe/recover"])
    }

    @Test func callerCancellationAfterACKSendsExactlyOneCancellationAndRecovers() async throws {
        let wire = try await withExchangePeer { transport in
            let ack = ExchangeSignal()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await transport.exchange(exchangeRequest("subscriptions/listen")) { bytes in
                        try checkACK(bytes)
                        ack.send()
                    }
                }
                try await ack.wait()
                group.cancelAll()
                await #expect(throws: CancellationError.self) { _ = try await group.next() }
            }
            try await recover(transport)
        }
        #expect(methods(wire) == ["subscriptions/listen", "notifications/cancelled", "probe/recover"])
        #expect(cancellationIDs(wire) == [.number(JSONNumber(integer: 71))])
    }

    @Test func nonterminalCallbackFailureCancelsActiveRequestAndRecovers() async throws {
        let wire = try await withExchangePeer { transport in
            await #expect(throws: ExchangeProbeError.callback) {
                try await transport.exchange(exchangeRequest("subscriptions/listen")) { bytes in
                    try checkACK(bytes)
                    throw ExchangeProbeError.callback
                }
            }
            try await recover(transport)
        }
        #expect(methods(wire) == ["subscriptions/listen", "notifications/cancelled", "probe/recover"])
        #expect(cancellationIDs(wire) == [.number(JSONNumber(integer: 71))])
    }

    @Test func alreadyCancelledExchangeNeverAdmitsRequest() async throws {
        let wire = try await withExchangePeer { transport in
            // Cancel this child before entering the public transport API.
            // The peer can reply if the buggy implementation sends the request;
            // RED therefore does not depend on a hang or deadline.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    withUnsafeCurrentTask { $0?.cancel() }
                    #expect(Task.isCancelled)
                    await #expect(throws: CancellationError.self) {
                        try await transport.exchange(exchangeRequest("probe/pre-cancelled")) { _ in
                            Issue.record("cancelled exchange delivered a response")
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await recover(transport)
        }
        #expect(methods(wire) == ["probe/recover"])
        #expect(cancellationIDs(wire).isEmpty)
    }
}
