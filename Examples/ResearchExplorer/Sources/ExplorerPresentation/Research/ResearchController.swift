// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import ExplorerDomain

@MainActor @Observable public final class ResearchController {
    public let source: ResearchSource
    public var query = ""
    public private(set) var phase = ResearchPhase.idle
    public private(set) var page: SearchPage?
    public private(set) var candidate: Candidate?
    public private(set) var outline: Outline?
    public private(set) var selectedPart: PartLocation?
    public private(set) var passage: SectionPassage?
    public private(set) var citations: SectionReferences?
    public private(set) var problem: ExplorerProblem?
    public private(set) var referenceProblem: ExplorerProblem?
    /// Explicit revision check; never replaces `outline`, `passage` or `citations`.
    public private(set) var comparison: RevisionComparison?
    /// Present only for the offline demo source.
    public let offlineEdit: OfflineRevisionEdit?
    public private(set) var offlineEditPublished = false
    public var isBusy: Bool { [.searching, .opening, .reading, .references, .comparing, .publishing].contains(phase) }
    @ObservationIgnored private let client: any ResearchClient
    @ObservationIgnored private let record: @Sendable (String, Bool) async -> Void
    private enum Action {
        case search(String), open(Candidate), read(Outline, PartLocation), tour
        case compare(Candidate, Outline, PartLocation?), publishEdit
    }
    @ObservationIgnored private var pending: (UInt64, Action)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var driver: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    public init(client: any ResearchClient, source: ResearchSource = .offlineDemo, record: @escaping @Sendable (String, Bool) async -> Void = { _, _ in },
                offlineEdit: OfflineRevisionEdit? = nil) {
        self.client = client; self.source = source; self.record = record
        // A simulated edit is meaningful only for fictional data; live sources change upstream.
        self.offlineEdit = source == .offlineDemo ? offlineEdit : nil
    }
    public func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.utf8.count <= 256 else {
            cancel(); problem = PublicProblems.project(.invalidArguments); phase = .problem; return
        }
        candidate = nil; outline = nil; selectedPart = nil; passage = nil; citations = nil; comparison = nil
        enqueue(.search(q), phase: .searching)
    }
    public func open(_ candidate: Candidate) {
        self.candidate = candidate; outline = nil; selectedPart = nil; passage = nil; citations = nil; comparison = nil
        enqueue(.open(candidate), phase: .opening)
    }
    /// One click: search the collection, open the Observatory and read its telescope section with
    /// references. Offline demo only; it never reaches a live provider.
    public func exploreOfflineCollection() {
        guard source == .offlineDemo else { return }
        query = OfflineTour.query
        page = nil; candidate = nil; outline = nil; selectedPart = nil; passage = nil; citations = nil; comparison = nil
        enqueue(.tour, phase: .searching)
    }
    /// Explicitly asks the source for the candidate's current revision and, when it differs,
    /// compares the selected section. The pinned revision stays what the reader shows.
    public func compareWithLatestRevision() {
        guard !isBusy, let candidate, let outline else { return }
        comparison = nil
        enqueue(.compare(candidate, outline, selectedPart), phase: .comparing)
    }
    /// Switches the reader to the compared latest revision: an explicit user decision.
    public func adoptLatestRevision() {
        guard !isBusy, let comparison, !comparison.latestIsPinned, outline?.snapshot == comparison.pinned else { return }
        let part = comparison.partID.flatMap { id in comparison.latest.sections.first { $0.location.partID == id }?.location }
        outline = comparison.latest; self.comparison = nil
        selectedPart = nil; passage = nil; citations = nil; problem = nil; referenceProblem = nil; phase = .outline
        if let part { read(part) }
    }
    /// Offline demo only: publishes the prepared upstream edit. Open outlines remain pinned.
    public func publishOfflineEdit() {
        guard !isBusy, offlineEdit != nil, !offlineEditPublished else { return }
        enqueue(.publishEdit, phase: .publishing)
    }
    public func read(_ part: PartLocation) {
        guard let outline, outline.snapshot == part.snapshot,
              outline.sections.contains(where: { $0.location == part }) else {
            cancel(); problem = PublicProblems.project(.revisionMismatch); phase = .problem; return
        }
        selectedPart = part; passage = nil; citations = nil; comparison = nil
        enqueue(.read(outline, part), phase: .reading)
    }
    public func back() {
        cancel(); candidate = nil; outline = nil; passage = nil; citations = nil; selectedPart = nil; comparison = nil
        problem = nil; referenceProblem = nil; phase = page == nil ? .idle : .candidates
    }
    public func refreshOutline() { if let candidate { open(candidate) } }
    public func cancel() {
        generation &+= 1; pending = nil; worker?.cancel()
        if isBusy { phase = .cancelled }
    }
    public func waitUntilIdle() async { await driver?.value }
    public func shutdown() async { closed = true; cancel(); await driver?.value }

    // One driver, one worker and one replacement, regardless of click rate.
    // Superseded work is cancelled AND joined before the next service operation.
    private func enqueue(_ action: Action, phase: ResearchPhase) {
        guard !closed else { return }
        generation &+= 1; pending = (generation, action); worker?.cancel()
        problem = nil; referenceProblem = nil; self.phase = phase
        guard driver == nil else { return }
        driver = Task { [self] in
            while let (token, action) = pending {
                pending = nil
                let task = Task { await self.perform(action, token: token) }
                worker = task; await task.value; worker = nil
            }
            driver = nil
        }
    }
    private func current(_ token: UInt64) -> Bool { token == generation && !closed && !Task.isCancelled }
    private func perform(_ action: Action, token: UInt64) async {
        // Multi-step actions record each completed step; `operation` names the step in progress.
        var operation = ""
        do {
            switch action {
            case .search(let q):
                operation = "search_articles"
                let result = try await client.search(.init(query: q, project: source.project, limit: 10))
                guard current(token) else { return }
                page = result; phase = result.candidates.isEmpty ? .empty : .candidates
            case .open(let candidate):
                operation = "get_article_outline"
                let result = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
                guard current(token), self.candidate == candidate else { return }
                outline = result; phase = .outline
            case .read(let outline, let part):
                operation = "read_article_section"
                guard try await readSection(outline, part, token: token) else { return }
            case .tour:
                operation = "search_articles"
                let result = try await client.search(.init(query: OfflineTour.query, project: source.project, limit: 10))
                guard current(token) else { return }
                page = result
                guard let candidate = result.candidates.first(where: { $0.id == OfflineTour.candidateID }) else {
                    throw PublicProblems.project(.unknownCandidate)
                }
                await record(operation, true)
                operation = "get_article_outline"; self.candidate = candidate; phase = .opening
                let opened = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
                guard current(token) else { return }
                outline = opened; phase = .outline
                guard let part = opened.sections.first(where: { $0.location.partID == OfflineTour.partID })?.location else {
                    throw PublicProblems.project(.absentSection)
                }
                await record(operation, true)
                operation = "read_article_section"; selectedPart = part; phase = .reading
                guard try await readSection(opened, part, token: token) else { return }
            case .compare(let candidate, let pinned, let part):
                operation = "get_article_outline"
                let latest = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
                guard current(token) else { return }
                var passage = RevisionComparison.Passage.notCompared
                if let part, latest.snapshot != pinned.snapshot {
                    await record(operation, true)
                    operation = "read_article_section"
                    // Re-read the pinned text from its own snapshot: an expired pin is reported, not replaced.
                    let old = try await client.section(.init(snapshot: pinned.snapshot, part: part, maxTextBytes: 32768))
                    if let moved = latest.sections.first(where: { $0.location.partID == part.partID })?.location {
                        let new = try await client.section(.init(snapshot: latest.snapshot, part: moved, maxTextBytes: 32768))
                        passage = old.text == new.text ? .unchanged(new.text) : .changed(pinned: old.text, latest: new.text)
                    } else { passage = .absentInLatest }
                }
                guard current(token), outline?.snapshot == pinned.snapshot, selectedPart == part else { return }
                comparison = .init(pinned: pinned.snapshot, latest: latest, partID: part?.partID, passage: passage)
                phase = restingPhase()
            case .publishEdit:
                await offlineEdit?.publish()
                offlineEditPublished = true // the source changed even if this action was superseded
                guard current(token) else { return }
                phase = restingPhase()
            }
            if !operation.isEmpty { await record(operation, true) }
        } catch is CancellationError {
            if token == generation, !closed { phase = .cancelled }
            if !operation.isEmpty { await record(operation, false) }
        } catch {
            guard current(token) else { return }
            problem = publicProblem(error); phase = .problem
            if !operation.isEmpty { await record(operation, false) }
        }
    }
    /// False when superseded: nothing landed and the step is not recorded as completed.
    private func readSection(_ outline: Outline, _ part: PartLocation, token: UInt64) async throws -> Bool {
        let text = try await client.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: 32768))
        guard current(token), self.outline?.snapshot == outline.snapshot, selectedPart == part else { return false }
        passage = text; phase = .references
        do {
            let refs = try await client.references(.init(snapshot: outline.snapshot, part: part))
            guard current(token), selectedPart == part else { return false }
            citations = refs; phase = .section
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard current(token) else { return false }
            referenceProblem = publicProblem(error); phase = .section
        }
        return true
    }
    private func restingPhase() -> ResearchPhase {
        if passage != nil || citations != nil || referenceProblem != nil { return .section }
        if outline != nil { return .outline }
        if let page { return page.candidates.isEmpty ? .empty : .candidates }
        return .idle
    }
    private func publicProblem(_ error: any Error) -> ExplorerProblem {
        source.problem((error as? ExplorerProblem)?.code ?? .upstreamUnavailable)
    }
}
