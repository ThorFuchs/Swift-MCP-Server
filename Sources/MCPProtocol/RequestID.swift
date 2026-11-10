// SPDX-License-Identifier: Apache-2.0
import JSON

/// Exact mathematical integer or scalar string. No machine integer/Double bridge.
public enum RequestID: Sendable {
    case string(ScalarText), integer(JSONNumber)
    public init(_ value: JSON, maximumUTF8Bytes: Int = 4096) throws {
        guard maximumUTF8Bytes > 0 else { throw WireFailure.invalidLimit }
        switch value {
        case .string(let text):
            guard text.utf8.count <= maximumUTF8Bytes else { throw WireFailure.limit }
            self = .string(ScalarText(text))
        case .number(let number) where number.isInteger: self = .integer(number)
        default: throw WireFailure.invalidRequest
        }
    }
    public var value: JSON {
        switch self { case .string(let text): .string(text.description); case .integer(let number): .number(number) }
    }
}
