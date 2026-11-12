// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

/// Answers a server's input request (MRTR). Receives the request's `params` and returns
/// the result object (`ElicitResult`, `CreateMessageResult` or `ListRootsResult`).
public typealias InputHandler = @Sendable (JSON) async throws -> JSON

public struct ClientConfiguration: Sendable {
    public struct Elicitation: Sendable {
        public var form: Bool, url: Bool
        public let handler: InputHandler
        public init(form: Bool = true, url: Bool = false, handler: @escaping InputHandler) {
            self.form = form; self.url = url; self.handler = handler
        }
    }
    /// Sent as `io.modelcontextprotocol/clientInfo` (name and version required).
    public var info: JSON?
    /// Answers `elicitation/create`; declares the `elicitation` capability with its modes.
    public var elicitation: Elicitation?
    /// Answers `sampling/createMessage`; declares `sampling`.
    public var sampling: InputHandler?
    /// Answers `roots/list`; declares `roots`.
    public var roots: InputHandler?
    /// Extension declarations sent in `clientCapabilities.extensions`, by identifier.
    public var extensions: [String: JSON]
    /// `io.modelcontextprotocol/logLevel` for requests with a log handler.
    public var logLevel: String?
    /// Input rounds per request before `ClientError.tooManyInputRounds`.
    public var maximumInputRounds: Int
    /// Bounds for parsing every message received.
    public var limits: JSONLimits
    /// Checks `structuredContent` of successful tool results against the tool's
    /// `outputSchema` from `tools/list` (default `true`). Elicitation content is always
    /// checked against `requestedSchema`.
    public var validatesStructuredContent: Bool = true
    public init(info: JSON? = nil, elicitation: Elicitation? = nil, sampling: InputHandler? = nil, roots: InputHandler? = nil,
                extensions: [String: JSON] = [:], logLevel: String? = nil, maximumInputRounds: Int = 8, limits: JSONLimits = .balanced) {
        self.info = info; self.elicitation = elicitation; self.sampling = sampling; self.roots = roots
        self.extensions = extensions; self.logLevel = logLevel; self.maximumInputRounds = max(1, maximumInputRounds); self.limits = limits
    }

    /// Capabilities that follow from the configured handlers and extensions.
    func capabilities() throws -> JSON {
        var members: [JSONMember] = []
        let empty = JSON.object(try JSONObject())
        if let elicitation {
            var modes: [JSONMember] = []
            if elicitation.form { modes.append(JSONMember("form", value: empty)) }
            if elicitation.url { modes.append(JSONMember("url", value: empty)) }
            members.append(JSONMember("elicitation", value: .object(try JSONObject(members: modes))))
        }
        if sampling != nil { members.append(JSONMember("sampling", value: empty)) }
        if roots != nil { members.append(JSONMember("roots", value: empty)) }
        if !extensions.isEmpty {
            let declared = try extensions.sorted { $0.key < $1.key }.map { JSONMember($0.key, value: $0.value) }
            members.append(JSONMember("extensions", value: .object(try JSONObject(members: declared))))
        }
        return .object(try JSONObject(members: members))
    }
}
