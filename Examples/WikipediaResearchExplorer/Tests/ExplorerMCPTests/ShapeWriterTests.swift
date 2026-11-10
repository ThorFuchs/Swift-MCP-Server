// SPDX-License-Identifier: Apache-2.0
// Actual PUBLIC JSON writer comparisons, authored Swift Testing source, NOT_RUN.
import Foundation
import Testing
import JSON
import MCPProtocol
@testable import ExplorerMCP
import ExplorerDomain

private struct ShapeText: Encodable, Sendable { let type = "text"; let text: String }
private struct ShapeOutcome<Value: Encodable & Sendable>: Encodable, Sendable {
    let status: String, value: Value?, problem: ExplorerProblem?
}
private struct ShapeEnvelope<Value: Encodable & Sendable>: Encodable, Sendable {
    let resultType = "complete"
    let content: [ShapeText]
    let structuredContent: ShapeOutcome<Value>
    let isError: Bool
}
private func actualBytes<T: Encodable>(_ value: T, ceiling: Int) throws -> Int {
    var limits = JSONLimits.balanced; limits[.outputBytes] = UInt64(ceiling)
    let json = try JSONValueEncoder(options:.init(limits:limits)).encodeWithReport(value).result
    return try WireCodec.write(json,limits:limits).result.count
}
/// Each admitted model is checked BOTH alone and inside the complete tool envelope.
/// Shape-only values do not certify provider/input schemas or catalogue dispatch.
private func compare<T: ResponseShape>(_ value: T, summary: String = "Synthetic fixture result; inspect structuredContent.") throws {
    let ceiling = ExplorerResponsePolicy.maximumToolBytes
    var direct = ResponseUpperBound(ceiling:ceiling); value.bound(&direct)
    try #require(direct.admitted)
    let bytes = try actualBytes(value,ceiling:ceiling)
    #expect(bytes <= direct.upper && direct.upper <= ceiling)
    let m = ToolAdmission.measure(value,problem:nil,summary:summary,ceiling:ceiling)
    try #require(m.admitted)
    let envelope = ShapeEnvelope(content:[ShapeText(text:summary)],structuredContent:ShapeOutcome(status:"ok",value:value,problem:nil),isError:false)
    let total = try actualBytes(envelope,ceiling:ceiling)
    #expect(total <= m.upper && m.upper <= ceiling && m.visitedWork <= 1048576)
}
private let sid = SnapshotID(provider:"synthetic-fixture",project:"fixture-enwiki",pageID:"p",revisionID:"r1",normalizerVersion:"fixture-1")
private func prov(present: Bool = false, long: Bool = false) -> Provenance {
    .init(identity:sid,title:long ? String(repeating:"h",count:512) : "Synthetic α",sourceURL:"fixture://p/r1",retrievedAt:"1970-01-01T00:00:00Z",modifiedAt:present ? "1970-01-01T00:00:00Z" : nil,language:present ? "en" : nil,license:"Apache-2.0 synthetic",synthetic:true)
}
struct ShapeWriterTests {
    @Test func identityLocationProvenanceAndCandidateFields() throws {
        try compare(sid)
        try compare(PartLocation(snapshot:sid,partID:"p1"))
        for present in [false,true] {
            try compare(prov(present:present,long:present))
            try compare(Candidate(id:"c",project:"fixture-enwiki",pageID:"p",title:"ASCII \" \\ α — π \u{0001}",description:present ? String(repeating:"d",count:1024) : nil))
            try compare(OutlineSection(location:.init(snapshot:sid,partID:"p"),parentPartID:present ? "parent" : nil,depth:present ? 32 : 0,heading:present ? "α \"\\\u{0001}" : nil))
            try compare(ReferenceEntry(id:"r",title:"Synthetic",url:present ? "fixture://r" : nil,synthetic:present))
        }
    }
    @Test func everyResultHasAdmittedEmptyAndPopulatedBoundaries() throws {
        for populated in [false,true] {
            let candidates = populated ? (0..<20).map { Candidate(id:"c\($0)",project:"fixture-enwiki",pageID:"p\($0)",title:"Synthetic",description:"owned") } : []
            try compare(SearchPage(candidates:candidates,truncated:populated,provider:"synthetic-fixture",query:"α \" \\ \u{0001}"))
            let rows = populated ? (0..<128).map { OutlineSection(location:.init(snapshot:sid,partID:"p\($0)"),parentPartID:"p",depth:1,heading:"h") } : []
            try compare(Outline(snapshot:sid,provenance:prov(present:populated),introduction:populated ? "intro \u{0001}" : nil,sections:rows,totalSections:populated ? 4096 : 0,introductionTruncated:populated,referenceCount:populated ? 20 : nil,tableCount:populated ? 1 : 0,truncated:populated))
            try compare(SectionPassage(snapshot:sid,provenance:prov(),selectedPartID:"p",includedPartIDs:populated ? (0..<128).map { "p\($0)" } : [],text:populated ? String(repeating:"α\"\\\u{0001}",count:64) : "",textAvailable:populated,truncated:populated,continuationSupported:false))
            let refs = populated ? (0..<20).map { ReferenceEntry(id:"r\($0)",title:"Synthetic",url:"fixture://r",synthetic:true) } : []
            let associations = populated ? (0..<64).map { CitationAssociation(partID:"p",referenceID:"r\($0)",resolved:$0 % 2 == 0) } : []
            try compare(SectionReferences(snapshot:sid,provenance:prov(),references:refs,associations:associations,unresolvedIDs:populated ? (0..<64).map { "r\($0)" } : [],truncated:populated,independentlyVerified:false))
        }
        try compare(CitationAssociation(partID:"p",referenceID:"r",resolved:false))
        try compare(CitationAssociation(partID:"p",referenceID:"r",resolved:true))
    }
    @Test func everyPublicProblemAndCompleteErrorEnvelope() throws {
        let codes: [ExplorerProblem.Code] = [.invalidArguments,.projectNotAllowed,.unknownCandidate,.absentPage,.absentSnapshot,.absentSection,.revisionMismatch,.ambiguousTitle,.missingReferences,.unsupportedVariant,.budgetExceeded,.upstreamUnavailable,.upstreamRateLimited,.upstreamTimedOut,.invalidFixture]
        #expect(codes.count == 15 && Set(codes.map(\.rawValue)).count == 15)
        for code in codes {
            let problem = PublicProblems.project(code)
            try compare(problem) // direct fields + admitted nonempty success envelope of the same model
            let summary = "read_article_section: \(code.rawValue). \(problem.recovery)"
            let m = ToolAdmission.measure(Optional<SectionPassage>.none,problem:problem,summary:summary,ceiling:98304)
            try #require(m.admitted)
            let envelope = ShapeEnvelope<SectionPassage>(content:[ShapeText(text:summary)],structuredContent:.init(status:"error",value:nil,problem:problem),isError:true)
            #expect(try actualBytes(envelope,ceiling:98304) <= m.upper && m.upper <= 98304)
        }
    }
    @Test func stringsSummaryIntegersAndConservativeDenialBeforeEncoding() throws {
        for string in ["", "ASCII", "\u{0000}\u{0001}\n\t\"\\", "α — π 😀", String(repeating:"h",count:512)] {
            try compare(SearchPage(candidates:[.init(id:"c",project:"fixture-enwiki",pageID:"p",title:"Synthetic",description:nil)],truncated:false,provider:"synthetic-fixture",query:string),summary:"summary " + string)
        }
        // All Swift Int values fit the documented 21 byte bound (incl Int.min).
        try compare(OutlineSection(location:.init(snapshot:sid,partID:"p"),parentPartID:nil,depth:Int.min,heading:nil))
        try compare(OutlineSection(location:.init(snapshot:sid,partID:"p"),parentPartID:nil,depth:Int.max,heading:nil))
        let large = SectionPassage(snapshot:sid,provenance:prov(),selectedPartID:"p",includedPartIDs:["p"],text:String(repeating:"\u{0001}",count:32768),textAvailable:true,truncated:false,continuationSupported:false)
        let candidate = ToolAdmission.measure(large,problem:nil,summary:"synthetic",ceiling:98304)
        #expect(!candidate.admitted)
        var encodedLarge = false
        // Same selection order as owned ExplorerTools: no candidate encoder is
        // called after conservative denial. No retry after any JSON failure.
        if candidate.admitted { encodedLarge = true; _ = try actualBytes(large,ceiling:98304) }
        let problem = PublicProblems.project(.budgetExceeded)
        let summary = "read_article_section: budget_exceeded. Select a narrower section or smaller limit."
        let fallback = ToolAdmission.measure(Optional<SectionPassage>.none,problem:problem,summary:summary,ceiling:98304)
        try #require(fallback.admitted)
        let selected = ShapeEnvelope<SectionPassage>(content:[ShapeText(text:summary)],structuredContent:.init(status:"error",value:nil,problem:problem),isError:true)
        let selectedBytes = try actualBytes(selected,ceiling:98304)
        #expect(!encodedLarge && selectedBytes <= fallback.upper)
        #expect(candidate.visitedWork + fallback.visitedWork <= 1048576)
    }
}
