// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol
import MCPServer

/// Bounded ordered observations through the production dispatcher. It owns no
/// credentials or server task. Recording capacity is independent of server work;
/// exhaustion throws, including when a provider already produced a response.
public struct InProcessHarness: Sendable {
    public let server: Server
    private let recorder: ExchangeRecorder
    public init(server: Server, maximumExchanges: Int = 128, maximumRecordedBytes: Int = 8_388_608) throws {
        self.server = server; recorder = try .init(countLimit: maximumExchanges, byteLimit: maximumRecordedBytes)
    }
    public func exchange(_ request: Data, principal: VerifiedPrincipal, origin: ScalarText) async throws -> Data? {
        let ticket = try await recorder.begin(request)
        let response: Data?
        do { response = try await server.handle(request, principal: principal, origin: origin) }
        catch {
            try await recorder.finish(ticket, response: nil, outcome: .failed)
            throw error
        }
        try await recorder.finish(ticket, response: response, outcome: .completed)
        return response
    }
    public var exchanges: [RecordedExchange] { get async { await recorder.snapshot } }
}
