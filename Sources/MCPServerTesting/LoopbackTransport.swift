// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPClient
import MCPProtocol
import MCPServer

/// Connects an `MCPClient.Client` directly to a `Server` in the same process, with HTTP
/// delivery semantics: every request has its own stream of notifications and one response.
/// No bytes leave the process; the server sees `principal` and `origin` as authenticated.
public struct LoopbackTransport: ClientTransport {
    public let server: Server
    public let principal: VerifiedPrincipal
    public let origin: ScalarText
    public init(server: Server, principal: VerifiedPrincipal, origin: ScalarText = ScalarText("loopback")) {
        self.server = server; self.principal = principal; self.origin = origin
    }
    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await server.dispatchEvents(request.body, principal: principal, origin: origin, mode: .http) { try await receive($0) }
    }
}
