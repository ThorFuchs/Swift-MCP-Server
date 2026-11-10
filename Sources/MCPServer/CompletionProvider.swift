// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol

public struct CompletionPage: Sendable {
    public let values: [String]
    public let total: Int?
    public let hasMore: Bool
    public init(values: [String], total: Int? = nil, hasMore: Bool = false) throws {
        guard values.count <= 1000, values.allSatisfy({ $0.utf8.count <= 4096 }),
              total.map({ $0 >= values.count && $0 <= 1_000_000_000 }) ?? true,
              !(hasMore && total == values.count) else { throw CoreFailure.invalidOutput }
        self.values = values; self.total = total; self.hasMore = hasMore
    }
}
public struct CompletionProvider: Sendable {
    public let requiredScopes: Set<ScalarText>
    let handler: @Sendable (JSON, RequestContext) async throws -> CompletionPage
    public init(requiredScopes: Set<ScalarText> = [], handler: @escaping @Sendable (JSON, RequestContext) async throws -> CompletionPage) {
        self.requiredScopes = requiredScopes; self.handler = handler
    }
}
