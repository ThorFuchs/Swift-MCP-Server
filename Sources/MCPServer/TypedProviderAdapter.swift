// SPDX-License-Identifier: Apache-2.0
import JSON

// Shared bounded coder for typed resource/prompt conveniences. Schema and
// wire validation remain with the catalog and dispatcher, not this adapter.
enum TypedProviderAdapter {
    static func decode<Input: Decodable & Sendable>(_ type: Input.Type, presence: JSONPresence<JSON>, context: RequestContext) async throws -> Input {
        let raw: JSON
        switch presence {
        case .absent: raw = try await RuntimeJSON.object([], budget: context.budget)
        case .null: raw = .null
        case .value(let value): raw = value
        }
        return try await context.budget.performJSON {
            try JSONValueDecoder(options: .init(limits: $0)).decodeWithReport(Input.self, from: raw)
        }
    }
    static func encode<Output: Encodable & Sendable>(_ value: Output, context: RequestContext) async throws -> JSON {
        try context.checkCancellation()
        return try await context.budget.performJSON {
            try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(value)
        }
    }
}
