// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Synchronization
import ExplorerDomain
import WikimediaAccess

private func problem(_ body: () async throws -> Void) async -> ExplorerProblem.Code? {
    do { try await body(); return nil } catch let p as ExplorerProblem { return p.code } catch { return nil }
}
private let shipped = ["fixture-observatory", "fixture-expedition", "fixture-instrument", "fixture-observations", "fixture-lanterns"]
/// Citations deliberately without metadata, by article. Anything else unresolved is a fixture defect.
private let intentionallyUnresolved: [String: Set<String>] = ["observatory": ["ref-lost-ledger"]]
private let referencesAbsent: Set<String> = ["lanterns"]

/// RE-01 (#33): the offline Riverglass collection is a coherent, fully resolvable set of articles.
struct RiverglassCollectionTests {
    private func service(_ provider: FixtureProvider, ttl: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }) throws -> ExplorerService {
        ExplorerService(provider: provider, limits: try ExplorerLimits(snapshotTTL: ttl), clock: clock)
    }

    @Test(arguments: FixtureProvider.Revision.allCases)
    func everyAdvertisedArticleResolvesWithSectionsAndCoherentReferences(edition: FixtureProvider.Revision) async throws {
        let provider = try FixtureProvider.load(revision: edition)
        let s = try service(provider)
        let page = try await s.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 20))
        #expect(page.candidates.map(\.id) == shipped && !page.truncated)
        for candidate in page.candidates {
            let outline = try await s.outline(.init(project: "fixture-enwiki", candidateID: candidate.id))
            let pageID = outline.snapshot.pageID
            #expect(outline.provenance.title == candidate.title && outline.provenance.synthetic)
            #expect(outline.provenance.sourceURL == "fixture://riverglass/\(pageID)/\(outline.snapshot.revisionID)")
            #expect(outline.provenance.license.contains("fictional") && outline.provenance.modifiedAt != nil)
            #expect(outline.sections.count >= (referencesAbsent.contains(pageID) ? 3 : 5) && outline.sections.count == outline.totalSections && !outline.truncated)
            #expect((outline.introduction?.utf8.count ?? 0) >= 200)
            var cited = Set<String>(), resolved = Set<String>(), unresolved = Set<String>(), associations = 0
            for section in outline.sections {
                let passage = try await s.section(.init(snapshot: outline.snapshot, part: section.location, maxTextBytes: nil))
                #expect(passage.snapshot == outline.snapshot && passage.textAvailable && !passage.text.isEmpty && !passage.truncated)
                #expect(section.heading?.isEmpty == false)
                if referencesAbsent.contains(pageID) {
                    // Absent metadata is never reported as a valid empty reference list.
                    #expect(await problem { _ = try await s.references(.init(snapshot: outline.snapshot, part: section.location)) } == .missingReferences)
                    #expect(outline.referenceCount == nil)
                    continue
                }
                let refs = try await s.references(.init(snapshot: outline.snapshot, part: section.location))
                #expect(refs.snapshot == outline.snapshot && !refs.independentlyVerified && !refs.truncated)
                #expect(refs.references.allSatisfy { $0.synthetic && $0.url?.hasPrefix("fixture://riverglass/references/") == true })
                cited.formUnion(refs.associations.map(\.referenceID)); associations += refs.associations.count
                resolved.formUnion(refs.references.map(\.id)); unresolved.formUnion(refs.unresolvedIDs)
            }
            guard !referencesAbsent.contains(pageID) else { continue }
            #expect(associations >= 5, "every article cites its sources")
            #expect(unresolved == intentionallyUnresolved[pageID, default: []])
            // No orphan references: every listed reference is cited by some section.
            #expect(resolved.count == outline.referenceCount)
            #expect(cited == resolved.union(unresolved))
        }
    }

    @Test func publishingTheEditionChangesOnlyTheObservatoryAndKeepsEveryPin() async throws {
        let provider = try FixtureProvider.load()
        let s = try service(provider)
        let observatory = OutlineInput(project: "fixture-enwiki", candidateID: "fixture-observatory")
        let instrument = OutlineInput(project: "fixture-enwiki", candidateID: "fixture-instrument")
        let a = try await s.outline(observatory), i1 = try await s.outline(instrument)
        #expect(await provider.edition() == .r1 && a.snapshot.revisionID == "r1")
        await provider.select(.r2)
        let b = try await s.outline(observatory), i2 = try await s.outline(instrument)
        #expect(b.snapshot.revisionID == "r2" && b.provenance.modifiedAt != a.provenance.modifiedAt)
        #expect(i2.snapshot == i1.snapshot, "pages without an r2 keep their latest earlier revision")
        let partA = try #require(a.sections.first { $0.location.partID == "p2" }?.location)
        let partB = try #require(b.sections.first { $0.location.partID == "p2" }?.location)
        let oldText = try await s.section(.init(snapshot: a.snapshot, part: partA, maxTextBytes: nil)).text
        let newText = try await s.section(.init(snapshot: b.snapshot, part: partB, maxTextBytes: nil)).text
        #expect(oldText.contains("2-metre") && !oldText.contains("2.1-metre") && !oldText.contains("remeasurement"))
        #expect(newText.contains("2.1-metre") && newText.contains("remeasurement"))
        let oldRefs = try await s.references(.init(snapshot: a.snapshot, part: partA))
        let newRefs = try await s.references(.init(snapshot: b.snapshot, part: partB))
        #expect(oldRefs.references.map(\.id) == ["ref-instrument-notes"])
        #expect(newRefs.references.map(\.id) == ["ref-instrument-notes", "ref-remeasurement-1931"])
        #expect(oldRefs.unresolvedIDs == ["ref-lost-ledger"] && newRefs.unresolvedIDs == ["ref-lost-ledger"])
        // Locators never cross revisions, in either direction.
        #expect(await problem { _ = try await s.section(.init(snapshot: a.snapshot, part: partB, maxTextBytes: nil)) } == .revisionMismatch)
        #expect(await problem { _ = try await s.references(.init(snapshot: b.snapshot, part: partA)) } == .revisionMismatch)
        // Every other section is unchanged between the editions.
        for section in a.sections where section.location.partID != "p2" {
            let moved = try #require(b.sections.first { $0.location.partID == section.location.partID }?.location)
            let left = try await s.section(.init(snapshot: a.snapshot, part: section.location, maxTextBytes: nil)).text
            let right = try await s.section(.init(snapshot: b.snapshot, part: moved, maxTextBytes: nil)).text
            #expect(left == right, "only the prepared passage differs (\(section.location.partID))")
        }
    }

    @Test func expiredPinIsReportedEvenAfterTheEditionChanges() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 0))
        let provider = try FixtureProvider.load()
        let s = try service(provider, ttl: 5, clock: { now.withLock { $0 } })
        let a = try await s.outline(.init(project: "fixture-enwiki", candidateID: "fixture-observatory"))
        await provider.select(.r2)
        now.withLock { $0 = Date(timeIntervalSince1970: 6) }
        let part = try #require(a.sections.first?.location)
        #expect(await problem { _ = try await s.section(.init(snapshot: a.snapshot, part: part, maxTextBytes: nil)) } == .absentSnapshot)
        #expect(await problem { _ = try await s.references(.init(snapshot: a.snapshot, part: part)) } == .absentSnapshot)
    }

    @Test func searchMatchesTitlesAndKeywordsDeterministically() async throws {
        let s = try service(try FixtureProvider.load())
        func ids(_ q: String, _ limit: Int? = nil) async throws -> SearchPage { try await s.search(.init(query: q, project: "fixture-enwiki", limit: limit)) }
        #expect(try await ids("telescope").candidates.map(\.id) == ["fixture-observatory", "fixture-instrument"])
        #expect(try await ids("TIDE-STAR").candidates.map(\.id) == ["fixture-observations"])
        #expect(try await ids("  ostmere  ").candidates.map(\.id) == ["fixture-expedition"])
        let none = try await ids("Wikipedia")
        #expect(none.candidates.isEmpty && !none.truncated)
        let capped = try await ids("Riverglass", 2)
        #expect(capped.candidates.map(\.id) == Array(shipped.prefix(2)) && capped.truncated)
    }

    @Test func negativeFixtureIsTestOnlyAndDistinctFromUnknownCandidates() async throws {
        let id = FixtureProvider.testOnlyNegativeCandidate.id
        let shippedService = try service(try FixtureProvider.load())
        #expect(try await shippedService.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 20)).candidates.map(\.id) == shipped)
        #expect(await problem { _ = try await shippedService.outline(.init(project: "fixture-enwiki", candidateID: id)) } == .unknownCandidate)
        let testService = try service(try FixtureProvider.load(includeTestOnlyNegativeCandidate: true))
        #expect(try await testService.search(.init(query: "Riverglass", project: "fixture-enwiki", limit: 20)).candidates.last?.id == id)
        #expect(await problem { _ = try await testService.outline(.init(project: "fixture-enwiki", candidateID: id)) } == .absentPage)
    }

    /// Provenance/licensing report: every shipped resource is owned synthetic data and makes no
    /// Wikimedia claim; reference links are inert fixture:// locators.
    @Test func shippedFixturesAreOwnedFictionalDataWithoutWikimediaClaims() throws {
        let directory = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/WikimediaAccess/Fixtures").standardized
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).filter { $0.hasSuffix(".json") }.sorted()
        #expect(files == ["expedition-r1", "instrument-r1", "lanterns-r1", "observations-r1", "observatory-r1", "observatory-r2", "search"].map { $0 + ".normalized.json" })
        var total = 0
        for file in files {
            let data = try Data(contentsOf: directory.appending(path: file))
            total += data.count
            let text = try #require(String(data: data, encoding: .utf8)).lowercased()
            #expect(text.contains("\"fixture_kind\": \"synthetic_normalized_example_not_upstream_payload\""))
            for claim in ["wikipedia", "wikimedia", "http://", "https://", "cc by-sa"] { #expect(!text.contains(claim), "\(file) mentions \(claim)") }
            if file != "search.normalized.json" { #expect(text.contains("original fictional teaching text")) }
        }
        #expect(total < 64 * 1024, "the collection stays small and reviewable")
    }
}
