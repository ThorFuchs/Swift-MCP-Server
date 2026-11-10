// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public struct PromptProvider: Sendable {
    public let definition: JSON
    public let requiredScopes: Set<ScalarText>
    public let requiredFeatures: Set<ClientFeature>
    let continuation: MultiRoundProvider?
    let handler: ProviderHandler
    /// Decode prompt arguments with the existing bounded coder and encode the
    /// complete result supplied by the host. Omitted arguments decode from an
    /// empty object; an explicit null remains null and is never substituted.
    public static func typed<Input: Decodable & Sendable, Output: Encodable & Sendable>(definition: JSON,
        input: Input.Type, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [],
        handler: @escaping @Sendable (Input, RequestContext) async throws -> Output) -> Self {
        .init(definition: definition, requiredScopes: requiredScopes, requiredFeatures: requiredFeatures) { presence, context in
            let decoded = try await TypedProviderAdapter.decode(Input.self, presence: presence, context: context)
            try context.checkCancellation()
            return try await TypedProviderAdapter.encode(handler(decoded, context), context: context)
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
