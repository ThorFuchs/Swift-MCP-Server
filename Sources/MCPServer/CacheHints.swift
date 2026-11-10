// SPDX-License-Identifier: Apache-2.0
import JSON

public struct CacheHints: Sendable {
    public enum Scope: String, Sendable { case `private`, `public` }
    public let ttlMilliseconds: Int64
    public let scope: Scope
    public init(ttlMilliseconds: Int64 = 0, scope: Scope = .private) throws {
        guard ttlMilliseconds >= 0, ttlMilliseconds <= 3_600_000 else { throw CoreFailure.invalidPolicy }
        self.ttlMilliseconds = ttlMilliseconds; self.scope = scope
    }
    func apply(to result: JSON, budget: RequestBudget) async throws -> JSON {
        struct Hints: Encodable { let ttlMs: Int64; let cacheScope: String }
        let values = try await budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(Hints(ttlMs: ttlMilliseconds, cacheScope: scope.rawValue)) }
        return try await RuntimeJSON.overlay(result, members: values.objectValue!.members, budget: budget)
    }
}
