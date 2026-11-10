// SPDX-License-Identifier: Apache-2.0
import SwiftUI
struct ExplorerSettings: View {
    @AppStorage("readerSize") private var readerSize = 17.0
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Slider(value: $readerSize, in: 14...26, step: 1) { Text("Article text size") }
            Text("\(Int(readerSize)) points").font(.callout).foregroundStyle(.secondary)
            LabeledContent("Source", value: "Choose in Server while stopped")
            Text("Live Wikipedia requires a separately qualified provider. The server never starts automatically.").font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 420)
    }
}
