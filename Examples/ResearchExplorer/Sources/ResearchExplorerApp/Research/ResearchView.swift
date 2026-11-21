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
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Open \(candidate.title)")
                }
                if page.truncated { Text(model.source == .offlineDemo ? "More candidates exist. Refine the query." : "Showing up to 10 results. Refine your query; total matches are unknown.").font(.callout).padding(8) }
            } else {
                ContentUnavailableView(model.phase == .empty ? "No matching articles" : model.phase == .cancelled ? "Search cancelled" : "A place to follow your curiosity", systemImage: "book.closed", description: Text(model.source == .offlineDemo ? "Search the fictional Riverglass collection. No network request is made." : "Search English Wikipedia explicitly. Opening an article selects one fetched revision; sections and references use that snapshot."))
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
            ToolbarItem { Label(model.source.rawValue, systemImage: model.source == .offlineDemo ? "externaldrive" : "globe").foregroundStyle(.secondary).help("Source is selected in Server. Plain text; no images, active HTML or independent source verification.") }
            ToolbarItem {
                if model.isBusy { Button("Cancel", systemImage: "xmark") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Search", systemImage: "arrow.right") { model.search() }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        .onChange(of: focusID) { searchFocused = true }
    }
}
