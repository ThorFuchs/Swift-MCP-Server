// SPDX-License-Identifier: Apache-2.0
import JSON

package enum RuntimeJSON {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    struct Object: Encodable, Sendable {
        let members: [JSONMember]
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for member in members { try container.encode(member.value, forKey: Key(member.key.string)) }
        }
    }
    package static func object(_ members: [JSONMember], budget: RequestBudget) async throws -> JSON {
        try await budget.consume(UInt64(members.reduce(0) { $0 + $1.key.string.utf8.count + 1 }))
        return try await budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(Object(members: members)) }
    }
    package static func overlay(_ value: JSON, members: [JSONMember], budget: RequestBudget) async throws -> JSON {
        guard let object = value.objectValue else { throw CoreFailure.invalidOutput }
        let replacing = Set(members.map { $0.key })
        try await budget.consume(UInt64(object.reduce(0) { $0 + $1.key.string.utf8.count + 1 }))
        return try await self.object(object.filter { !replacing.contains($0.key) } + members, budget: budget)
    }
}
