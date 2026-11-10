// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain

/// Sole policy for the fixed WRE server factory; not a general SDK envelope API.
public enum ExplorerResponsePolicy {
    public static let finalRPCBytes = 131_072
    public static let outerReserveBytes = 32_768
    public static let maximumToolBytes = finalRPCBytes - outerReserveBytes
    public static let preflightWork: UInt64 = 1_048_576
    public static func toolCeiling(requested: Int) -> Int { min(requested, maximumToolBytes) }
}

/// Capped conservative bound, not serialization. No JSON bytes/AST are produced.
/// Static keys use exact ASCII lengths; strings use 2+6*UTF8, integers 21,
/// booleans 5, absent optionals 4, arrays/objects overcount commas by one.
struct ResponseUpperBound {
    let ceiling: Int
    private(set) var upper = 0
    private(set) var admitted = true
    private(set) var visitedWork: UInt64 = 0
    init(ceiling: Int) { self.ceiling = ceiling }
    private mutating func visit(_ n: UInt64) {
        let (sum, overflow) = visitedWork.addingReportingOverflow(n)
        guard !overflow, sum <= ExplorerResponsePolicy.preflightWork else { admitted = false; return }
        visitedWork = sum
    }
    mutating func add(_ n: Int) {
        guard admitted else { return }
        visit(1)
        guard admitted else { return }
        guard n >= 0, n <= ceiling - upper else { admitted = false; return }
        upper += n
    }
    mutating func string(_ s: String) {
        guard admitted else { return }
        let n = s.utf8.count
        visit(UInt64(n) + 1)
        add(2)
        guard admitted else { return }
        guard n <= (ceiling - upper) / 6 else { admitted = false; return }
        add(n * 6)
    }
    mutating func object(_ keys: [String]) {
        add(2)
        for key in keys { guard admitted else { break }; add(key.utf8.count + 4) } // quotes, colon, excess comma
    }
    mutating func array(_ n: Int) { add(2); add(n) }
}
protocol ResponseShape: Encodable, Sendable {
    func bound(_ meter: inout ResponseUpperBound)
}
struct ToolAdmission {
    static func measure<Value: ResponseShape>(_ value: Value?, problem: ExplorerProblem?,
        summary: String, ceiling: Int) -> ResponseUpperBound {
        var m = ResponseUpperBound(ceiling: ceiling)
        m.object(["resultType", "content", "structuredContent", "isError"])
        m.string("complete"); m.array(1); m.object(["type", "text"])
        m.string("text"); m.string(summary); m.add(5)
        if let problem {
            m.object(["status", "problem"]); m.string("error"); problem.bound(&m)
        } else if let value {
            m.object(["status", "value"]); m.string("ok"); value.bound(&m)
        } else { m.add(ceiling) } // unreachable state cannot be admitted
        return m
    }
}

extension SnapshotID: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["provider", "project", "pageID", "revisionID", "normalizerVersion"])
        if !m.admitted { return }; m.string(provider)
        if !m.admitted { return }; m.string(project)
        if !m.admitted { return }; m.string(pageID)
        if !m.admitted { return }; m.string(revisionID)
        if !m.admitted { return }; m.string(normalizerVersion)
    }
}

extension PartLocation: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["snapshot", "partID"])
        if !m.admitted { return }; snapshot.bound(&m)
        if !m.admitted { return }; m.string(partID)
    }
}

extension Provenance: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["identity", "title", "sourceURL", "retrievedAt", "modifiedAt", "language", "license", "synthetic"])
        if !m.admitted { return }; identity.bound(&m)
        if !m.admitted { return }; m.string(title)
        if !m.admitted { return }; m.string(sourceURL)
        if !m.admitted { return }; m.string(retrievedAt)
        if !m.admitted { return }; if let v = modifiedAt { m.string(v) } else { m.add(4) }
        if !m.admitted { return }; if let v = language { m.string(v) } else { m.add(4) }
        if !m.admitted { return }; m.string(license)
        if !m.admitted { return }; m.add(5)
    }
}

