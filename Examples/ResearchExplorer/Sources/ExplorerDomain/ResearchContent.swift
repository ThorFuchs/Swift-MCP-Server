// SPDX-License-Identifier: Apache-2.0
import Foundation

extension Snapshot {
    /// Equality of bounded retained research content. Only retrieval time and
    /// its derived accounting/expiry/LRU metadata may refresh. Not a hash/JCS.
    public func hasSameResearchContent(as other: Snapshot) throws -> Bool {
        try Task.checkCancellation()
        let a = provenance, b = other.provenance
        guard a.identity == b.identity, a.title == b.title, a.sourceURL == b.sourceURL,
              a.modifiedAt == b.modifiedAt, a.language == b.language, a.license == b.license,
              a.synthetic == b.synthetic, parts.count == other.parts.count,
              tableCount == other.tableCount else { return false }
        for (left, right) in zip(parts, other.parts) {
            try Task.checkCancellation(); if left != right { return false }
        }
        // nil and [] are different knowledge states.
        guard (references == nil) == (other.references == nil),
              (tables == nil) == (other.tables == nil),
              (references?.count ?? 0) == (other.references?.count ?? 0),
              (tables?.count ?? 0) == (other.tables?.count ?? 0) else { return false }
        for (left, right) in zip(references ?? [], other.references ?? []) {
            try Task.checkCancellation(); if left != right { return false }
        }
        for (left, right) in zip(tables ?? [], other.tables ?? []) {
            try Task.checkCancellation(); if left != right { return false }
        }
        return true
    }
}
