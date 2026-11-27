// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum CorrelationProbeError: Error { case missingSignal }
private final class CorrelationSignal: Sendable {
    private let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func send() { pair.continuation.yield(()); pair.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.pair.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CorrelationProbeError.missingSignal }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CorrelationProbeError.missingSignal
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private final class CorrelationLog: Sendable {
    let ready = CorrelationSignal()
    private let storage = Mutex<[String]>([])
    func append(_ line: String) {
        storage.withLock { $0.append(line) }
        print("A22B3_PEER \(line)")
        if line == "READY" { ready.send() }
    }
    var lines: [String] { storage.withLock { $0 } }
    func requests() throws -> [JSONObject] {
        try lines.filter { $0.hasPrefix("RX:") }.map {
            try correlationObject(Data($0.dropFirst(3).utf8))
        }
    }
    func methods() throws -> [String] {
        try requests().map { try #require($0["method"]?.stringValue) }
    }
    func cancellationIDs() throws -> [JSON] {
        try requests().filter { $0["method"]?.stringValue == "notifications/cancelled" }
            .map { try #require($0["params"]?.objectValue?["requestId"]) }
    }
}

// Real finite newline-framed child; no private SDK hooks. Scenario selects
// only the response script, not the client behavior. TX means offered by
// the peer, not necessarily delivered to the receiver.
private let correlationPeer = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"probe/progress"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":17,"progress":1}}'
                printf '%s\n' TX:progress-integer >&2
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"17","progress":2}}'
                printf '%s\n' TX:progress-string >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","witness":"terminal"}}' ;;
            *'"method":"probe/scalar"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":"e\u0301","result":{"resultType":"complete","witness":"foreign"}}'
                printf '%s\n' TX:foreign-scalar >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":"\u00e9","result":{"resultType":"complete","witness":"exact"}}'
                printf '%s\n' TX:exact-scalar >&2 ;;
            *'"method":"subscriptions/listen"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71},"notifications":{"toolsListChanged":true}}}'
                printf '%s\n' TX:ack >&2
                case "$1" in
                    graceful|conflicting)
                        if [ "$1" = conflicting ]; then
                            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":72,"_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                            printf '%s\n' TX:conflicting-cancel >&2
                        fi
                        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":71,"_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                        printf '%s\n' TX:matching-cancel >&2
                        printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                        printf '%s\n' TX:terminal >&2 ;;
                    eof)
                        printf '%s\n' TX:abrupt-eof >&2
                        break ;;
                    partial)
                        printf '%s' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                        printf '%s\n' TX:unterminated-frame >&2
                        break ;;
                    reuse) : ;;
                    *) exit 42 ;;
                esac ;;
            *'"method":"probe/reuse"'*)
                # A request with the old ID must not have reached the peer.
                printf '%s\n' TX:late-on-reuse >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","witness":"old-response"}}' ;;
            *'"method":"probe/recover"'*)
                if [ "$1" = reuse ]; then
                    printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","witness":"late-old"}}'
                    printf '%s\n' TX:late-old >&2
                fi
                printf '%s\n' '{"jsonrpc":"2.0","id":73,"result":{"resultType":"complete","witness":"recovery"}}' ;;
            *'"method":"notifications/cancelled"'*) : ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func correlationObject(_ bytes: Data) throws -> JSONObject {
    try #require(try WireCodec.parse(Array(bytes), limits: .balanced).result.objectValue)
}

private func correlationRequest(_ method: String, id: Int = 71) -> OutgoingRequest {
    .init(id: .integer(JSONNumber(integer: id)), method: method, name: nil,
          body: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#.utf8))
}

private func withCorrelationPeer(_ scenario: String,
    _ body: @Sendable (StdioClientTransport) async throws -> Void) async throws -> CorrelationLog {
    let log = CorrelationLog()
    let transport = StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
        arguments: ["-c", correlationPeer, "correlation", scenario], maximumPendingRequests: 2,
        maximumMessageBytes: 4096, standardError: { log.append($0) }))
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

