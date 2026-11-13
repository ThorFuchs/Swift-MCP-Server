// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol

/// One encoded request and the routing data a transport needs (HTTP sets `Mcp-Method` and
/// `Mcp-Name` from it).
public struct OutgoingRequest: Sendable {
    public let id: RequestID
    public let method: String
    /// `params.name` or `params.uri` for methods that route by name (tools/call, prompts/get,
    /// resources/read) and the task ID for `tasks/*`; nil otherwise.
    public let name: String?
    /// The complete JSON-RPC request, UTF-8 encoded.
    public let body: Data
    /// Already-encoded `Mcp-Param-*` headers for `tools/call` (see `ToolHeaders`).
    public let parameterHeaders: [(name: String, value: String)]
    public init(id: RequestID, method: String, name: String?, body: Data, parameterHeaders: [(name: String, value: String)] = []) {
        self.id = id; self.method = method; self.name = name; self.body = body; self.parameterHeaders = parameterHeaders
    }
}

/// Carries one request to its terminal response.
///
/// `exchange` delivers every message the server sends for this request, in order: request
/// scoped notifications (progress, log messages, or a listen stream's events) and finally
/// the response. It returns after the response, or throws when the exchange ends without
/// one. Awaiting `receive` is the backpressure: a transport never buffers without bound.
/// Cancelling the calling task cancels the exchange (stdio sends `notifications/cancelled`,
/// HTTP closes the stream). Transports never interpret results.
public protocol ClientTransport: Sendable {
    func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws
    /// Whether this transport mirrors `x-mcp-header` tool parameters into headers. Such
    /// transports (Streamable HTTP) require the client to drop tools whose annotations are
    /// invalid; others may ignore the annotations.
    var mirrorsToolParameters: Bool { get }
}

extension ClientTransport {
    public var mirrorsToolParameters: Bool { false }
}
