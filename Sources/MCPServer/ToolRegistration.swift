// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public enum ClientFeature: String, Sendable, Hashable, CaseIterable {
    case sampling, samplingTools, samplingContext, roots, elicitationForm, elicitationURL
    var path: [String] {
        switch self {
        case .sampling: ["sampling"]
        case .samplingTools: ["sampling", "tools"]
        case .samplingContext: ["sampling", "context"]
        case .roots: ["roots"]
        case .elicitationForm: ["elicitation", "form"]
        case .elicitationURL: ["elicitation", "url"]
        }
    }
}
public typealias ProviderHandler = @Sendable (JSONPresence<JSON>, RequestContext) async throws -> JSON
public struct ToolRegistration: Sendable {
    public let definition: JSON
    public let requiredScopes: Set<ScalarText>
    public let requiredFeatures: Set<ClientFeature>
    let continuation: MultiRoundProvider?
    let handler: ProviderHandler
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [], rounds: MultiRoundProvider) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures
        self.continuation = rounds; self.handler = { _, _ in throw CoreFailure.invalidOutput }
    }
    public init(definition: JSON, requiredScopes: Set<ScalarText> = [], requiredFeatures: Set<ClientFeature> = [], handler: @escaping ProviderHandler) {
        self.definition = definition; self.requiredScopes = requiredScopes; self.requiredFeatures = requiredFeatures; self.handler = handler; self.continuation = nil
    }
    /// Typed arguments use the upstream bounded native coder after schema
    /// validation. Typed structured results are checked against outputSchema.
    public static func typed<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        definition: JSON, input: Input.Type, requiredScopes: Set<ScalarText> = [],
        requiredFeatures: Set<ClientFeature> = [],
        handler: @escaping @Sendable (Input, RequestContext) async throws -> Output) -> Self {
        .init(definition: definition, requiredScopes: requiredScopes, requiredFeatures: requiredFeatures) { presence, context in
            let raw: JSON
            switch presence {
            case .absent: raw = try await RuntimeJSON.object([], budget: context.budget)
            case .null: raw = .null
            case .value(let value): raw = value
            }
            let input = try await context.budget.performJSON { try JSONValueDecoder(options: .init(limits: $0)).decodeWithReport(Input.self, from: raw) }
            let output = try await handler(input, context)
            try context.checkCancellation()
            let structured = try await context.budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(output) }
            return try await RuntimeJSON.object([.init("resultType", value: .string("complete")),
                .init("content", value: .array([])), .init("structuredContent", value: structured)], budget: context.budget)
        }
    }
}