private func correlationRecover(_ transport: StdioClientTransport) async throws {
    try await transport.exchange(correlationRequest("probe/recover", id: 73)) { bytes in
        let object = try correlationObject(bytes)
        #expect(object["id"] == .number(JSONNumber(integer: 73)))
        #expect(object["result"]?.objectValue?["witness"]?.stringValue == "recovery")
    }
}

private func listenWitness(_ bytes: Data) throws -> String {
    let object = try correlationObject(bytes)
    if object["method"]?.stringValue == "notifications/subscriptions/acknowledged" {
        #expect(object["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] == .number(JSONNumber(integer: 71)))
        return "ack"
    }
    if object["method"]?.stringValue == "notifications/cancelled" {
        let number = try #require(object["params"]?.objectValue?["requestId"]?.numberValue)
        return "cancel:\(try number.integer(as: Int.self))"
    }
    #expect(object["id"] == .number(JSONNumber(integer: 71)))
    #expect(object["result"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/subscriptionId"] == .number(JSONNumber(integer: 71)))
    return "terminal"
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioEOFCorrelationCases {
    @Test func stringProgressTokenDoesNotAliasIntegerToken() async throws {
        try await checkProgress(integer: false)
    }
    @Test func integerProgressTokenIsDeliveredWithoutStringAliasing() async throws {
        try await checkProgress(integer: true)
    }
    private func checkProgress(integer: Bool) async throws {
        let trace = Mutex<[String]>([])
        let token = integer ? "17" : #""17""#
        let request = OutgoingRequest(id: .integer(JSONNumber(integer: 71)), method: "probe/progress", name: nil,
            body: Data(#"{"jsonrpc":"2.0","id":71,"method":"probe/progress","params":{"_meta":{"progressToken":\#(token)}}}"#.utf8))
        let log = try await withCorrelationPeer("progress") { transport in
            try await transport.exchange(request) { bytes in
                let object = try correlationObject(bytes)
                let label: String
                if object["method"]?.stringValue == "notifications/progress" {
                    let value = try #require(object["params"]?.objectValue?["progressToken"])
                    label = value == .number(JSONNumber(integer: 17)) ? "integer" :
                        (value == .string("17") ? "string" : "unexpected")
                } else {
                    #expect(object["id"] == .number(JSONNumber(integer: 71)))
                    #expect(object["result"]?.objectValue?["witness"]?.stringValue == "terminal")
                    label = "terminal"
                }
                trace.withLock { $0.append(label) }
            }
            try await correlationRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3_PROGRESS integer=\(integer) trace=\(actual)")
        #expect(actual == [integer ? "integer" : "string", "terminal"])
        #expect(log.lines.contains("TX:progress-integer") && log.lines.contains("TX:progress-string"))
        #expect(try log.methods() == ["probe/progress", "probe/recover"])
        #expect(try log.cancellationIDs().isEmpty)
    }

    @Test func scalarDistinctResponseCannotCompleteAnotherStringID() async throws {
        let trace = Mutex<[String]>([])
        let id = ScalarText("\u{00E9}")
        let request = OutgoingRequest(id: .string(id), method: "probe/scalar", name: nil,
            body: Data(#"{"jsonrpc":"2.0","id":"\u00e9","method":"probe/scalar"}"#.utf8))
        let log = try await withCorrelationPeer("scalar") { transport in
            try await transport.exchange(request) { bytes in
                let object = try correlationObject(bytes)
                let actualID = try #require(object["id"]?.stringValue)
                let witness = try #require(object["result"]?.objectValue?["witness"]?.stringValue)
                #expect(ScalarText(actualID) == id)
                trace.withLock { $0.append(witness) }
            }
            try await correlationRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3_SCALAR trace=\(actual)")
        #expect(actual == ["exact"])
        #expect(log.lines.contains("TX:foreign-scalar") && log.lines.contains("TX:exact-scalar"))
        #expect(try log.methods() == ["probe/scalar", "probe/recover"])
        #expect(try log.cancellationIDs().isEmpty)
    }

    @Test func serverCancellationAndGracefulTerminalPreserveOrder() async throws {
        try await checkServerCancellation(conflicting: false)
    }
    @Test func conflictingCancellationIdentityDoesNotReachListenReceiver() async throws {
        try await checkServerCancellation(conflicting: true)
    }
    private func checkServerCancellation(conflicting: Bool) async throws {
        let trace = Mutex<[String]>([])
        let log = try await withCorrelationPeer(conflicting ? "conflicting" : "graceful") { transport in
            try await transport.exchange(correlationRequest("subscriptions/listen")) { bytes in
                let witness = try listenWitness(bytes)
                trace.withLock { $0.append(witness) }
            }
            try await correlationRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3_SERVER_CANCEL conflicting=\(conflicting) trace=\(actual)")
        #expect(actual == ["ack", "cancel:71", "terminal"])
        #expect(log.lines.contains("TX:matching-cancel") && log.lines.contains("TX:terminal"))
        #expect(log.lines.contains("TX:conflicting-cancel") == conflicting)
        #expect(try log.methods() == ["subscriptions/listen", "probe/recover"])
        #expect(try log.cancellationIDs().isEmpty)
    }

    @Test func acknowledgedListenWithoutTerminalFailsAtEOF() async throws {
        try await checkEOF(partial: false)
    }
    @Test func unterminatedJSONLineCannotBecomeGracefulTerminal() async throws {
        try await checkEOF(partial: true)
    }
    private func checkEOF(partial: Bool) async throws {
        let trace = Mutex<[String]>([])
        let log = try await withCorrelationPeer(partial ? "partial" : "eof") { transport in
            await #expect(throws: StdioClientTransportError.serverExited) {
                try await transport.exchange(correlationRequest("subscriptions/listen")) { bytes in
                    let witness = try listenWitness(bytes)
                    trace.withLock { $0.append(witness) }
                }
            }
        }
        let actual = trace.withLock { $0 }
        print("A22B3_EOF partial=\(partial) trace=\(actual)")
        #expect(actual == ["ack"])
        #expect(log.lines.contains(partial ? "TX:unterminated-frame" : "TX:abrupt-eof"))
        #expect(try log.methods() == ["subscriptions/listen"])
        #expect(try log.cancellationIDs().isEmpty)
    }

    @Test func cancelledUnansweredIDCannotBeReissuedIntoOldResponse() async throws {
        let ack = CorrelationSignal(), trace = Mutex<[String]>([])
        let log = try await withCorrelationPeer("reuse") { transport in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await transport.exchange(correlationRequest("subscriptions/listen")) { bytes in
                        #expect(try listenWitness(bytes) == "ack")
                        ack.send()
                    }
                }
                do { try await ack.wait() }
                catch { group.cancelAll(); throw error }
                group.cancelAll()
                await #expect(throws: CancellationError.self) { _ = try await group.next() }
            }
            // The first request was cancelled but no response was received.
            // Reject reuse locally; a unique ID must remain usable.
            await #expect(throws: StdioClientTransportError.busy) {
                try await transport.exchange(correlationRequest("probe/reuse")) { bytes in
                    let object = try correlationObject(bytes)
                    let witness = try #require(object["result"]?.objectValue?["witness"]?.stringValue)
                    trace.withLock { $0.append(witness) }
                }
            }
            try await correlationRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3_REUSE trace=\(actual)")
        #expect(actual.isEmpty)
        #expect(!log.lines.contains("TX:late-on-reuse"))
        #expect(log.lines.contains("TX:late-old"))
        #expect(try log.methods() == ["subscriptions/listen", "notifications/cancelled", "probe/recover"])
        #expect(try log.cancellationIDs() == [.number(JSONNumber(integer: 71))])
    }
}
