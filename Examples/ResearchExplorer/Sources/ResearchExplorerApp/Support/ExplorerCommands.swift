// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit

struct ExplorerCommands: Commands {
    let lifetime: AppLifetime
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Workspace") {
            Button("Research", systemImage: "magnifyingglass") { lifetime.destination = .research }.keyboardShortcut("1")
            Button("Server", systemImage: "server.rack") { lifetime.destination = .server }.keyboardShortcut("2")
            Button("Activity", systemImage: "waveform.path") { lifetime.destination = .activity }.keyboardShortcut("3")
            Divider()
            Button("Find") { lifetime.searchFocus = UUID() }.keyboardShortcut("f").disabled(lifetime.destination == .server)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Explorer") {
                if let window = lifetime.mainWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                else { openWindow(id: "explorer") }
            }
        }
    }
}
