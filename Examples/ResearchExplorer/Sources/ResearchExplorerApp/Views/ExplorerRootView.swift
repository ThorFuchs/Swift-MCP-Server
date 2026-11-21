// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct ExplorerRootView: View {
    @Bindable var lifetime: AppLifetime
    var body: some View {
        NavigationSplitView {
            List(Workspace.allCases, selection: Binding<Workspace?>(get: { lifetime.destination }, set: { if let value = $0 { lifetime.destination = value } })) { workspace in
                Label(workspace.rawValue, systemImage: workspace.symbol).tag(workspace)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 290)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Label("Server " + (lifetime.server?.phase.rawValue.lowercased() ?? "unavailable"), systemImage: "circle").font(.callout).foregroundStyle(.secondary).padding()
            }
        } detail: {
            Group {
                switch lifetime.destination {
                case .research:
                    if let research = lifetime.research { ResearchView(model: research, focusID: lifetime.searchFocus).disabled(lifetime.isQuitting || lifetime.termination.unsettled) }
                    else { ContentUnavailableView(lifetime.startupProblem == nil ? "Preparing source" : "Source unavailable", systemImage: lifetime.startupProblem == nil ? "book.closed" : "exclamationmark.triangle", description: Text(lifetime.startupProblem ?? "Preparing the selected bounded provider. No listener or network request is started.")) }
                case .server: ServerView(lifetime: lifetime).disabled(lifetime.isQuitting || lifetime.termination.unsettled)
                case .activity: ActivityView(lifetime: lifetime, focusID: lifetime.searchFocus)
                }
            }.navigationTitle(lifetime.destination.rawValue)
        }
        .task { lifetime.prepare() }
        .background(WindowReference { lifetime.mainWindow = $0 }.frame(width: 0, height: 0))
    }
}
