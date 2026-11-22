// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit
import ExplorerPresentation

struct ActivityView: View {
    @Bindable var lifetime: AppLifetime
    let focusID: UUID
    @State private var filterText = ""
    @State private var severity: EventSeverity?
    @State private var origin: EventOrigin?
    @State private var component: String?
    @State private var selectedID: UUID?
    @State private var followTail = true
    @State private var sortOrder = [KeyPathComparator(\ActivityEvent.date)]
    @FocusState private var searchFocused: Bool
    private var filter: ActivityFilter { .init(search: filterText, severity: severity, origin: origin, component: component) }
    private var rows: [ActivityEvent] { lifetime.activitySnapshot.events.filter(filter.includes).sorted(using: sortOrder) }
    private var selected: ActivityEvent? { lifetime.activitySnapshot.events.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Activity log").font(.largeTitle.bold())
            Text("Local research (direct, not MCP), MCP tool-handler calls from any client (external, curl recipe or Explore MCP) and app-owned server lifecycle. Bounded, redacted projections: no arguments, results, headers or credentials.").foregroundStyle(.secondary)
            HStack {
                Picker("Level", selection: $severity) {
                    Text("All levels").tag(EventSeverity?.none)
                    ForEach(EventSeverity.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(maxWidth: 180)
                Picker("Component", selection: $component) {
                    Text("All components").tag(String?.none)
                    ForEach(["Research", "MCP", "Server"], id: \.self) { Text($0).tag(Optional($0)) }
                }.frame(maxWidth: 190)
                Picker("Origin", selection: $origin) {
                    Text("All origins").tag(EventOrigin?.none)
                    ForEach(EventOrigin.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(maxWidth: 190)
                Spacer()
                Toggle("Follow tail", isOn: $followTail).help("Display only. Collection and the server continue unchanged.")
            }
            if lifetime.activitySnapshot.events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "waveform.path", description: Text("Search an offline article or explicitly start this app's server."))
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: filterText)
            } else {
                ScrollViewReader { proxy in
                    Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                        TableColumn("Time", value: \.date) { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(min: 90, ideal: 110)
                        TableColumn("Level") { Label($0.severity.rawValue, systemImage: $0.severity == .error ? "exclamationmark.triangle" : $0.severity == .warning ? "exclamationmark.circle" : "info.circle") }.width(min: 85, ideal: 100)
                        TableColumn("Component", value: \.component).width(min: 85, ideal: 100)
                        TableColumn("Event", value: \.summary)
                    }
                    .onChange(of: rows.last?.id) { if followTail, let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }.frame(minHeight: 200)
            }
            Divider()
            if let selected { EventDetailsView(event: selected) }
            else if selectedID != nil { Text("The selected event has left retained history.").foregroundStyle(.secondary) }
            else { Text("Select an event to inspect its redacted details.").foregroundStyle(.secondary) }
            HStack {
                Text("\(lifetime.activitySnapshot.events.count) events retained · \(lifetime.activitySnapshot.discarded) discarded").monospacedDigit()
                Spacer(); Text("Bounded projected metadata only")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(28)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Search activity", text: $filterText).frame(minWidth: 200, idealWidth: 320).focused($searchFocused).accessibilityLabel("Search retained activity")
            }
            ToolbarItem { Button("Copy event", systemImage: "doc.on.doc") { if let selected { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.detail, forType: .string) } }.disabled(selected == nil) }
            ToolbarItem { Button("Export…", systemImage: "square.and.arrow.up") { lifetime.export(filter: filter) }.disabled(lifetime.exporting) }
        }
        .onChange(of: focusID) { searchFocused = true }
        .onChange(of: filterText) { if filterText.count > 256 { filterText = String(filterText.prefix(256)) } }
        .alert("Export not completed", isPresented: Binding(get: { lifetime.exportProblem != nil }, set: { if !$0 { lifetime.exportProblem = nil } })) { Button("OK", role: .cancel) {} } message: { Text(lifetime.exportProblem ?? "") }
    }
}
struct EventDetailsView: View {
    let event: ActivityEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Event details").font(.title2.bold())
            Text(event.detail).font(.callout.monospaced()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
