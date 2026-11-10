// SPDX-License-Identifier: Apache-2.0
import JSON
import JSONSchema
import MCPProtocol

public enum HeaderDeclarationFailure: Error, Sendable, Equatable {
    case invalidLimit, invalidLocation, invalidName, invalidType, collision, traversalLimit
}
public enum HeaderDeclarations {
    /// Traverse declared schema positions, never resolve a reference/effective shape.
    /// Unknown metadata is preserved and not interpreted as a schema. All recognized
    /// non-properties locations are visited to reject misplaced annotations (D07).
    public static func scan(_ document: JSONSchemaDocument, maximumNodes: Int = 1024,
        maximumDepth: Int = 32, maximumHeaders: Int = 64,
        charge: @Sendable (UInt64) async throws -> Void,
        inspect: @Sendable ([String]) async throws -> JSONSchemaNodeView) async throws -> [HeaderDeclaration] {
        guard maximumNodes > 0, maximumDepth > 0, maximumDepth <= Int.max / 2,
              maximumHeaders > 0 else { throw HeaderDeclarationFailure.invalidLimit }
        struct Entry { let raw: JSON; let pointer: [String]; let path: [ScalarText]; let eligible: Bool }
        var stack = [Entry(raw: document.raw, pointer: [], path: [], eligible: true)]
        var visited = 0, pending = 1
        var result: [HeaderDeclaration] = [], names = Set<ScalarText>()
        // Maps and arrays contain child schemas; single keywords contain one.
        let maps = ["properties", "$defs", "definitions", "patternProperties", "dependentSchemas", "dependencies"]
        let arrays = ["allOf", "anyOf", "oneOf", "prefixItems"]
        let singles = ["items", "contains", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
                       "propertyNames", "not", "if", "then", "else", "contentSchema"]
        while let entry = stack.popLast() {
            pending -= 1; visited += 1
            guard visited <= maximumNodes, entry.pointer.count <= maximumDepth * 2 else { throw HeaderDeclarationFailure.traversalLimit }
            try Task.checkCancellation(); try await charge(1)
            guard let object = entry.raw.objectValue else { continue }
            // Charge all examined member key bytes before raw lookup/dispatch.
            for member in object {
                try await charge((UInt64(member.key.string.utf8.count) + 1) * UInt64(maps.count + arrays.count + singles.count + 4))
            }
            let view = try await inspect(entry.pointer)
            switch view.declaredAnnotations.presence(of: "x-mcp-header") {
            case .absent: break
            case .null: throw HeaderDeclarationFailure.invalidName
            case .value(let annotation):
                guard entry.eligible, !entry.path.isEmpty else { throw HeaderDeclarationFailure.invalidLocation }
                guard let name = annotation.stringValue, name.utf8.count <= 256, validToken(name) else { throw HeaderDeclarationFailure.invalidName }
                guard let type = object["type"]?.stringValue, let primitive = HeaderDeclaration.Primitive(rawValue: type) else { throw HeaderDeclarationFailure.invalidType }
                try await charge(UInt64(name.utf8.count) * 4 + UInt64(entry.path.count))
                let folded = ScalarText(String(decoding: name.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self))
                guard names.insert(folded).inserted else { throw HeaderDeclarationFailure.collision }
                guard result.count < maximumHeaders else { throw HeaderDeclarationFailure.traversalLimit }
                result.append(.init(path: entry.path, name: "Mcp-Param-" + name, primitive: primitive))
            }
            func push(_ raw: JSON, pointer: [String], path: [ScalarText], eligible: Bool) throws {
                guard pending < maximumNodes - visited, pointer.count <= maximumDepth * 2 else { throw HeaderDeclarationFailure.traversalLimit }
                stack.append(.init(raw: raw, pointer: pointer, path: path, eligible: eligible)); pending += 1
            }
            for key in maps {
                guard let children = object[key]?.objectValue else { continue }
                for member in children {
                    try await charge(UInt64(member.key.string.utf8.count) + UInt64(entry.pointer.reduce(0) { $0 + $1.utf8.count }) + 1)
                    try push(member.value, pointer: entry.pointer + [key, member.key.string],
                        path: key == "properties" ? entry.path + [ScalarText(member.key.string)] : [],
                        eligible: entry.eligible && key == "properties")
                }
            }
            for key in arrays {
                guard let children = object[key]?.arrayValue else { continue }
                for (index, child) in children.enumerated() {
                    try await charge(1); try push(child, pointer: entry.pointer + [key, String(index)], path: [], eligible: false)
                }
            }
            for key in singles {
                if let child = object[key] {
                    if let array = child.arrayValue { // Reject misplaced annotations even in legacy-shaped invalid schemas.
                        for (index, item) in array.enumerated() {
                            try await charge(1); try push(item, pointer: entry.pointer + [key, String(index)], path: [], eligible: false)
                        }
                    } else { try await charge(1); try push(child, pointer: entry.pointer + [key], path: [], eligible: false) }
                }
            }
        }
        return result
    }
    private static func validToken(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
            [33,35,36,37,38,39,42,43,45,46,94,95,96,124,126].contains(byte)
        }
    }
}
