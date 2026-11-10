// SPDX-License-Identifier: Apache-2.0
// WRE1 test SOURCE. Native execution: NOT_RUN.
import Foundation
import Synchronization
import Testing
@testable import ExplorerDomain

private func part(_ id: String = "p", text: String? = "hello", citations: [String]? = nil, children: [PartSeed]? = nil, kind: String? = nil) -> PartSeed {
    .init(id: id, heading: "Heading", text: text, kind: kind, citations: citations, parts: children)
}
private func seed(_ parts: [PartSeed], references: [ReferenceSeed]? = []) -> ArticleSeed {
    .init(fixtureKind: "synthetic_normalized_example_not_upstream_payload", formatVersion: "wre-fixture-1",
        project: "fixture-enwiki", pageID: "observatory", revisionID: "r1", title: "Synthetic",
        sourceURL: "fixture://riverglass/observatory/r1", normalizerVersion: "fixture-1", license: "Apache-2.0 (synthetic)",
        parts: parts, references: references, tables: nil, modifiedAt: nil)
}
private func snapshot(_ seed: ArticleSeed) throws -> Snapshot {
    try Normalizer.normalize(seed, retrievedAt: Date(timeIntervalSince1970: 0), limits: ExplorerLimits())
}
private func expectProblem(_ code: ExplorerProblem.Code, _ body: () throws -> Void) {
    do { try body(); Issue.record("Expected \(code)") }
    catch let problem as ExplorerProblem { #expect(problem.code == code) }
    catch { Issue.record("Unexpected error: \(error)") }
}
struct DomainTests {
    @Test func introductionTruncationIsAggregateWithFewSections_T01() throws {
        let s = try snapshot(seed([part("intro", text: String(repeating: "x", count: 1025))]))
        let outline = try SnapshotProjection.outline(s)
        #expect(outline.sections.count == 1)
        #expect(outline.introduction?.utf8.count == 1024)
        #expect(outline.introductionTruncated && outline.truncated)
    }
    @Test func sectionAndIntroductionTruncationAreIndependent_T02() throws {
        let rows = (0..<129).map { part("p\($0)", text: "short") }
        let a = try SnapshotProjection.outline(snapshot(seed(rows)))
        #expect(a.sections.count == 128 && a.totalSections == 129)
        #expect(a.truncated && !a.introductionTruncated)
        let both = [part("intro", text: String(repeating: "x", count: 1025))] + rows
        let b = try SnapshotProjection.outline(snapshot(seed(both)))
        #expect(b.truncated && b.introductionTruncated && b.totalSections == 130)
    }
    @Test func exactIntroductionUTF8BoundaryIsLossless_T03() throws {
        let text = String(repeating: "α", count: 512)
        let a = try SnapshotProjection.outline(snapshot(seed([part(text: text)])))
        #expect(a.introduction == text && !a.introductionTruncated && !a.truncated)
        let b = try SnapshotProjection.outline(snapshot(seed([part(text: text + "π")])))
        #expect(b.introduction == text && b.introductionTruncated && b.truncated)
    }
    @Test func preorderIdentityAndMissingMetadataArePreserved() throws {
        let a = try snapshot(seed([part("a", children: [part("b")]), part("c")]))
        let b = try snapshot(seed([part("a", children: [part("b")]), part("c")]))
        #expect(a.parts == b.parts)
        #expect(a.parts.map(\.id) == ["a", "b", "c"])
        #expect(a.parts.map(\.parentID) == [nil, "a", nil])
        #expect(a.provenance == b.provenance)
        #expect(a.provenance.language == nil && a.provenance.modifiedAt == nil)
        #expect(a.provenance.identity.revisionID == "r1")
    }
    @Test func utf8ClippingNeverSplitsScalarAndMarksTruncation() throws {
        let value = try Normalizer.prefix("α — π", maximumBytes: 5)
        #expect(value.text == "α ")
        #expect(value.text.utf8.count == 3 && value.truncated)
        #expect(try Normalizer.prefix("α", maximumBytes: 2).truncated == false)
        #expect(try Normalizer.prefix("α", maximumBytes: 1).text.isEmpty)
    }
    @Test func absentTextDoesNotMasqueradeAsSuppliedEmptyText() throws {
        let absent = try snapshot(seed([part(text: nil)]))
        let empty = try snapshot(seed([part(text: "")]))
        let a = try SnapshotProjection.section(absent, part: .init(snapshot: absent.provenance.identity, partID: "p"), maximumBytes: 32)
        let b = try SnapshotProjection.section(empty, part: .init(snapshot: empty.provenance.identity, partID: "p"), maximumBytes: 32)
        #expect(a.text.isEmpty && b.text.isEmpty)
        #expect(!a.textAvailable && b.textAvailable)
    }
    @Test func repeatedIDsUnsupportedKindsDepthAndBreadthAreDenied() throws {
        expectProblem(.budgetExceeded) { _ = try snapshot(seed([part("same"), part("same")])) }
        expectProblem(.unsupportedVariant) { _ = try snapshot(seed([part(kind: "script")])) }
        var deep = part("n33")
        for i in (1...32).reversed() { deep = part("n\(i)", children: [deep]) }
        expectProblem(.budgetExceeded) { _ = try snapshot(seed([deep])) }
        let broad = (0..<4097).map { part("p\($0)") }
        expectProblem(.budgetExceeded) { _ = try snapshot(seed(broad)) }
        expectProblem(.budgetExceeded) { _ = try snapshot(seed([part(text: String(repeating: "x", count: 4_194_305))])) }
    }
    @Test func subtreeExcludesFollowingSiblingAndRejectsRevisionMixing() throws {
        let s = try snapshot(seed([part("a", text: "parent", children: [part("b", text: "child")]), part("c", text: "sibling")]))
        let id = s.provenance.identity
        let passage = try SnapshotProjection.section(s, part: .init(snapshot: id, partID: "a"), maximumBytes: 32768)
        #expect(passage.text == "parent\n\nchild")
        #expect(passage.includedPartIDs == ["a", "b"] && !passage.continuationSupported)
        let wrong = SnapshotID(provider: id.provider, project: id.project, pageID: id.pageID, revisionID: "r2", normalizerVersion: id.normalizerVersion)
        expectProblem(.revisionMismatch) { _ = try SnapshotProjection.section(s, part: .init(snapshot: wrong, partID: "a"), maximumBytes: 32) }
        expectProblem(.absentSection) { _ = try SnapshotProjection.section(s, part: .init(snapshot: id, partID: "absent"), maximumBytes: 32) }
        expectProblem(.invalidArguments) { _ = try SnapshotProjection.section(s, part: .init(snapshot: id, partID: "a"), maximumBytes: -1) }
    }
    @Test func referenceAbsenceEmptyAndUnresolvedAreDifferentOutcomes() throws {
        let r = ReferenceSeed(id: "r", title: "Synthetic source", url: nil, synthetic: true)
        let s = try snapshot(seed([part("a", citations: ["r", "missing"])], references: [r]))
        let result = try SnapshotProjection.references(s, part: .init(snapshot: s.provenance.identity, partID: "a"))
        #expect(result.unresolvedIDs == ["missing"])
        #expect(result.associations.map(\.resolved) == [true, false])
        #expect(result.references.map(\.id) == ["r"] && !result.independentlyVerified)
        let absent = try snapshot(seed([part()], references: nil))
        expectProblem(.missingReferences) { _ = try SnapshotProjection.references(absent, part: .init(snapshot: absent.provenance.identity, partID: "p")) }
        let empty = try snapshot(seed([part()], references: []))
        #expect(try SnapshotProjection.references(empty, part: .init(snapshot: empty.provenance.identity, partID: "p")).references.isEmpty)
    }
    @Test func sectionAndReferenceMetadataHaveFinitePrefixes() throws {
        let kids = (0..<140).map { part("c\($0)", text: "x", citations: ["ref\($0)"]) }
        let refs = (0..<140).map { ReferenceSeed(id: "ref\($0)", title: "Synthetic", url: nil, synthetic: true) }
        let s = try snapshot(seed([part("root", children: kids)], references: refs))
        let loc = PartLocation(snapshot: s.provenance.identity, partID: "root")
        let text = try SnapshotProjection.section(s, part: loc, maximumBytes: 32768)
        let citations = try SnapshotProjection.references(s, part: loc)
        #expect(text.includedPartIDs.count == 128 && text.truncated)
        #expect(citations.references.count == 20 && citations.truncated)
        #expect(try SnapshotProjection.outline(s).sections.count == 128)
    }
    @Test func alreadyCancelledNormalizationCannotSucceed() async throws {
        let value = seed([part()])
        let start = Mutex(false)
        let task = Task {
            while !start.withLock({ $0 }) { try Task.checkCancellation(); await Task.yield() }
            return try snapshot(value)
        }
        task.cancel(); start.withLock { $0 = true }
        do { _ = try await task.value; Issue.record("Cancellation must propagate") }
        catch is CancellationError { }
    }
}
