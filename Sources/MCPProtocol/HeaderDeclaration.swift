// SPDX-License-Identifier: Apache-2.0
/// Validated declaration paths use exact scalar keys. HTTP owns value mapping.
public struct HeaderDeclaration: Sendable {
    public enum Primitive: String, Sendable { case string, integer, boolean }
    public let path: [ScalarText]
    public let name: String
    public let primitive: Primitive
    public init(path: [ScalarText], name: String, primitive: Primitive) {
        self.path = path; self.name = name; self.primitive = primitive
    }
}
