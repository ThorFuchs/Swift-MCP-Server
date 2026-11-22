// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A copyable request against this app's running local server, in the exact shape the SDK's
/// `HTTPClientTransport` sends for MCP 2026-07-28: one stateless POST per request with
/// `MCP-Protocol-Version`, `Mcp-Method` (and `Mcp-Name` for `tools/call`), and the protocol version
/// and client capabilities in `params._meta`. There is no `initialize` handshake and no session.
/// The sheet shows `curl`; tests execute the same model against a live host.
public struct ConnectionRecipe: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let endpoint: URL
    public let headers: [Header]
    public let body: String
    public struct Header: Sendable, Equatable { public let name, value: String }

    static let protocolVersion = "2026-07-28"
    static func meta() -> String {
        #""_meta":{"io.modelcontextprotocol/protocolVersion":"\#(protocolVersion)","io.modelcontextprotocol/clientCapabilities":{}}"#
    }
    private static func headers(method: String, name: String?) -> [Header] {
        var h = [Header(name: "Content-Type", value: "application/json"),
                 Header(name: "Accept", value: "application/json, text/event-stream"),
                 Header(name: "MCP-Protocol-Version", value: protocolVersion),
                 Header(name: "Mcp-Method", value: method)]
        if let name { h.append(.init(name: "Mcp-Name", value: name)) }
        return h
    }

    /// Recipes for the announced loopback endpoint; nil when it is not a loopback URL.
    public static func recipes(for endpoint: ServerEndpoint, source: ResearchSource) -> [ConnectionRecipe] {
        guard let url = URL(string: endpoint.url), url.scheme == "http", url.host == "127.0.0.1" else { return [] }
        let query = source == .offlineDemo ? OfflineTour.query : "Noether"
        return [
            .init(title: "Discover the server", endpoint: url, headers: headers(method: "server/discover", name: nil),
                  body: #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(meta())}}"#),
            .init(title: "List the tools", endpoint: url, headers: headers(method: "tools/list", name: nil),
                  body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(meta())}}"#),
            .init(title: "Call search_articles", endpoint: url, headers: headers(method: "tools/call", name: "search_articles"),
                  body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{\#(meta()),"name":"search_articles","arguments":{"query":"\#(query)","project":"\#(source.project)","limit":5}}}"#),
        ]
    }

    /// Shell command; every value is single-quoted and contains no single quote.
    public var curl: String {
        (["curl -sS -X POST '\(endpoint.absoluteString)'"] + headers.map { "  -H '\($0.name): \($0.value)'" } + ["  --data '\(body)'"])
            .joined(separator: " \\\n")
    }
}
