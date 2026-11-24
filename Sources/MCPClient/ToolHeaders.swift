// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON

/// `x-mcp-header` declarations of one tool (Streamable HTTP, *Custom Headers from Tool
/// Parameters*): which argument, at which `properties` path, is mirrored into which
/// `Mcp-Param-{name}` header.
public struct ToolHeaders: Sendable {
    /// Supported scalar types for parameter-to-header mirroring.
    public enum Primitive: String, Sendable { case string, integer, boolean }
    /// A statically reachable argument path, header name and scalar type.
    public struct Declaration: Sendable {
        public let path: [String]
        public let name: String
        public let primitive: Primitive
    }
    /// Validated parameter-header declarations extracted from the input schema.
    public let declarations: [Declaration]

    /// An invalid annotation prevents the tool from being mirrored safely.
    public struct Invalid: Error, Sendable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    /// Reads every `x-mcp-header` in `inputSchema`. A declaration that is not statically
    /// reachable through `properties` only, has an invalid or duplicate name, or annotates a
    /// non-primitive (or `number`) property makes the whole tool invalid.
    public init(inputSchema: JSON) throws {
        var found: [Declaration] = []
        try Self.walk(inputSchema, path: [], reachable: true, into: &found)
        var seen = Set<String>()
        for declaration in found {
            guard seen.insert(declaration.name.lowercased()).inserted else { throw Invalid(reason: "duplicate x-mcp-header '\(declaration.name)'") }
        }
        declarations = found
    }

    private static func walk(_ schema: JSON, path: [String], reachable: Bool, into found: inout [Declaration]) throws {
        if let array = schema.arrayValue {
            for item in array { try walk(item, path: path, reachable: false, into: &found) }
            return
        }
        guard let object = schema.objectValue else { return }
        if let annotation = object["x-mcp-header"] {
            guard reachable, !path.isEmpty else { throw Invalid(reason: "x-mcp-header outside a properties chain") }
            guard let name = annotation.stringValue, !name.isEmpty, name.utf8.allSatisfy(isTokenCharacter) else {
                throw Invalid(reason: "x-mcp-header is not an HTTP token")
            }
            guard let type = object["type"]?.stringValue, let primitive = Primitive(rawValue: type) else {
                throw Invalid(reason: "x-mcp-header on a non-primitive property")
            }
            found.append(Declaration(path: path, name: name, primitive: primitive))
        }
        for member in object {
            let key = member.key.string
            if key == "properties", let properties = member.value.objectValue {
                for property in properties {
                    try walk(property.value, path: path + [property.key.string], reachable: reachable, into: &found)
                }
            } else if key != "x-mcp-header" {
                // Every other keyword (items, anyOf, $defs, $ref targets, …) breaks static reachability.
                try walk(member.value, path: path, reachable: false, into: &found)
            }
        }
    }

    /// RFC 9110 `tchar`.
    static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): true
        default: "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    /// `Mcp-Param-*` headers for these arguments. Absent and `null` values have no header;
    /// a value of the wrong type or an integer outside ±(2^53−1) is not mirrored.
    public func headers(for arguments: JSON?) -> [(name: String, value: String)] {
        declarations.compactMap { declaration in
            var value = arguments
            for key in declaration.path { value = value?.objectValue?[key] }
            guard let value, !value.isNull else { return nil }
            let text: String
            switch declaration.primitive {
            case .string:
                guard let string = value.stringValue else { return nil }
                text = string
            case .boolean:
                guard let flag = value.booleanValue else { return nil }
                text = flag ? "true" : "false"
            case .integer:
                guard let number = value.numberValue, number.isInteger, let integer = try? number.integer(as: Int64.self),
                      abs(integer) <= 9_007_199_254_740_991 else { return nil }
                text = String(integer)
            }
            return ("Mcp-Param-" + declaration.name, HeaderValue.encode(text))
        }
    }
}

/// Header value encoding shared by `Mcp-Name` and `Mcp-Param-*`.
public enum HeaderValue {
    /// Plain when every byte is visible ASCII or space, without leading or trailing
    /// whitespace and not looking like the sentinel; otherwise `=?base64?…?=`.
    public static func encode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let plain = bytes.allSatisfy { (0x20...0x7E).contains($0) } && bytes.first != 0x20 && bytes.last != 0x20
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        return plain ? value : "=?base64?" + Data(bytes).base64EncodedString() + "?="
    }
}
