// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPProtocol

// The transport intentionally delivers adversarial frames to one exchange.
// Only public Client/ClientTransport APIs are used. Correlation uses the actual
// outgoing request ID, never a hard-coded assumption about Client's counter.
private enum ListenScriptFailure: Error, Equatable, Sendable {
    case unexpectedRequest
    case hostCallback
}

private enum ListenFrame: Sendable {
    case ack(String, foreign: Bool = false)
    case changed(String, foreign: Bool = false)
    case close(foreign: Bool = false)

    func bytes(id: JSON) throws -> Data {
        let requestID = String(decoding: try WireCodec.write(id, limits: .balanced).result, as: UTF8.self)
        let foreignID = #""foreign-subscription""#
        let text: String
        switch self {
        case .ack(let filter, let foreign):
            text = #"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":\#(foreign ? foreignID : requestID)},"notifications":\#(filter)}}"#
        case .changed(let kind, let foreign):
            text = #"{"jsonrpc":"2.0","method":"notifications/\#(kind)/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":\#(foreign ? foreignID : requestID)}}}"#
        case .close(let foreign):
            text = #"{"jsonrpc":"2.0","id":\#(requestID),"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":\#(foreign ? foreignID : requestID)}}}"#
        }
        return Data(text.utf8)
    }
}

private final class ListenScriptTransport: ClientTransport, Sendable {
    private let frames: [ListenFrame]
    private let requestCount = Mutex(0)
    private let deliveries = Mutex(0)
    init(_ frames: [ListenFrame]) { self.frames = frames }
    var exchanges: Int { requestCount.withLock { $0 } }
    var delivered: Int { deliveries.withLock { $0 } }

    func exchange(_ request: OutgoingRequest,
                  receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let previous = requestCount.withLock { count in
            let previous = count; count += 1; return previous
        }
        guard previous == 0, request.method == "subscriptions/listen" else {
            throw ListenScriptFailure.unexpectedRequest
        }
        for frame in frames {
            deliveries.withLock { $0 += 1 }
            try await receive(try frame.bytes(id: request.id.value))
        }
    }
}

private final class ListenObservations: Sendable {
    private let storage = Mutex<[String]>([])
    var events: [String] { storage.withLock { $0 } }
    func record(_ event: ListenEvent) {
        let value: String
        switch event {
        case .acknowledged: value = "ack"
        case .toolsChanged: value = "tools"
        case .promptsChanged: value = "prompts"
        case .resourcesChanged: value = "resources"
        case .resourceUpdated: value = "resource"
        case .notification: value = "extension"
        }
        storage.withLock { $0.append(value) }
    }
}

@Suite(.serialized) struct ClientListenInvariantCases {
    private static let tools = #"{"toolsListChanged":true}"#
    private static let toolsAndPrompts = #"{"toolsListChanged":true,"promptsListChanged":true}"#

    // Positive control: a server may acknowledge only the supported subset.
    @Test func acknowledgedSubsetReceivesOnlyAgreedEventsAndCloses() async throws {
        let transport = ListenScriptTransport([.ack(Self.tools), .changed("tools"), .close()])
        let observed = ListenObservations()
        try await Client(transport: transport).listen(
            .init(toolsListChanged: true, promptsListChanged: true)) { event in
                if case .acknowledged(let agreed) = event {
                    #expect(agreed.objectValue?["toolsListChanged"]?.booleanValue == true)
                    #expect(agreed.objectValue?["promptsListChanged"] == nil)
                }
                observed.record(event)
            }
        #expect(observed.events == ["ack", "tools"])
        #expect(transport.exchanges == 1 && transport.delivered == 3)
    }

    // Positive control: a host callback error must propagate unchanged and
    // a compliant scripted transport must not deliver subsequent frames.
    @Test func callbackFailureTerminatesExchangeWithoutLaterDelivery() async throws {
        let transport = ListenScriptTransport([.ack(Self.tools), .changed("tools"), .close()])
        let observed = ListenObservations()
        await #expect(throws: ListenScriptFailure.hostCallback) {
            try await Client(transport: transport).listen(.init(toolsListChanged: true)) { event in
                observed.record(event)
                throw ListenScriptFailure.hostCallback
            }
        }
        #expect(observed.events == ["ack"])
        #expect(transport.exchanges == 1 && transport.delivered == 1)
    }

    private func rejected(_ frames: [ListenFrame], filter: SubscriptionFilter = .init(toolsListChanged: true),
                          events: [String]) async throws {
        let transport = ListenScriptTransport(frames)
        let observed = ListenObservations()
        do {
            try await Client(transport: transport).listen(filter) { observed.record($0) }
            Issue.record("invalid subscription sequence unexpectedly completed")
        } catch ClientError.invalidResponse(_) {
            // Specific local failure class; error text is not part of the contract.
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(observed.events == events)
        #expect(transport.exchanges == 1)
        #expect(transport.delivered == events.count + 1)
    }

    @Test func eventBeforeAcknowledgementDoesNotReachHost() async throws {
        try await rejected([.changed("tools"), .ack(Self.tools), .close()], events: [])
    }

    @Test func foreignAcknowledgementDoesNotReachHost() async throws {
        try await rejected([.ack(Self.tools, foreign: true), .close()], events: [])
    }

    @Test func duplicateAcknowledgementDoesNotReachHost() async throws {
        try await rejected([.ack(Self.tools), .ack(Self.tools), .close()], events: ["ack"])
    }

    @Test func acknowledgementCannotExpandRequestedFilter() async throws {
        try await rejected([.ack(Self.toolsAndPrompts), .close()], events: [])
    }

    @Test func foreignEventDoesNotReachHost() async throws {
        try await rejected([.ack(Self.tools), .changed("tools", foreign: true), .close()], events: ["ack"])
    }

    @Test func requestedButUnacknowledgedEventDoesNotReachHost() async throws {
        try await rejected([.ack(Self.tools), .changed("prompts"), .close()],
                           filter: .init(toolsListChanged: true, promptsListChanged: true), events: ["ack"])
    }

    @Test func foreignTerminalSubscriptionMetadataIsRejected() async throws {
        try await rejected([.ack(Self.tools), .close(foreign: true)], events: ["ack"])
    }
}
