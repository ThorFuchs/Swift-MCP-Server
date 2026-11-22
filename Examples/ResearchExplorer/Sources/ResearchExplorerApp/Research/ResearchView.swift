// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ExplorerDomain
import ExplorerPresentation

struct ResearchView: View {
    @Bindable var model: ResearchController
    let focusID: UUID
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                VStack(alignment: .leading, spacing: 6) {
                    Label(problem.message, systemImage: "exclamationmark.triangle").font(.headline)
                    Text(problem.recovery).foregroundStyle(.secondary)
                    if model.outline != nil { Button("Obtain a new outline") { model.refreshOutline() } }
                    else if !model.query.isEmpty { Button("Try again") { model.search() } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary)
            }
            if let outline = model.outline { ArticleReaderView(model: model, outline: outline) }
            else if model.candidate != nil && model.isBusy { ProgressView("Opening exact revision…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let page = model.page, model.phase != .empty {
                List(page.candidates, id: \.id) { candidate in
                    Button { model.open(candidate) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.title).font(.headline)
                            if let description = candidate.description { Text(description).foregroundStyle(.secondary) }
                            SourceBadge(source: model.source)
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Open \(candidate.title)")
                }
                if page.truncated { Text(model.source == .offlineDemo ? "More candidates exist. Refine the query." : "Showing up to 10 results. Refine your query; total matches are unknown.").font(.callout).padding(8) }
            } else if model.phase == .empty || model.phase == .cancelled {
                ContentUnavailableView {
                    Label(model.phase == .empty ? "No matching articles" : "Search cancelled", systemImage: "book.closed")
                } description: {
                    Text(model.phase == .empty ? "Nothing in this source matched. No other source was searched instead." : "The search was stopped. No partial result is shown.")
                } actions: {
                    if model.source == .offlineDemo {
                        Button("Show all Riverglass articles") { model.query = OfflineTour.query; model.search() }
                    }
                }
            } else if model.source == .offlineDemo {
                ContentUnavailableView {
                    Label("Explore the Riverglass collection", systemImage: "books.vertical")
                } description: {
                    Text("Five fictional articles about an observatory that never existed, written as teaching data. Everything stays on this Mac: no network request is made and no server is started.\n\nOr search for observatory, expedition, telescope or catalogue.")
                } actions: {
                    Button("Explore the offline collection", systemImage: "sparkle.magnifyingglass") { model.exploreOfflineCollection() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                ContentUnavailableView("A place to follow your curiosity", systemImage: "book.closed", description: Text("Search English Wikipedia explicitly. Opening an article selects one fetched revision; sections and references use that snapshot. For a no-network tour, choose Offline demo in Server."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { model.back() } label: { Label("Back to results", systemImage: "chevron.left") }.disabled(model.candidate == nil).keyboardShortcut("[", modifiers: .command) }
            ToolbarItem(placement: .principal) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.source == .offlineDemo ? "Search offline articles" : "Search English Wikipedia", text: $model.query).textFieldStyle(.plain).frame(minWidth: 200, idealWidth: 330).focused($searchFocused).onSubmit { model.search() }.accessibilityLabel("Search articles")
                    if model.isBusy { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 6)
            }
            ToolbarItem {
                if model.isBusy { Button("Cancel", systemImage: "xmark") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Search", systemImage: "arrow.right") { model.search() }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        .onChange(of: focusID) { searchFocused = true }
    }
}

/// Every result and article names its source, so fictional data is never mistaken for Wikipedia.
struct SourceBadge: View {
    let source: ResearchSource
    var body: some View {
        Label(source == .offlineDemo ? "Fictional · Offline demo" : "Wikipedia English",
              systemImage: source == .offlineDemo ? "externaldrive" : "globe")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel(source == .offlineDemo ? "Source: fictional offline demo" : "Source: Wikipedia English")
    }
}