extension Candidate: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["id", "project", "pageID", "title", "description"])
        if !m.admitted { return }; m.string(id)
        if !m.admitted { return }; m.string(project)
        if !m.admitted { return }; m.string(pageID)
        if !m.admitted { return }; m.string(title)
        if !m.admitted { return }; if let v = description { m.string(v) } else { m.add(4) }
    }
}

extension SearchPage: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["candidates", "truncated", "provider", "query"])
        if !m.admitted { return }; m.array(candidates.count); for v in candidates { guard m.admitted else { break }; v.bound(&m) }
        if !m.admitted { return }; m.add(5)
        if !m.admitted { return }; m.string(provider)
        if !m.admitted { return }; m.string(query)
    }
}

extension OutlineSection: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["location", "parentPartID", "depth", "heading"])
        if !m.admitted { return }; location.bound(&m)
        if !m.admitted { return }; if let v = parentPartID { m.string(v) } else { m.add(4) }
        if !m.admitted { return }; m.add(21)
        if !m.admitted { return }; if let v = heading { m.string(v) } else { m.add(4) }
    }
}

extension Outline: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["snapshot", "provenance", "introduction", "sections", "totalSections", "introductionTruncated", "referenceCount", "tableCount", "truncated"])
        if !m.admitted { return }; snapshot.bound(&m)
        if !m.admitted { return }; provenance.bound(&m)
        if !m.admitted { return }; if let v = introduction { m.string(v) } else { m.add(4) }
        if !m.admitted { return }; m.array(sections.count); for v in sections { guard m.admitted else { break }; v.bound(&m) }
        if !m.admitted { return }; m.add(21)
        if !m.admitted { return }; m.add(5)
        if !m.admitted { return }; m.add(referenceCount == nil ? 4 : 21)
        if !m.admitted { return }; m.add(21)
        if !m.admitted { return }; m.add(5)
    }
}

extension SectionPassage: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["snapshot", "provenance", "selectedPartID", "includedPartIDs", "text", "textAvailable", "truncated", "continuationSupported"])
        if !m.admitted { return }; snapshot.bound(&m)
        if !m.admitted { return }; provenance.bound(&m)
        if !m.admitted { return }; m.string(selectedPartID)
        if !m.admitted { return }; m.array(includedPartIDs.count); for v in includedPartIDs { guard m.admitted else { break }; m.string(v) }
        if !m.admitted { return }; m.string(text)
        if !m.admitted { return }; m.add(5)
        if !m.admitted { return }; m.add(5)
        if !m.admitted { return }; m.add(5)
    }
}

extension ReferenceEntry: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["id", "title", "url", "synthetic"])
        if !m.admitted { return }; m.string(id)
        if !m.admitted { return }; m.string(title)
        if !m.admitted { return }; if let v = url { m.string(v) } else { m.add(4) }
        if !m.admitted { return }; m.add(5)
    }
}

extension CitationAssociation: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["partID", "referenceID", "resolved"])
        if !m.admitted { return }; m.string(partID)
        if !m.admitted { return }; m.string(referenceID)
        if !m.admitted { return }; m.add(5)
    }
}

extension SectionReferences: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["snapshot", "provenance", "references", "associations", "unresolvedIDs", "truncated", "independentlyVerified"])
        if !m.admitted { return }; snapshot.bound(&m)
        if !m.admitted { return }; provenance.bound(&m)
        if !m.admitted { return }; m.array(references.count); for v in references { guard m.admitted else { break }; v.bound(&m) }
        if !m.admitted { return }; m.array(associations.count); for v in associations { guard m.admitted else { break }; v.bound(&m) }
        if !m.admitted { return }; m.array(unresolvedIDs.count); for v in unresolvedIDs { guard m.admitted else { break }; m.string(v) }
        if !m.admitted { return }; m.add(5)
        if !m.admitted { return }; m.add(5)
    }
}

extension ExplorerProblem: ResponseShape {
    func bound(_ m: inout ResponseUpperBound) {
        m.object(["code", "message", "recovery"])
        if !m.admitted { return }; m.string(code.rawValue)
        if !m.admitted { return }; m.string(message)
        if !m.admitted { return }; m.string(recovery)
    }
}
