// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

private enum BoundaryFailure: Error, Sendable {
    case unexpectedRequest
    case rendezvousDeadline
}

private func boundaryAck(_ id: String, _ filter: String) -> String {
    #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)},"notifications":\#(filter)}}"#
}

private func boundaryEvent(_ id: String, _ method: String, extra: String = "") -> String {
    #"{"jsonrpc":"2.0","method":"\#(method)","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)}\#(extra)}}"#
}

private func boundaryClose(_ id: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)}}}"#
}

/// The first exchange pauses after its ACK until the second has delivered
/// its own ACK. Timeout bounds a missing rendezvous, not event sequencing.
private final class ListenOverlap: Sendable {
    private let arrived = Mutex(0)
    private let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func meet() async throws {
        let previous = arrived.withLock { count in
            let previous = count; count += 1; return previous
        }
        if previous == 1 {
            release.continuation.yield(())
            release.continuation.finish()
            return
        }
        guard previous == 0 else { throw BoundaryFailure.unexpectedRequest }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.release.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw BoundaryFailure.rendezvousDeadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private struct BoundaryTransport: ClientTransport {
    let script: @Sendable (String, JSONObject) throws -> [String]
    var overlap: ListenOverlap? = nil

    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard request.method == "subscriptions/listen" else { throw BoundaryFailure.unexpectedRequest }
        let body = try WireCodec.parse(Array(request.body), limits: .balanced).result
        guard let filter = body.objectValue?["params"]?.objectValue?["notifications"]?.objectValue else {
            throw BoundaryFailure.unexpectedRequest
        }
        let id = String(decoding: try WireCodec.write(request.id.value, limits: .balanced).result, as: UTF8.self)
        for (index, frame) in try script(id, filter).enumerated() {
            try await receive(Data(frame.utf8))
            if index == 0 { try await overlap?.meet() }
        }
    }
}

private func boundaryLabel(_ event: ListenEvent) -> String {
    switch event {
    case .acknowledged: "ack"
    case .toolsChanged: "tools"
    case .promptsChanged: "prompts"
    case .resourcesChanged: "resources"
    case .resourceUpdated(let uri): "uri:" + uri
    case .notification(let method, _): method
    }
}

@Suite(.serialized) struct ClientListenBoundaryCases {
    private static let tools = #"{"toolsListChanged":true}"#
    private static let uriA = "file:///one"
    private static let uriB = "file:///two"

