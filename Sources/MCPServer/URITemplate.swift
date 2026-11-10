// SPDX-License-Identifier: Apache-2.0
// Original RFC6570 level-4 boundary; no third-party expansion code is copied.
import Foundation
import MCPProtocol

public enum URIValue: Sendable {
    public struct Pair: Sendable {
        public let name: String
        public let value: String?
        public init(_ name: String, _ value: String?) { self.name = name; self.value = value }
    }
    case string(String), list([String?]), map([Pair])
}
public struct URITemplate: Sendable {
    private struct Variable: Sendable { let name: ScalarText; let explode: Bool; let prefix: Int? }
    private enum Part: Sendable { case literal(String), expression(UInt8, [Variable]) }
    private let parts: [Part]
    public static func prepare(_ source: String, budget: RequestBudget) async throws -> Self {
        do { return try await prepareChecked(source, budget: budget) }
        catch {
            if error as? CoreFailure == .limit || error is CancellationError { await budget.terminate() }
            throw error
        }
    }
    private static func prepareChecked(_ source: String, budget: RequestBudget) async throws -> Self {
        guard source.utf8.count <= 8192 else { throw CoreFailure.limit }
        try await budget.consume(UInt64(source.utf8.count) * 16 + 1)
        let bytes = Array(source.utf8)
        var parts: [Part] = [], offset = 0, start = 0, variableCount = 0
        func literal(_ slice: ArraySlice<UInt8>) throws -> String {
            let text = String(decoding: slice, as: UTF8.self)
            for scalar in text.unicodeScalars {
                let value = scalar.value
                let ascii = value >= 33 && value <= 126 && ![34,39,60,62,92,94,96,123,124,125].contains(value)
                let ucs = (0xA0...0xD7FF).contains(value) || (0xE000...0xFDCF).contains(value) || (0xFDF0...0xFFEF).contains(value)
                let plane = value >> 16, low = value & 0xFFFF
                let supplementary = ((1...13).contains(plane) || (plane == 14 && low >= 0x1000) || plane == 15 || plane == 16) && low <= 0xFFFD
                guard ascii || ucs || supplementary else { throw CoreFailure.invalidInput }
            }
            let raw = Array(slice); var index = 0
            while index < raw.count {
                if raw[index] == 37 { guard index + 2 < raw.count, hex(raw[index+1]), hex(raw[index+2]) else { throw CoreFailure.invalidInput }; index += 3 }
                else { index += 1 }
            }
            return text
        }
        while offset < bytes.count {
            try Task.checkCancellation()
            if bytes[offset] == 125 { throw CoreFailure.invalidInput }
            guard bytes[offset] == 123 else { offset += 1; continue }
            if start < offset { parts.append(.literal(try literal(bytes[start..<offset]))) }
            guard let end = bytes[(offset+1)...].firstIndex(of: 125), end > offset + 1 else { throw CoreFailure.invalidInput }
            var expression = Array(bytes[(offset+1)..<end]), op: UInt8 = 0
            if [43,35,46,47,59,63,38].contains(expression[0]) { op = expression.removeFirst() }
            guard !expression.isEmpty else { throw CoreFailure.invalidInput }
            let specs = expression.split(separator: 44, omittingEmptySubsequences: false)
            guard specs.count <= 32 else { throw CoreFailure.limit }
            var variables: [Variable] = []
            for spec in specs {
                variableCount += 1; guard variableCount <= 256 else { throw CoreFailure.limit }
                var raw = Array(spec), explode = false, prefix: Int?
                if raw.last == 42 { explode = true; raw.removeLast() }
                if let colon = raw.firstIndex(of: 58) {
                    let number = raw[(colon+1)...]
                    guard !explode, (1...4).contains(number.count), number.first! >= 49, number.first! <= 57,
                          number.allSatisfy({ (48...57).contains($0) }) else { throw CoreFailure.invalidInput }
                    prefix = number.reduce(0) { $0 * 10 + Int($1 - 48) }; raw = Array(raw[..<colon])
                }
                guard !raw.isEmpty, raw.count <= 1024, raw.first != 46, raw.last != 46 else { throw CoreFailure.invalidInput }
                var index = 0, dot = false
                while index < raw.count {
                    let byte = raw[index]
                    if byte == 37 {
                        guard index + 2 < raw.count, hex(raw[index+1]), hex(raw[index+2]) else { throw CoreFailure.invalidInput }
                        index += 3; dot = false
                    } else if byte == 46 {
                        guard !dot else { throw CoreFailure.invalidInput }; dot = true; index += 1
                    } else {
                        guard alpha(byte) || (48...57).contains(byte) || byte == 95 else { throw CoreFailure.invalidInput }
                        dot = false; index += 1
                    }
                }
                variables.append(.init(name: ScalarText(String(decoding: raw, as: UTF8.self)), explode: explode, prefix: prefix))
            }
            parts.append(.expression(op, variables)); offset = end + 1; start = offset
        }
        if start < bytes.count { parts.append(.literal(try literal(bytes[start...]))) }
        return .init(parts: parts)
    }

