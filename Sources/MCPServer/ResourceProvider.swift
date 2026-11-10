// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public struct ResourceProvider: Sendable {
    public let definition: JSON
    public let requiredScopes: Set<ScalarText>
    public let requiredFeatures: Set<ClientFeature>
    let continuation: MultiRoundProvider?
    let handler: ProviderHandler
    /// Typed complete resource output. The host supplies the explicit definition
    /// and a complete result shape; ordinary wire validation still applies.
    public static func typed<Output: Encodable & Sendable>(definition: JSON, requiredScopes: Set<ScalarText> = [],
        requiredFeatures: Set<ClientFeature> = [], handler: @escaping @Sendable (String, RequestContext) async throws -> Output) -> Self {
        .init(definition: definition, requiredScopes: requiredScopes, requiredFeatures: requiredFeatures) { input, context in
            guard case .value(let raw) = input, let uri = raw.stringValue else { throw CoreFailure.invalidInput }
            try context.checkCancellation()
            return try await TypedProviderAdapter.encode(handler(uri, context), context: context)
        }
    }
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [], rounds: MultiRoundProvider) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures
        self.continuation = rounds; self.handler = { _, _ in throw CoreFailure.invalidOutput }
    }
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [], handler: @escaping ProviderHandler) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures; self.handler = handler; self.continuation = nil
    }
}
public struct ResourceTemplateProvider: Sendable {
    public let definition: JSON
    public let requiredScopes: Set<ScalarText>
    public let requiredFeatures: Set<ClientFeature>
    /// URI matching is a host callback; RFC6570 expansion is a separate API.
    /// The callback must cooperate with RequestContext cancellation/budgets.
    let matches: @Sendable (String, RequestContext) async throws -> Bool
    let continuation: MultiRoundProvider?
    let handler: ProviderHandler
    /// Typed complete result for an explicitly matched template URI.
    public static func typed<Output: Encodable & Sendable>(definition: JSON, requiredScopes: Set<ScalarText> = [],
        requiredFeatures: Set<ClientFeature> = [], matches: @escaping @Sendable (String, RequestContext) async throws -> Bool,
        handler: @escaping @Sendable (String, RequestContext) async throws -> Output) -> Self {
        .init(definition: definition, requiredScopes: requiredScopes, requiredFeatures: requiredFeatures, matches: matches) { input, context in
            guard case .value(let raw) = input, let uri = raw.stringValue else { throw CoreFailure.invalidInput }
            try context.checkCancellation()
            return try await TypedProviderAdapter.encode(handler(uri, context), context: context)
        }
    }
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [],
        matches: @escaping @Sendable (String, RequestContext) async throws -> Bool, rounds: MultiRoundProvider) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures
        self.matches = matches; self.continuation = rounds; self.handler = { _, _ in throw CoreFailure.invalidOutput }
    }
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [],
        matches: @escaping @Sendable (String, RequestContext) async throws -> Bool, handler: @escaping ProviderHandler) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures
        self.matches = matches; self.handler = handler; self.continuation = nil
    }
}
