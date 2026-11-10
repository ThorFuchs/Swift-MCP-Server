// SPDX-License-Identifier: Apache-2.0
/// Protocol text compared by Unicode scalar identity, without normalization.
/// This is a name/identity key, never a JSON value model.
public struct ScalarText: Sendable, Hashable, CustomStringConvertible {
    public let description: String
    public init(_ text: String) { description = text }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.description.utf8.elementsEqual(rhs.description.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(description.utf8.count)
        for byte in description.utf8 { hasher.combine(byte) }
    }
}
