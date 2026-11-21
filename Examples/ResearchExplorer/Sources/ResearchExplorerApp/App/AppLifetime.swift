// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit
import Observation
import ExplorerDomain
import WikimediaAccess
import ExplorerPresentation

enum Workspace: String, CaseIterable, Identifiable { case research = "Research", server = "Server", activity = "Activity"
    var id: String { rawValue }
    var symbol: String { switch self { case .research: "magnifyingglass"; case .server: "server.rack"; case .activity: "waveform.path" } }
}
@MainActor @Observable final class AppLifetime {
    private(set) var profile: SourceProfile
    let termination = AppTerminationController()
    var canSwitchSource: Bool { !isQuitting && !termination.unsettled && bootstrap == nil && server?.phase == .stopped && server?.cleanupDebt == false }
    let activity: ActivityStore
    var activitySnapshot = ActivitySnapshot.empty
    private(set) var server: ServerController?
    var exporting = false
    var exportProblem: String?
    private var exportCleanupDebt = false
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private let exportWriter: ActivityExportWriter
    @ObservationIgnored private let loadService: @Sendable (SourceProfile) async throws -> ExplorerService
    @ObservationIgnored private let makeHost: @Sendable (ExplorerService, ActivityStore, UUID) throws -> any ExplorerHTTPHost
    private(set) var service: ExplorerService?
    private(set) var research: ResearchController?
    private(set) var startupProblem: String?
    var destination = Workspace.research
    var searchFocus = UUID()
    var isQuitting = false
    weak var mainWindow: NSWindow?
    @ObservationIgnored private var bootstrap: Task<Void, Never>?
    init(profile: SourceProfile = .wikipediaEnglish,
         loadService: @escaping @Sendable (SourceProfile) async throws -> ExplorerService = { try await AppResources.loadService(profile: $0) },
         makeHost: @escaping @Sendable (ExplorerService, ActivityStore, UUID) throws -> any ExplorerHTTPHost = { service, activity, id in
             SDKHTTPHost(service: service, activity: activity, runID: id, configuration: try LocalEndpoint(port: 8765))
         }, exportWriter: ActivityExportWriter = ActivityExportWriter()) {
        self.profile = profile; self.loadService = loadService; self.makeHost = makeHost
        self.exportWriter = exportWriter; activity = ActivityStore()
    }
    func waitUntilPrepared() async { await bootstrap?.value }
    func waitUntilExportSettled() async { await exportTask?.value }
    func waitForTerminationSettlement() async { await termination.waitUntilSettled() }
    func prepare() {
        observe()
        guard bootstrap == nil, service == nil, startupProblem == nil, !isQuitting else { return }
        let activity = self.activity, makeHost = self.makeHost
        bootstrap = Task { [self] in
            defer { bootstrap = nil }
            do {
                let service = try await loadService(profile)
                try Task.checkCancellation()
                self.service = service
                research = ResearchController(client: service, source: profile, record: { operation, success in await activity.localResearch(operation, success: success, profile: service.profile) })
                server = ServerController(activity: activity, factory: { runID in
                    try makeHost(service, activity, runID)
                })
            } catch is CancellationError { /* quit owns and joins bootstrap */ }
            catch { startupProblem = "The selected source could not be prepared. No fictional fallback was substituted. Check the complete app resource bundles." }
        }
    }
    func observe() {
        guard observation == nil else { return }
        observation = Task { [weak self, activity] in
            while !Task.isCancelled {
                let snapshot = await activity.snapshot()
                guard !Task.isCancelled else { break }; self?.activitySnapshot = snapshot
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }
    func startServer() { guard !isQuitting, !termination.unsettled else { return }; server?.start() }
    func selectSource(_ profile: SourceProfile) {
        guard profile != self.profile, canSwitchSource else { return }
        isQuitting = true // quiesces every mutating UI action during handoff
        bootstrap = Task { [self] in
            await research?.shutdown() // keep the old owner until its actual join
            do {
                let selected = try await loadService(profile)
                try Task.checkCancellation()
                self.profile = profile; service = selected
                research = ResearchController(client: selected, source: profile, record: { [activity] op, ok in
                    await activity.localResearch(op, success: ok, profile: profile)
                })
                server = ServerController(activity: activity, factory: { [activity, makeHost] id in
                    try makeHost(selected, activity, id)
                })
            } catch {
                startupProblem = "Source handoff failed. The old source was not relabelled."
                // The old driver joined before handoff. A failed construction
                // must not leave its retained service with a closed controller.
                if let service {
                    research = ResearchController(client: service, source: self.profile, record: { [activity] op, ok in
                        await activity.localResearch(op, success: ok, profile: service.profile)
                    })
                }
            }
            bootstrap = nil; isQuitting = false
        }
    }
    func export(filter: ActivityFilter) {
        guard exportTask == nil, !isQuitting, !termination.unsettled else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Explorer-activity.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        beginExport(filter: filter, destination: destination)
    }
    func beginExport(filter: ActivityFilter, destination: URL) {
        guard exportTask == nil, !isQuitting, !termination.unsettled else { return }
        let snapshot = activitySnapshot
        exporting = true
        exportTask = Task { [self] in
            defer { exporting = false; exportTask = nil }
            do {
                // Bounded writer actor does JSON + disk work away from UI rendering.
                try await exportWriter.encodeAndWrite(snapshot, filter: filter, to: destination)
            } catch is ExportSettlementFailure {
                exportCleanupDebt = true; exportProblem = "Export failed and its owned temporary-file cleanup is unresolved. The app will retain this failure when Quit is requested."
            } catch is CancellationError { exportProblem = "Export was cancelled. Owned partial output was removed." }
            catch { exportProblem = "Export was denied or could not be committed. No provider payload, credentials or arbitrary error description was retained." }
        }
    }
    func quit(waitMilliseconds: Int = 10_000) async -> Bool {
        guard !isQuitting, !termination.unsettled else { return false }
        isQuitting = true
        let clean = await termination.request(waitMilliseconds: waitMilliseconds, settle: { [self] in
            bootstrap?.cancel(); await bootstrap?.value
            await research?.shutdown()
            exportTask?.cancel(); await exportTask?.value
            let serverClean = await server?.stopAndJoin() ?? true
            guard serverClean, !exportCleanupDebt else { return false }
            observation?.cancel(); await observation?.value; observation = nil
            return true
        }, recover: { [self] in
            // Called only after the old Research driver actually joined.
            if let service {
                research = ResearchController(client: service, source: profile, record: { [activity] op, ok in
                    await activity.localResearch(op, success: ok, profile: service.profile)
                })
            }
            isQuitting = false
            if service == nil { startupProblem = nil; prepare() } else { observe() }
        })
        if !clean { isQuitting = false }
        return clean
    }
}
/// Narrow asynchronous termination bridge; no process signals or synchronous actor wait.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var lifetime: AppLifetime?
    private var quitting: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitting == nil, let lifetime else { return quitting == nil ? .terminateNow : .terminateCancel }
        quitting = Task {
            let clean = await lifetime.quit()
            sender.reply(toApplicationShouldTerminate: clean)
            if !clean {
                quitting = nil
                let alert = NSAlert(); alert.messageText = "The app has not finished cleanup"
                alert.informativeText = "The app retained unsettled owners. Research becomes available after its old work joins. Server or export cleanup debt remains visible; no join was manufactured."
                alert.addButton(withTitle: "Return to Explorer"); alert.runModal()
            }
        }
        return .terminateLater
    }
}
struct WindowReference: NSViewRepresentable {
    let register: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(register: register) }
    func updateNSView(_ view: WindowProbe, context: Context) {}
    final class WindowProbe: NSView {
        let register: @MainActor (NSWindow) -> Void
        init(register: @escaping @MainActor (NSWindow) -> Void) { self.register = register; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { if let window { register(window) } }
    }
}

/// Finite file/parser startup on its own actor, not the UI executor.
private actor AppResources {
    static let shared = AppResources()
    static func loadService(profile: SourceProfile) async throws -> ExplorerService { try await shared.load(profile: profile) }
    private func load(profile: SourceProfile) throws -> ExplorerService {
        try Task.checkCancellation()
        switch profile {
        case .offlineDemo: return ExplorerService(provider: try FixtureProvider.load(), limits: try ExplorerLimits())
        case .wikipediaEnglish: return ExplorerService(provider: WikipediaProvider(), limits: try ExplorerLimits())
        }
    }
}
