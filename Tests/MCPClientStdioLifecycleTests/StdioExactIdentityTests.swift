// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPClientStdio
import MCPProtocol
import Subprocess

private enum IdentityProbeError: Error { case readiness }
private final class IdentityPeerLog: Sendable {
    private let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let storage = Mutex<[String]>([])
    func append(_ line: String) {
        storage.withLock { $0.append(line) }
        print("A22B3A_PEER \(line)")
        if line == "READY" { ready.continuation.yield(()); ready.continuation.finish() }
    }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.ready.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw IdentityProbeError.readiness }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw IdentityProbeError.readiness
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    var lines: [String] { storage.withLock { $0 } }
    func methods() throws -> [String] {
        try lines.filter { $0.hasPrefix("RX:") }.map {
            let object = try identityObject(Data($0.dropFirst(3).utf8))
            return try #require(object["method"]?.stringValue)
        }
    }
}

// Every admitted request has a finite scripted response. The outer
// progress callback starts a distinct exchange; the peer emits frames
// for both before returning the inner terminal. No timing-based order.
private let identityPeer = #"""
    printf '%s\n' READY >&2
    while IFS= read -r line; do
        printf 'RX:%s\n' "$line" >&2
        case "$line" in
            *'"method":"probe/scalar-outer"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"\u00e9","progress":1,"message":"outer-start"}}' ;;
            *'"method":"probe/scalar-inner"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"\u00e9","progress":2,"message":"outer-progress"}}'
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"e\u0301","progress":1,"message":"inner-progress"}}'
                printf '%s\n' '{"jsonrpc":"2.0","id":"\u00e9","result":{"resultType":"complete","witness":"outer-terminal"}}'
                printf '%s\n' '{"jsonrpc":"2.0","id":"e\u0301","result":{"resultType":"complete","witness":"inner-terminal"}}'
                printf '%s\n' TX:scalar-interleaved >&2 ;;
            *'"method":"probe/large"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1e23,"progress":1,"message":"large-progress"}}'
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"100000000000000000000000","progress":2,"message":"foreign-string"}}'
                printf '%s\n' '{"jsonrpc":"2.0","id":9223372036854775808e1,"result":{"resultType":"complete","witness":"equivalent-terminal"}}'
                printf '%s\n' TX:large-equivalent >&2
                break ;;
            *'"method":"probe/token-owner"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"shared","progress":1,"message":"owner-start"}}' ;;
            *'"method":"probe/duplicate-token"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":72,"result":{"resultType":"complete","witness":"unexpected-duplicate"}}' ;;
            *'"method":"probe/unique-token"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","witness":"owner-terminal"}}'
                printf '%s\n' '{"jsonrpc":"2.0","id":73,"result":{"resultType":"complete","witness":"unique-terminal"}}' ;;
            *'"method":"probe/ordinary"'*)
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":71,"_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":71}}}'
                printf '%s\n' TX:foreign-subscription >&2
                printf '%s\n' '{"jsonrpc":"2.0","id":71,"result":{"resultType":"complete","witness":"ordinary-terminal"}}' ;;
            *'"method":"probe/recover"'*)
                printf '%s\n' '{"jsonrpc":"2.0","id":74,"result":{"resultType":"complete","witness":"recovery"}}' ;;
            *'"method":"notifications/cancelled"'*) : ;;
            *) exit 41 ;;
        esac
    done
    printf '%s\n' CLEAN >&2
    exit 0
    """#

private func identityObject(_ bytes: Data) throws -> JSONObject {
    try #require(try WireCodec.parse(Array(bytes), limits: .balanced).result.objectValue)
}

private func identityWitness(_ bytes: Data) throws -> String {
    let object = try identityObject(bytes)
    if object["method"]?.stringValue == "notifications/progress" {
        return try #require(object["params"]?.objectValue?["message"]?.stringValue)
    }
    if let method = object["method"]?.stringValue { return method }
    return try #require(object["result"]?.objectValue?["witness"]?.stringValue)
}

private func identityRequest(_ method: String, id: RequestID, wireID: String, token: String? = nil) -> OutgoingRequest {
    let params = token.map { #","params":{"_meta":{"progressToken":\#($0)}}"# } ?? ""
    return .init(id: id, method: method, name: nil,
        body: Data(#"{"jsonrpc":"2.0","id":\#(wireID),"method":"\#(method)"\#(params)}"#.utf8))
}

private func numberedIdentityRequest(_ method: String, id: Int, token: String? = nil) -> OutgoingRequest {
    identityRequest(method, id: .integer(JSONNumber(integer: id)), wireID: String(id), token: token)
}

private func withIdentityPeer(_ body: @Sendable (StdioClientTransport) async throws -> Void) async throws -> IdentityPeerLog {
    let log = IdentityPeerLog()
    let transport = StdioClientTransport(configuration: .init(executable: .path("/bin/sh"),
        arguments: ["-c", identityPeer], maximumPendingRequests: 2,
        maximumMessageBytes: 4096, standardError: { log.append($0) }))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await transport.run() }
        do { try await log.wait(); try await body(transport) }
        catch { transport.shutdown(); group.cancelAll(); throw error }
        transport.shutdown()
        try await group.waitForAll()
    }
    #expect(log.lines.first == "READY" && log.lines.last == "CLEAN")
    return log
}

private func identityRecover(_ transport: StdioClientTransport) async throws {
    try await transport.exchange(numberedIdentityRequest("probe/recover", id: 74)) { bytes in
        let witness = try identityWitness(bytes)
        #expect(witness == "recovery")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct StdioExactIdentityCases {
    @Test func simultaneousScalarDistinctIDsAndTokensRemainIndependent() async throws {
        let trace = Mutex<[String]>([])
        let outer = identityRequest("probe/scalar-outer", id: .string(ScalarText("\u{00E9}")), wireID: #""\u00e9""#, token: #""\u00e9""#)
        let inner = identityRequest("probe/scalar-inner", id: .string(ScalarText("e\u{0301}")), wireID: #""e\u0301""#, token: #""e\u0301""#)
        let log = try await withIdentityPeer { transport in
            try await transport.exchange(outer) { bytes in
                let witness = try identityWitness(bytes)
                trace.withLock { $0.append(witness) }
                if witness == "outer-start" {
                    try await transport.exchange(inner) { frame in
                        let witness = try identityWitness(frame)
                        trace.withLock { $0.append(witness) }
                    }
                }
            }
            try await identityRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3A_SCALAR_PAIR trace=\(actual)")
        #expect(actual == ["outer-start", "inner-progress", "inner-terminal", "outer-progress", "outer-terminal"])
        #expect(log.lines.contains("TX:scalar-interleaved"))
        #expect(try log.methods() == ["probe/scalar-outer", "probe/scalar-inner", "probe/recover"])
    }

    @Test func largeMathematicalIntegerIDsAndTokensUseEquivalentSpellings() async throws {
        let trace = Mutex<[String]>([])
        let id = try JSONNumber(parsing: "92233720368547758080")
        let request = identityRequest("probe/large", id: .integer(id), wireID: "92233720368547758080", token: "100000000000000000000000")
        let log = try await withIdentityPeer { transport in
            try await transport.exchange(request) { bytes in
                let witness = try identityWitness(bytes)
                trace.withLock { $0.append(witness) }
            }
        }
        let actual = trace.withLock { $0 }
        print("A22B3A_LARGE trace=\(actual)")
        #expect(actual == ["large-progress", "equivalent-terminal"])
        #expect(log.lines.contains("TX:large-equivalent"))
        #expect(try log.methods() == ["probe/large"])
    }

    @Test func duplicateActiveProgressTokenRefusesSecondRequest() async throws {
        let trace = Mutex<[String]>([])
        let log = try await withIdentityPeer { transport in
            try await transport.exchange(numberedIdentityRequest("probe/token-owner", id: 71, token: #""shared""#)) { bytes in
                let witness = try identityWitness(bytes)
                trace.withLock { $0.append(witness) }
                if witness == "owner-start" {
                    await #expect(throws: StdioClientTransportError.busy) {
                        try await transport.exchange(numberedIdentityRequest("probe/duplicate-token", id: 72, token: #""shared""#)) { frame in
                            let witness = try identityWitness(frame)
                            trace.withLock { $0.append(witness) }
                        }
                    }
                    try await transport.exchange(numberedIdentityRequest("probe/unique-token", id: 73, token: #""unique""#)) { frame in
                        let witness = try identityWitness(frame)
                        trace.withLock { $0.append(witness) }
                    }
                }
            }
            try await identityRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3A_DUPLICATE trace=\(actual)")
        #expect(actual == ["owner-start", "unique-terminal", "owner-terminal"])
        #expect(try log.methods() == ["probe/token-owner", "probe/unique-token", "probe/recover"])
    }

    @Test func subscriptionNotificationsCannotReachOrdinaryRequest() async throws {
        let trace = Mutex<[String]>([])
        let log = try await withIdentityPeer { transport in
            try await transport.exchange(numberedIdentityRequest("probe/ordinary", id: 71)) { bytes in
                let witness = try identityWitness(bytes)
                trace.withLock { $0.append(witness) }
            }
            try await identityRecover(transport)
        }
        let actual = trace.withLock { $0 }
        print("A22B3A_NONLISTEN trace=\(actual)")
        #expect(actual == ["ordinary-terminal"])
        #expect(log.lines.contains("TX:foreign-subscription"))
        #expect(try log.methods() == ["probe/ordinary", "probe/recover"])
    }
}
