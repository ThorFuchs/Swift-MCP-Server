// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

/// Answers an input request (MRTR) of a method without a typed handler, for example one an
/// extension defines. Receives the request's `params` and returns its result object.
public typealias InputHandler = @Sendable (JSON) async throws -> JSON

public struct ClientConfiguration: Sendable {
    public struct Elicitation: Sendable {
        /// The modes declared in the `elicitation` capability.
        public var form: Bool, url: Bool
        public let handler: @Sendable (ElicitationRequest) async throws -> ElicitationResponse
        public init(form: Bool = true, url: Bool = false, handler: @escaping @Sendable (ElicitationRequest) async throws -> ElicitationResponse) {
            self.form = form; self.url = url; self.handler = handler
        }
    }
    /// Sent as `io.modelcontextprotocol/clientInfo` (name and version required).
    public var info: JSON?
    /// Answers `elicitation/create`; declares the `elicitation` capability with its modes.
    /// Accepted form content is checked against `requestedSchema` before it is sent.
    public var elicitation: Elicitation?
    /// Answers `sampling/createMessage`; declares `sampling`.
    public var sampling: (@Sendable (SamplingRequest) async throws -> SamplingResponse)?
    /// Answers `roots/list`; declares `roots`.
    public var roots: (@Sendable () async throws -> [Root])?
    /// Handlers for other input request methods, by method. Their results are checked only
    /// as JSON-RPC result objects.
    public var additionalInputHandlers: [String: InputHandler]
    /// Extension declarations sent in `clientCapabilities.extensions`, by identifier.
    public var extensions: [String: JSON]
    /// `io.modelcontextprotocol/logLevel` for requests with a log handler.
    public var logLevel: LoggingLevel?
    /// Input rounds per request before `ClientError.tooManyInputRounds`.
    public var maximumInputRounds: Int
    /// Bounds for parsing every message received.
    public var limits: JSONLimits
    /// Checks `structuredContent` of successful tool results against the tool's
    /// `outputSchema` from `tools/list` (default `true`). Elicitation content is always
    /// checked against `requestedSchema`.
    public var validatesStructuredContent: Bool = true
    public init(info: JSON? = nil, elicitation: Elicitation? = nil,
                sampling: (@Sendable (SamplingRequest) async throws -> SamplingResponse)? = nil,
                roots: (@Sendable () async throws -> [Root])? = nil, additionalInputHandlers: [String: InputHandler] = [:],
                extensions: [String: JSON] = [:], logLevel: LoggingLevel? = nil, maximumInputRounds: Int = 8, limits: JSONLimits = .balanced) {
        self.info = info; self.elicitation = elicitation; self.sampling = sampling; self.roots = roots
        self.additionalInputHandlers = additionalInputHandlers
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
            let declared = extensions.sorted { $0.key < $1.key }.map { JSONMember($0.key, value: $0.value) }
            members.append(JSONMember("extensions", value: .object(try JSONObject(members: declared))))
        }
        return .object(try JSONObject(members: members))
    }
}
