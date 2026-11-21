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
    public var isBusy: Bool { [.searching, .opening, .reading, .references].contains(phase) }
    @ObservationIgnored private let client: any ResearchClient
    @ObservationIgnored private let record: @Sendable (String, Bool) async -> Void
    private enum Action { case search(String), open(Candidate), read(Outline, PartLocation) }
    @ObservationIgnored private var pending: (UInt64, Action)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var driver: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    public init(client: any ResearchClient, source: ResearchSource = .offlineDemo, record: @escaping @Sendable (String, Bool) async -> Void = { _, _ in }) {
        self.client = client; self.source = source; self.record = record
    }
    public func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.utf8.count <= 256 else {
            cancel(); problem = PublicProblems.project(.invalidArguments); phase = .problem; return
        }
        candidate = nil; outline = nil; selectedPart = nil; passage = nil; citations = nil
        enqueue(.search(q), phase: .searching)
    }
    public func open(_ candidate: Candidate) {
        self.candidate = candidate; outline = nil; selectedPart = nil; passage = nil; citations = nil
        enqueue(.open(candidate), phase: .opening)
    }
    public func read(_ part: PartLocation) {
        guard let outline, outline.snapshot == part.snapshot,
              outline.sections.contains(where: { $0.location == part }) else {
            cancel(); problem = PublicProblems.project(.revisionMismatch); phase = .problem; return
        }
        selectedPart = part; passage = nil; citations = nil
        enqueue(.read(outline, part), phase: .reading)
    }
    public func back() {
        cancel(); candidate = nil; outline = nil; passage = nil; citations = nil; selectedPart = nil
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
        let operation: String
        switch action { case .search: operation = "search_articles"; case .open: operation = "get_article_outline"; case .read: operation = "read_article_section" }
        do {
            switch action {
            case .search(let q):
                let result = try await client.search(.init(query: q, project: source.project, limit: 10))
                guard current(token) else { return }
                page = result; phase = result.candidates.isEmpty ? .empty : .candidates
            case .open(let candidate):
                let result = try await client.outline(.init(project: candidate.project, candidateID: candidate.id))
                guard current(token), self.candidate == candidate else { return }
                outline = result; phase = .outline
            case .read(let outline, let part):
                let text = try await client.section(.init(snapshot: outline.snapshot, part: part, maxTextBytes: 32768))
                guard current(token), self.outline?.snapshot == outline.snapshot, selectedPart == part else { return }
                passage = text; phase = .references
                do {
                    let refs = try await client.references(.init(snapshot: outline.snapshot, part: part))
                    guard current(token), selectedPart == part else { return }
                    citations = refs; phase = .section
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard current(token) else { return }
                    referenceProblem = publicProblem(error); phase = .section
                }
            }
            await record(operation, true)
        } catch is CancellationError {
            if token == generation, !closed { phase = .cancelled }
            await record(operation, false)
        } catch {
            guard current(token) else { return }
            problem = publicProblem(error); phase = .problem
            await record(operation, false)
        }
    }
    private func publicProblem(_ error: any Error) -> ExplorerProblem {
        source.problem((error as? ExplorerProblem)?.code ?? .upstreamUnavailable)
    }
}
