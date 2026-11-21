// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ExplorerPresentation

@main struct ResearchExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var lifetime = AppLifetime()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("Research Explorer", id: "explorer") {
            ExplorerRootView(lifetime: lifetime)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear { delegate.lifetime = lifetime }
        }
        .defaultSize(width: 1280, height: 860)
        .commands { ExplorerCommands(lifetime: lifetime) }
        Settings { ExplorerSettings() }
    }
}