    public func expand(_ values: [ScalarText: URIValue], maximumBytes: Int = 65_536, budget: RequestBudget) async throws -> String {
        do { return try await expandChecked(values, maximumBytes: maximumBytes, budget: budget) }
        catch {
            if error as? CoreFailure == .limit || error is CancellationError { await budget.terminate() }
            throw error
        }
    }
    private func expandChecked(_ values: [ScalarText: URIValue], maximumBytes: Int, budget: RequestBudget) async throws -> String {
        guard maximumBytes > 0, maximumBytes <= 1_048_576, values.count <= 256 else { throw CoreFailure.limit }
        var weight = 0
        func weigh(_ text: String) throws {
            guard text.utf8.count <= 4096, text.utf8.count + 1 <= 1_048_576 - weight else { throw CoreFailure.limit }
            weight += text.utf8.count + 1
        }
        for (name, value) in values {
            try weigh(name.description)
            switch value {
            case .string(let text): try weigh(text)
            case .list(let items):
                guard items.count <= 256 else { throw CoreFailure.limit }
                for item in items { if let item { try weigh(item) } }
            case .map(let items):
                guard items.count <= 256 else { throw CoreFailure.limit }
                var names = Set<ScalarText>()
                for item in items {
                    guard names.insert(ScalarText(item.name)).inserted else { throw CoreFailure.duplicate }
                    try weigh(item.name); if let value = item.value { try weigh(value) }
                }
            }
        }
        try await budget.consume(UInt64(weight) * 16 + 1)
        var output = "", outputBytes = 0
        func append(_ text: String) async throws {
            try Task.checkCancellation()
            guard text.utf8.count <= maximumBytes - outputBytes else { throw CoreFailure.limit }
            try await budget.consume(UInt64(text.utf8.count) + 1)
            output += text; outputBytes += text.utf8.count
        }
        func encode(_ text: String, reserved: Bool) throws -> String {
            let input = Array(text.utf8), digits = Array("0123456789ABCDEF".utf8)
            var result: [UInt8] = [], index = 0
            while index < input.count {
                try Task.checkCancellation()
                let byte = input[index]
                if reserved && byte == 37 && index + 2 < input.count && Self.hex(input[index+1]) && Self.hex(input[index+2]) {
                    guard result.count <= maximumBytes - 3 else { throw CoreFailure.limit }
                    result.append(contentsOf: input[index...index+2]); index += 3
                } else if Self.alpha(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte) || (reserved && Array(":/?#[]@!$&'()*+,;=".utf8).contains(byte)) {
                    guard result.count < maximumBytes else { throw CoreFailure.limit }; result.append(byte); index += 1
                } else {
                    guard result.count <= maximumBytes - 3 else { throw CoreFailure.limit }
                    result.append(contentsOf: [37, digits[Int(byte >> 4)], digits[Int(byte & 15)]]); index += 1
                }
            }
            return String(decoding: result, as: UTF8.self)
        }
        for part in parts {
            switch part {
            case .literal(let text): try await append(encode(text, reserved: true))
            case .expression(let op, let variables):
                let reserved = op == 43 || op == 35
                let named = [59,63,38].contains(op)
                let separator = [46,47,59].contains(op) ? String(UnicodeScalar(op)) : (op == 63 || op == 38 ? "&" : ",")
                let first = op == 0 || op == 43 ? "" : String(UnicodeScalar(op))
                var segments: [String] = [], segmentBytes = 0
                func segment(_ value: String) throws {
                    guard value.utf8.count <= maximumBytes - segmentBytes else { throw CoreFailure.limit }
                    segmentBytes += value.utf8.count; segments.append(value)
                }
                func pair(_ name: String, _ value: String) -> String { value.isEmpty && op == 59 ? name : name + "=" + value }
                for variable in variables {
                    guard let value = values[variable.name] else { continue }
                    switch value {
                    case .string(let string):
                        let text = try encode(Self.prefix(string, length: variable.prefix), reserved: reserved)
                        try segment(named ? pair(variable.name.description, text) : text)
                    case .list(let list):
                        guard variable.prefix == nil else { throw CoreFailure.invalidInput }
                        var items: [String] = [], bytes = 0
                        for item in list.compactMap({ $0 }) {
                            let text = try encode(item, reserved: reserved)
                            guard text.utf8.count <= maximumBytes - bytes else { throw CoreFailure.limit }
                            bytes += text.utf8.count; items.append(text)
                        }
                        guard !items.isEmpty else { continue }
                        if variable.explode { for item in items { try segment(named ? pair(variable.name.description, item) : item) } }
                        else { let text = items.joined(separator: ","); try segment(named ? pair(variable.name.description, text) : text) }
                    case .map(let map):
                        guard variable.prefix == nil else { throw CoreFailure.invalidInput }
                        var items: [String] = [], bytes = 0
                        for item in map {
                            guard let value = item.value else { continue }
                            let key = try encode(item.name, reserved: reserved), text = try encode(value, reserved: reserved)
                            guard key.utf8.count + text.utf8.count + 2 <= maximumBytes - bytes else { throw CoreFailure.limit }
                            bytes += key.utf8.count + text.utf8.count + 2
                            if variable.explode { try segment(text.isEmpty && op != 63 && op != 38 ? key : key + "=" + text) }
                            else { items.append(key); items.append(text) }
                        }
                        if !variable.explode, !items.isEmpty { let text = items.joined(separator: ","); try segment(named ? pair(variable.name.description, text) : text) }
                    }
                }
                if !segments.isEmpty { try await append(first); for (index, segment) in segments.enumerated() { if index > 0 { try await append(separator) }; try await append(segment) } }
            }
        }
        return output
    }
    private static func alpha(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    private static func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
    private static func prefix(_ text: String, length: Int?) -> String {
        guard let length else { return text }
        let bytes = Array(text.utf8); var index = 0, count = 0
        func octet(_ at: Int) -> UInt8? {
            guard at + 2 < bytes.count, bytes[at] == 37, hex(bytes[at+1]), hex(bytes[at+2]) else { return nil }
            func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : (b & 0xDF) - 55 }
            return nibble(bytes[at+1]) * 16 + nibble(bytes[at+2])
        }
        while index < bytes.count && count < length {
            let byte = bytes[index]
            if let value = octet(index) {
                let width = value < 128 ? 1 : ((0xC2...0xDF).contains(value) ? 2 : ((0xE0...0xEF).contains(value) ? 3 : ((0xF0...0xF4).contains(value) ? 4 : 1)))
                var encoded: [UInt8] = []
                for offset in 0..<width { if let next = octet(index + offset * 3) { encoded.append(next) } }
                index += encoded.count == width && String(bytes: encoded, encoding: .utf8) != nil ? width * 3 : 3
            } else { index += byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4)) }
            count += 1
        }
        return String(decoding: bytes.prefix(index), as: UTF8.self)
    }
}
