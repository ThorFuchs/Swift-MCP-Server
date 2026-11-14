// SPDX-License-Identifier: Apache-2.0

/// Why a `SKILL.md` could not be served. Thrown when a catalog is built, never at request time.
public struct SkillDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let skill: String
    public let reason: String
    public var description: String { "\(skill): \(reason)" }
}