    @Test func resourceSubsetAndExtensionPayloadRemainUsable() async throws {
        let transport = BoundaryTransport(script: { id, _ in
            [boundaryAck(id, #"{"resourceSubscriptions":["file:///one"],"taskIds":["t1"]}"#),
             boundaryEvent(id, "notifications/resources/updated", extra: #","uri":"file:///one""#),
             boundaryEvent(id, "notifications/tasks", extra: #","taskId":"t1","status":"completed""#),
             boundaryEvent(id, "notifications/cancelled", extra: #","requestId":\#(id)"#),
             boundaryClose(id)]
        })
        let seen = Mutex<[String]>([])
        try await Client(transport: transport).listen(.init(resourceSubscriptions: [Self.uriA, Self.uriB],
            extensions: ["taskIds": .array([.string("t1"), .string("t2")])])) { event in
                if case .acknowledged(let raw) = event {
                    #expect(raw.objectValue?["taskIds"]?.arrayValue?.compactMap(\.stringValue) == ["t1"])
                }
                if case .notification(let method, let raw) = event {
                    #expect(method == "notifications/tasks")
                    #expect(raw.objectValue?["taskId"]?.stringValue == "t1")
                    #expect(raw.objectValue?["status"]?.stringValue == "completed")
                }
                seen.withLock { $0.append(boundaryLabel(event)) }
            }
        #expect(seen.withLock { $0 } == ["ack", "uri:file:///one", "notifications/tasks"])
    }

    private func reject(_ transport: BoundaryTransport, filter: SubscriptionFilter,
                        events: [String]) async throws {
        let seen = Mutex<[String]>([])
        do {
            try await Client(transport: transport).listen(filter) { event in
                seen.withLock { $0.append(boundaryLabel(event)) }
            }
            Issue.record("invalid subscription unexpectedly completed")
        } catch ClientError.invalidResponse(_) {
            // Exact local failure category, not an arbitrary transport error.
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(seen.withLock { $0 } == events)
    }

    @Test func acknowledgementCannotAddUnrequestedResourceURI() async throws {
        try await reject(.init(script: { id, _ in
            [boundaryAck(id, #"{"resourceSubscriptions":["file:///two"]}"#), boundaryClose(id)]
        }), filter: .init(resourceSubscriptions: [Self.uriA]), events: [])
    }

    @Test func resourceUpdateMustUseAnAcknowledgedURI() async throws {
        try await reject(.init(script: { id, _ in
            [boundaryAck(id, #"{"resourceSubscriptions":["file:///one"]}"#),
             boundaryEvent(id, "notifications/resources/updated", extra: #","uri":"file:///two""#), boundaryClose(id)]
        }), filter: .init(resourceSubscriptions: [Self.uriA, Self.uriB]), events: ["ack"])
    }

    @Test func foreignExtensionEventDoesNotReachHost() async throws {
        try await reject(.init(script: { id, _ in
            [boundaryAck(id, #"{"taskIds":["t1"]}"#),
             boundaryEvent(#""foreign""#, "notifications/tasks", extra: #","taskId":"t1""#), boundaryClose(id)]
        }), filter: .init(extensions: ["taskIds": .array([.string("t1")])]), events: ["ack"])
    }

    @Test func gracefulCompletionRequiresAcknowledgement() async throws {
        try await reject(.init(script: { id, _ in [boundaryClose(id)] }),
                         filter: .init(toolsListChanged: true), events: [])
    }

    @Test func serverErrorBeforeAcknowledgementRemainsTyped() async throws {
        let transport = BoundaryTransport(script: { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"invalid filter"}}"#]
        })
        await #expect(throws: ClientError.server(code: -32602, message: "invalid filter", data: nil)) {
            try await Client(transport: transport).listen(.init(toolsListChanged: true)) { _ in
                Issue.record("unexpected callback on error response")
            }
        }
    }

    @Test func notificationAfterTerminalResponseDoesNotReachHost() async throws {
        try await reject(.init(script: { id, _ in
            [boundaryAck(id, Self.tools), boundaryClose(id), boundaryEvent(id, "notifications/tools/list_changed")]
        }), filter: .init(toolsListChanged: true), events: ["ack"])
    }

    @Test func concurrentSubscriptionsKeepDistinctAcknowledgedFilters() async throws {
        let transport = BoundaryTransport(script: { id, filter in
            if filter["toolsListChanged"]?.booleanValue == true {
                return [boundaryAck(id, Self.tools), boundaryEvent(id, "notifications/tools/list_changed"), boundaryClose(id)]
            }
            if filter["promptsListChanged"]?.booleanValue == true {
                return [boundaryAck(id, #"{"promptsListChanged":true}"#), boundaryEvent(id, "notifications/prompts/list_changed"), boundaryClose(id)]
            }
            throw BoundaryFailure.unexpectedRequest
        }, overlap: ListenOverlap())
        let client = Client(transport: transport)
        let tools = Mutex<[String]>([]), prompts = Mutex<[String]>([])
        async let first: Void = client.listen(.init(toolsListChanged: true)) { event in
            tools.withLock { $0.append(boundaryLabel(event)) }
        }
        async let second: Void = client.listen(.init(promptsListChanged: true)) { event in
            prompts.withLock { $0.append(boundaryLabel(event)) }
        }
        _ = try await (first, second)
        #expect(tools.withLock { $0 } == ["ack", "tools"])
        #expect(prompts.withLock { $0 } == ["ack", "prompts"])
    }
}
