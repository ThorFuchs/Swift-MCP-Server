// SPDX-License-Identifier: Apache-2.0
// Strict parser for the YAML subset used by Agent Skills `SKILL.md` frontmatter.
import Foundation

/// A frontmatter value in author order. Encodes as the equivalent JSON value.
package indirect enum FrontmatterValue: Sendable, Equatable, Encodable {
    case string(String), integer(Int64), double(Double), boolean(Bool), null
    case sequence([FrontmatterValue])
    case mapping([(key: String, value: FrontmatterValue)])

    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.boolean(let a), .boolean(let b)): a == b
        case (.null, .null): true
        case (.sequence(let a), .sequence(let b)): a == b
        case (.mapping(let a), .mapping(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .integer(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .double(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .boolean(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .sequence(let items):
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        case .mapping(let members):
            var c = encoder.container(keyedBy: Key.self)
            for member in members { try c.encode(member.value, forKey: Key(member.key)) }
        }
    }
    package subscript(key: String) -> FrontmatterValue? {
        guard case .mapping(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
    package var string: String? { if case .string(let value) = self { value } else { nil } }
}

/// Splits `SKILL.md` into its frontmatter mapping. Supported YAML: block mappings and
/// sequences, plain, single- and double-quoted scalars, `|`/`>` block scalars, flow
/// sequences of scalars and comments. Anchors, aliases, tags, flow mappings, tabs and
/// duplicate keys are rejected rather than guessed, so the served `frontmatter` is
/// always the value a YAML 1.2 core-schema parser reads from the same bytes.
package enum Frontmatter {
    package struct Failure: Error { package let line: Int, reason: String }

    package static func parse(_ markdown: String) throws(Failure) -> FrontmatterValue {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        guard lines.first == "---" else { throw Failure(line: 1, reason: "SKILL.md must begin with a '---' frontmatter line") }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0 == "---" || $0 == "..." }) else { throw Failure(line: 1, reason: "frontmatter is not closed by '---'") }
        var parser = Parser(lines: Array(lines[..<end]).map(String.init))
        let value = try parser.document()
        guard case .mapping = value else { throw Failure(line: 2, reason: "frontmatter must be a mapping") }
        return value
    }

    private struct Parser {
        let lines: [String]
        var index = 0
        init(lines: [String]) { self.lines = lines }

        var lineNumber: Int { index + 2 }
        func fail(_ reason: String) -> Failure { Failure(line: lineNumber, reason: reason) }

        static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        static func isBlank(_ line: String) -> Bool {
            let trimmed = line.drop { $0 == " " }
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
        mutating func skipBlank() { while index < lines.count, Self.isBlank(lines[index]) { index += 1 } }

        mutating func document() throws(Failure) -> FrontmatterValue {
            for (offset, line) in lines.enumerated() where line.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw Failure(line: offset + 2, reason: "tabs are not allowed in indentation")
            }
            skipBlank()
            guard index < lines.count else { return .mapping([]) }
            let value = try block(indent: Self.indentation(lines[index]))
            skipBlank()
            guard index == lines.count else { throw fail("unexpected content") }
            return value
        }

        mutating func block(indent: Int) throws(Failure) -> FrontmatterValue {
            let content = lines[index].dropFirst(indent)
            return content.hasPrefix("- ") || content == "-" ? try sequence(indent: indent) : try mapping(indent: indent)
        }

        mutating func mapping(indent: Int) throws(Failure) -> FrontmatterValue {
            var members: [(key: String, value: FrontmatterValue)] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index], level = Self.indentation(line)
                if level < indent { break }
                guard level == indent else { throw fail("unexpected indentation") }
                let (key, rest) = try splitKey(String(line.dropFirst(indent)))
                guard !members.contains(where: { $0.key == key }) else { throw fail("duplicate key '\(key)'") }
                index += 1
                members.append((key, try value(after: rest, indent: indent, allowSequenceAtSameIndent: true)))
            }
            return .mapping(members)
        }

        mutating func sequence(indent: Int) throws(Failure) -> FrontmatterValue {
            var items: [FrontmatterValue] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index], level = Self.indentation(line)
                if level < indent { break }
                guard level == indent else { throw fail("unexpected indentation") }
                let content = line.dropFirst(indent)
                guard content.hasPrefix("- ") || content == "-" else { break }
                let rest = String(content.dropFirst(1)).trimmingLeadingSpaces
                if rest.contains(": ") || rest.hasSuffix(":") { throw fail("mappings inside sequences are not supported") }
                index += 1
                items.append(try value(after: rest, indent: indent, allowSequenceAtSameIndent: false))
            }
            return .sequence(items)
        }

        /// The value following `key:` (or `-`). Empty means a nested block or null.
        mutating func value(after raw: String, indent: Int, allowSequenceAtSameIndent: Bool) throws(Failure) -> FrontmatterValue {
            let rest = Self.stripComment(raw.trimmingLeadingSpaces).trimmingTrailingSpaces
            if rest.isEmpty {
                skipBlank()
                guard index < lines.count else { return .null }
                let level = Self.indentation(lines[index])
                let content = lines[index].dropFirst(level)
                if level > indent { return try block(indent: level) }
                if allowSequenceAtSameIndent, level == indent, content.hasPrefix("- ") || content == "-" { return try sequence(indent: level) }
                return .null
            }
            if let header = rest.first, header == "|" || header == ">" { return try blockScalar(header: rest, indent: indent) }
            if rest.hasPrefix("[") { return try flowSequence(rest) }
            if let first = rest.first, "{&*!%@`".contains(first) { throw fail("unsupported YAML construct '\(first)'") }
            if rest.hasPrefix("\"") { return .string(try doubleQuoted(rest)) }
            if rest.hasPrefix("'") { return .string(try singleQuoted(rest)) }
            // Plain scalars may continue on more-indented lines; they fold with single spaces.
            var text = rest
            while index < lines.count, !Self.isBlank(lines[index]), Self.indentation(lines[index]) > indent {
                let continuation = lines[index].trimmingLeadingSpaces
                if continuation.hasPrefix("- ") || continuation.contains(": ") { break }
                text += " " + Self.stripComment(continuation).trimmingTrailingSpaces
                index += 1
            }
            return try Self.plain(text, at: lineNumber)
        }

        func splitKey(_ content: String) throws(Failure) -> (String, String) {
            var key: String, rest: Substring
            if content.hasPrefix("\"") || content.hasPrefix("'") {
                let quote = content.first!
                guard let close = content.dropFirst().firstIndex(of: quote) else { throw fail("unterminated quoted key") }
                key = String(content[content.index(after: content.startIndex)..<close])
                rest = content[content.index(after: close)...]
                guard rest.hasPrefix(":") else { throw fail("expected ':' after key") }
                rest = rest.dropFirst()
            } else {
                guard let colon = content.range(of: ": ")?.lowerBound ?? (content.hasSuffix(":") ? content.index(before: content.endIndex) : nil)
                else { throw fail("expected 'key: value'") }
                key = String(content[..<colon]).trimmingTrailingSpaces
                rest = content[content.index(after: colon)...]
                if let first = key.first, "{[&*!%@`#|>-\"'".contains(first) { throw fail("unsupported key '\(key)'") }
            }
            guard !key.isEmpty else { throw fail("empty key") }
            guard rest.isEmpty || rest.hasPrefix(" ") else { throw fail("expected a space after ':'") }
            return (key, String(rest))
        }

        mutating func blockScalar(header: String, indent: Int) throws(Failure) -> FrontmatterValue {
            let folded = header.first == ">"
            let chomp = header.dropFirst()
            guard ["", "-", "+"].contains(chomp) else { throw fail("unsupported block scalar header '\(header)'") }
            var body: [String] = [], level: Int?
            while index < lines.count {
                let line = lines[index]
                if line.allSatisfy({ $0 == " " }) { body.append(""); index += 1; continue }
                let current = Self.indentation(line)
                if level == nil { guard current > indent else { break }; level = current }
                guard current >= level! else { break }
                body.append(String(line.dropFirst(level!))); index += 1
            }
            var trailing = 0
            while body.last == "" { body.removeLast(); trailing += 1 }
            var text: String
            if folded {
                text = ""
                for (offset, line) in body.enumerated() {
                    if offset == 0 { text = line; continue }
                    let previous = body[offset - 1]
                    if line.isEmpty { text += "\n" }
                    else if previous.isEmpty || line.hasPrefix(" ") || previous.hasPrefix(" ") { text += (previous.isEmpty ? "" : "\n") + line }
                    else { text += " " + line }
                }
            } else { text = body.joined(separator: "\n") }
            switch chomp {
            case "-": break
            case "+": text += String(repeating: "\n", count: body.isEmpty ? trailing : trailing + 1)
            default: if !body.isEmpty { text += "\n" }
            }
            return .string(text)
        }

        func flowSequence(_ text: String) throws(Failure) -> FrontmatterValue {
            guard text.hasSuffix("]") else { throw fail("flow sequences must be on one line") }
            let inner = text.dropFirst().dropLast().trimmingLeadingSpaces.trimmingTrailingSpaces
            if inner.isEmpty { return .sequence([]) }
            var items: [FrontmatterValue] = [], current = "", quote: Character?
            for character in inner {
                if let open = quote { current.append(character); if character == open { quote = nil }; continue }
                if character == "\"" || character == "'" { quote = character; current.append(character); continue }
                if "[]{}".contains(character) { throw fail("nested flow collections are not supported") }
                if character == "," { items.append(try flowItem(current)); current = ""; continue }
                current.append(character)
            }
            guard quote == nil else { throw fail("unterminated quoted scalar") }
            items.append(try flowItem(current))
            return .sequence(items)
        }
        func flowItem(_ raw: String) throws(Failure) -> FrontmatterValue {
            let item = raw.trimmingLeadingSpaces.trimmingTrailingSpaces
            guard !item.isEmpty else { throw fail("empty flow sequence item") }
            if item.hasPrefix("\"") { return .string(try doubleQuoted(item)) }
            if item.hasPrefix("'") { return .string(try singleQuoted(item)) }
            if let first = item.first, "&*!%@`".contains(first) || item.contains(": ") { throw fail("unsupported flow item '\(item)'") }
            return try Self.plain(item, at: lineNumber)
        }

        func doubleQuoted(_ text: String) throws(Failure) -> String {
            var result = "", iterator = text.dropFirst().makeIterator(), closed = false
            while let character = iterator.next() {
                if character == "\"" { closed = true; break }
                guard character == "\\" else { result.append(character); continue }
                guard let escape = iterator.next() else { break }
                switch escape {
                case "\"": result.append("\""); case "\\": result.append("\\"); case "/": result.append("/")
                case "n": result.append("\n"); case "t": result.append("\t"); case "r": result.append("\r")
                case "0": result.append("\0"); case " ": result.append(" ")
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let digit = iterator.next() { hex.append(digit) } }
                    guard hex.count == 4, let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) else { throw fail("invalid \\u escape") }
                    result.unicodeScalars.append(scalar)
                default: throw fail("unsupported escape '\\\(escape)'")
                }
            }
            guard closed else { throw fail("unterminated double-quoted scalar (multi-line quoted scalars are not supported)") }
            let remainder = String(iterator).trimmingLeadingSpaces
            guard remainder.isEmpty || remainder.hasPrefix("#") else { throw fail("unexpected text after quoted scalar") }
            return result
        }
        func singleQuoted(_ text: String) throws(Failure) -> String {
            var result = "", characters = Array(text.dropFirst()), position = 0, closed = false
            while position < characters.count {
                let character = characters[position]
                if character == "'" {
                    if position + 1 < characters.count, characters[position + 1] == "'" { result.append("'"); position += 2; continue }
                    closed = true; position += 1; break
                }
                result.append(character); position += 1
            }
            guard closed else { throw fail("unterminated single-quoted scalar (multi-line quoted scalars are not supported)") }
            let remainder = String(characters[position...]).trimmingLeadingSpaces
            guard remainder.isEmpty || remainder.hasPrefix("#") else { throw fail("unexpected text after quoted scalar") }
            return result
        }

        static func stripComment(_ text: String) -> String {
            guard !text.hasPrefix("\""), !text.hasPrefix("'") else { return text }
            if text.hasPrefix("#") { return "" }
            guard let range = text.range(of: " #") else { return text }
            return String(text[..<range.lowerBound])
        }

        /// YAML 1.2 core schema resolution for plain scalars.
        static func plain(_ text: String, at line: Int) throws(Failure) -> FrontmatterValue {
            switch text {
            case "", "~", "null", "Null", "NULL": return .null
            case "true", "True", "TRUE": return .boolean(true)
            case "false", "False", "FALSE": return .boolean(false)
            default: break
            }
            let lowered = text.lowercased()
            if lowered.hasPrefix("0x") || lowered.hasPrefix("0o") || lowered.hasSuffix(".inf") || lowered == ".nan" {
                throw Failure(line: line, reason: "quote '\(text)': non-decimal and special numbers are not supported")
            }
            if text.wholeMatch(of: /[-+]?[0-9]+/) != nil {
                guard let value = Int64(text.hasPrefix("+") ? String(text.dropFirst()) : text) else { throw Failure(line: line, reason: "integer '\(text)' is out of range; quote it") }
                return .integer(value)
            }
            if text.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?/) != nil, let value = Double(text) {
                return .double(value)
            }
            if text.contains(": ") || text.hasSuffix(":") { throw Failure(line: line, reason: "plain scalar contains ': '; quote it") }
            return .string(text)
        }
    }
}

extension StringProtocol {
    package var trimmingLeadingSpaces: String { String(drop { $0 == " " }) }
    package var trimmingTrailingSpaces: String {
        var text = String(self)
        while text.last == " " { text.removeLast() }
        return text
    }
}
