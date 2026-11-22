// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit
import ExplorerPresentation
import ExplorerDomain

struct ServerView: View {
    @Bindable var lifetime: AppLifetime
    @State private var showConnection = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Server overview").font(.largeTitle.bold())
                Text("Research Explorer · MCP 2026-07-28 · \(lifetime.profile.rawValue)").foregroundStyle(.secondary)
                Picker("Research source", selection: Binding(get: { lifetime.profile }, set: { lifetime.selectSource($0) })) {
                    ForEach(SourceProfile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(!lifetime.canSwitchSource)
                Text("Source changes require a stopped, joined server and settled Research. No request is made at startup.").font(.caption).foregroundStyle(.secondary)
                if let server = lifetime.server {
                    GroupBox {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(server.phase.rawValue, systemImage: server.phase == .running ? "checkmark.circle.fill" : server.phase == .failed ? "exclamationmark.triangle" : "circle").font(.title2.bold())
                                Text(server.endpoint?.url ?? "HTTP · loopback only · starts explicitly").textSelection(.enabled).font(.callout.monospaced())
                                if let failure = server.failure {
                                    Text(failure == .catalogUnavailable
                                        ? "Catalog construction failed before listener readiness. Verify the selected SDK resource contract and product; see WRE-S01."
                                        : "\(failure.rawValue). \(server.cleanupDebt ? "Cleanup remains unresolved; Start is disabled." : "Review the listener and retry explicitly.")")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if server.canStart { Button("Start server", systemImage: "play.fill") { lifetime.startServer() }.buttonStyle(.borderedProminent) }
                            else { Button("Stop server", systemImage: "stop.fill") { lifetime.stopServer() }.disabled(!server.canStop) }
                            Button("Restart") { server.restart() }.disabled(server.phase != .running)
                            Button("Connection details", systemImage: "doc.on.doc") { showConnection = true }.disabled(server.endpoint == nil)
                        }.padding(12)
                    }
                    Text("Local development access. Host is checked; browser Origins and supplied Authorization are rejected. Not a public or protected-resource endpoint.").font(.callout).foregroundStyle(.secondary)
                    MCPJourneyView(lifetime: lifetime, journey: lifetime.journey, running: server.phase == .running)
                    summaries
                    RequestActivityChart(snapshot: lifetime.activitySnapshot)
                    GroupBox("Recent eligible tool calls") {
                        if lifetime.activitySnapshot.recentCalls.isEmpty {
                            ContentUnavailableView("No MCP calls observed", systemImage: "arrow.left.arrow.right", description: Text("An external client must call this app's HTTP host. Local Research does not enter these totals."))
                        } else {
                            Table(lifetime.activitySnapshot.recentCalls.reversed()) {
                                TableColumn("Tool", value: \.operation)
                                TableColumn("Duration") { row in Text(row.durationMilliseconds.map { "\($0) ms" } ?? "Unavailable").monospacedDigit() }
                                TableColumn("Outcome") { row in Text(row.outcome.rawValue) }
                            }.frame(minHeight: 180)
                        }
                        HStack { Spacer(); Button("View activity") { lifetime.destination = .activity } }.padding(8)
                    }
                    Text("Only this app's catalogue handler invocations are observed. Pre-handler transport/schema rejections and connection counts are unavailable. No protocol sessions are inferred.").font(.caption).foregroundStyle(.secondary)
                } else { ContentUnavailableView("Server unavailable", systemImage: "exclamationmark.triangle", description: Text(lifetime.startupProblem ?? "The selected SDK host could not be constructed.")) }
            }.padding(28)
        }
        .sheet(isPresented: $showConnection) { connectionDetails }
    }
    private var summaries: some View {
        let s = lifetime.activitySnapshot
        return HStack(spacing: 24) {
            metric("Active tool requests", s.metricsAvailable ? "\(s.active)" : "Unavailable", "arrow.up.right")
            metric("Completed calls", s.metricsAvailable ? "\(s.completed)" : "Unavailable", "checkmark.circle")
            metric("Failed calls", s.metricsAvailable ? "\(s.failed)" : "Unavailable", "exclamationmark.triangle")
            metric("Recent median", s.medianMilliseconds.map { "\($0) ms" } ?? "No samples", "clock")
        }.overlay(alignment: .bottomLeading) { if s.metricsPartial { Text("Partial observation").font(.caption).foregroundStyle(.secondary).offset(y: 16) } }
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Label(title, systemImage: icon).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connection details").font(.title2.bold())
            Text(lifetime.server?.endpoint?.url ?? "Listener not running").font(.body.monospaced()).textSelection(.enabled)
            Text("MCP 2026-07-28 POST endpoint. Anonymous loopback development only. No legacy initialize/ping, GET stream, session or replay support. HTTPS resource-server authorization is a different SDK configuration.").foregroundStyle(.secondary)
            Text("The app shares its \(lifetime.profile.rawValue) service with all four tool registrations. Handler-only activity is recorded; client compatibility requires actual requests.").font(.callout)
            HStack {
                Button("Copy endpoint", systemImage: "doc.on.doc") { if let text = lifetime.server?.endpoint?.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }.disabled(lifetime.server?.endpoint == nil)
                Spacer(); Button("Done") { showConnection = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520)
    }
}

/// "Explore MCP": a real public-SDK client (Client + HTTPClientTransport) calls this app's own
/// loopback server. Only metadata is shown in the timeline; the tool calls appear in Activity.
struct MCPJourneyView: View {
    @Bindable var lifetime: AppLifetime
    let journey: MCPJourneyController
    let running: Bool
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("A real MCP client in this app connects to the server above over loopback HTTP: server/discover, tools/list, then the four tools. Results are checked against each tool's outputSchema and the requested revision. Nothing is sent until you press Explore MCP.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if journey.isRunning {
                        Button("Cancel", systemImage: "xmark") { journey.cancel() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Explore MCP", systemImage: "arrow.left.arrow.right") { lifetime.exploreMCP() }
                            .disabled(!running).help(running ? "Runs one guided client journey." : "Start the server first; the journey never starts it.")
                    }
                    Spacer()
                    Text(journey.phase.rawValue).foregroundStyle(.secondary)
                }
                if !journey.steps.isEmpty {
                    Table(journey.steps) {
                        TableColumn("Method") { Text($0.method).font(.callout.monospaced()) }
                        TableColumn("Tool") { Text($0.tool ?? "—").font(.callout.monospaced()) }
                        TableColumn("Status") { step in Text(step.status.rawValue) }
                        TableColumn("Validated") { step in Text(step.validated ? "Schema + identity" : "No") }
                        TableColumn("Revision") { step in Text(step.revisionID ?? "—") }
                        TableColumn("Duration") { step in Text("\(step.milliseconds) ms").monospacedDigit() }
                    }.frame(minHeight: 170)
                    ForEach(journey.steps.compactMap(\.failure), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                if let outline = journey.outline {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(outline.provenance.title).font(.headline)
                        Text("Revision \(outline.snapshot.revisionID) · \(outline.snapshot.provider) · \(outline.provenance.synthetic ? "fictional" : "fetched snapshot")").font(.caption).foregroundStyle(.secondary)
                        if let passage = journey.passage { Text(passage.text).lineLimit(6).textSelection(.enabled) }
                        if let refs = journey.references { Text("\(refs.references.count) references, \(refs.unresolvedIDs.count) unresolved · not independently verified").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Guided MCP journey", systemImage: "point.3.connected.trianglepath.dotted") }
    }
}
