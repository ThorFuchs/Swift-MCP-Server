// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ExplorerDomain
import ExplorerPresentation

/// The research workspace for an open article: outline · reading · evidence, as columns of one
/// view (no nested split views; workspace navigation stays in the sidebar). The layout depends
/// only on the width of this whole area, so showing or hiding a column never feeds back into it:
/// ≥ 1100 pt shows all three; ≥ 760 pt keeps the outline and moves evidence to a toolbar popover;
/// narrower windows also move the outline into a toolbar menu.
struct ArticleReaderView: View {
    @Bindable var model: ResearchController
    let outline: Outline
    @State private var width: CGFloat = 1200
    @State private var evidenceColumn = true
    @State private var evidencePopover = false
    static let outlineColumnBreakpoint: CGFloat = 760
    static let evidenceColumnBreakpoint: CGFloat = 1100
    var body: some View {
        let presentation = model.presentation
        let showOutline = width >= Self.outlineColumnBreakpoint
        let roomForEvidence = width >= Self.evidenceColumnBreakpoint
        HStack(spacing: 0) {
            if showOutline {
                OutlinePane(model: model, outline: outline, rows: presentation.outline).frame(width: 230)
                Divider()
            }
            VStack(spacing: 0) {
                if !showOutline {
                    compactBar(presentation, roomForEvidence: roomForEvidence)
                    Divider()
                }
                ReadingPane(model: model, outline: outline, presentation: presentation)
            }.frame(maxWidth: .infinity)
            if roomForEvidence && evidenceColumn {
                Divider()
                EvidencePane(model: model, presentation: presentation).frame(width: 320)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .popover(isPresented: $evidencePopover, arrowEdge: .top) {
            EvidencePane(model: model, presentation: model.presentation).frame(width: 340, height: 560)
        }
        .toolbar {
            ToolbarItemGroup {
                if !showOutline {
                    Menu {
                        ForEach(presentation.outline) { row in
                            Button(String(repeating: "   ", count: row.indent) + row.title) { model.read(row.location) }
                        }
                    } label: { Label("Contents", systemImage: "list.bullet.indent") }
                    .help("Sections of revision \(outline.snapshot.revisionID)")
                }
                Button { model.readAdjacent(-1) } label: { Label("Previous section", systemImage: "chevron.up") }
                    .disabled(!presentation.canReadPrevious).keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button { model.readAdjacent(1) } label: { Label("Next section", systemImage: "chevron.down") }
                    .disabled(!presentation.canReadNext).keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button {
                    if roomForEvidence { evidenceColumn.toggle() } else { evidencePopover.toggle() }
                } label: { Label("Evidence", systemImage: "sidebar.trailing") }
                .help("References and provenance of the selected section").keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
    /// Compact windows keep every reader control visible inline, never only in toolbar overflow.
    private func compactBar(_ presentation: ReaderPresentation, roomForEvidence: Bool) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(presentation.outline) { row in
                    Button(String(repeating: "   ", count: row.indent) + row.title) { model.read(row.location) }
                }
            } label: { Label(presentation.outline.first(where: \.isSelected)?.title ?? "Contents", systemImage: "list.bullet.indent") }
            .fixedSize()
            Spacer(minLength: 0)
            Button { model.readAdjacent(-1) } label: { Label("Previous section", systemImage: "chevron.up") }
                .labelStyle(.iconOnly).disabled(!presentation.canReadPrevious)
            Button { model.readAdjacent(1) } label: { Label("Next section", systemImage: "chevron.down") }
                .labelStyle(.iconOnly).disabled(!presentation.canReadNext)
            Button { evidencePopover = true } label: { Label("Evidence", systemImage: "sidebar.trailing") }
        }
        .buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Section hierarchy of the pinned revision. Arrow keys move the selection; selecting reads.
struct OutlinePane: View {
    @Bindable var model: ResearchController
    let outline: Outline
    let rows: [OutlineRow]
    var body: some View {
        List(selection: Binding<String?>(
            get: { model.selectedPart?.partID },
            set: { id in if let row = rows.first(where: { $0.id == id }), row.location != model.selectedPart { model.read(row.location) } })) {
            Section {
                ForEach(rows) { row in
                    Text(row.title)
                        .padding(.leading, CGFloat(row.indent) * 14)
                        .lineLimit(2)
                        .tag(row.id)
                        .accessibilityLabel(row.accessibilityLabel)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outline.provenance.title).font(.headline).lineLimit(2)
                    Text("Revision \(outline.snapshot.revisionID) · \(rows.count) sections").font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 4)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Article contents")
    }
}

/// The text column: identity, state and the selected section of the pinned revision.
struct ReadingPane: View {
    @Bindable var model: ResearchController
    let outline: Outline
    let presentation: ReaderPresentation
    @AppStorage("readerSize") private var readerSize = 17.0
    private var bodyFont: Font { .system(size: min(26, max(13, readerSize)), design: .serif) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(outline.provenance.title).font(.largeTitle.bold()).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { badges }
                        VStack(alignment: .leading, spacing: 4) { badges }
                    }.font(.callout).foregroundStyle(.secondary)
                }
                status
                if let passage = model.passage, let part = model.selectedPart {
                    let heading = presentation.outline.first { $0.location == part }?.title
                    if let heading { Text(heading).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader) }
                    Text(passage.textAvailable ? (passage.text.isEmpty ? "This section contains no supplied text." : passage.text) : "Text was not supplied for this section.")
                        .font(bodyFont).lineSpacing(6).textSelection(.enabled)
                        .foregroundStyle(passage.textAvailable && !passage.text.isEmpty ? .primary : .secondary)
                    if passage.truncated {
                        Label("Shortened to the \(32768 / 1024) KiB section budget; the rest of this section is not shown.", systemImage: "text.badge.minus")
                            .font(.callout).foregroundStyle(.orange)
                    }
                } else {
                    Text(outline.introduction ?? "No introduction was supplied.").font(bodyFont).lineSpacing(6).textSelection(.enabled)
                    if outline.introductionTruncated { Label("Introduction shortened to its excerpt.", systemImage: "text.badge.minus").font(.callout).foregroundStyle(.orange) }
                    if !model.isBusy { Text("Choose a section in Contents to read it with its references.").foregroundStyle(.secondary) }
                }
                RevisionPanel(model: model, outline: outline)
            }
            .frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private var badges: some View {
        SourceBadge(source: model.source)
        Label("Revision \(outline.snapshot.revisionID) · pinned", systemImage: "pin")
        if let modified = outline.provenance.modifiedAt { Label("Edited \(modified)", systemImage: "clock") }
    }
    @ViewBuilder private var status: some View {
        switch presentation.status {
        case .readingSection: ProgressView("Reading section…").controlSize(.small)
        case .loadingReferences: ProgressView("Loading references…").controlSize(.small)
        case .comparing: ProgressView("Checking for a newer revision…").controlSize(.small)
        case .cancelled: Label("Stopped. The pinned revision is unchanged; choose a section to continue.", systemImage: "stop.circle").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

/// References for the selected section and the exact provenance of the pinned revision.
struct EvidencePane: View {
    @Bindable var model: ResearchController
    let presentation: ReaderPresentation
    var body: some View {
        Form {
            Section {
                references
            } header: {
                Text("References")
            } footer: {
                Label("Citation metadata is not independently verified.", systemImage: "exclamationmark.shield").font(.caption)
            }
            Section("Provenance") {
                ForEach(presentation.provenance) { line in
                    LabeledContent(line.label) { Text(line.value).textSelection(.enabled).multilineTextAlignment(.trailing) }
                }
                if let permalink = presentation.permalink {
                    Link("Open this revision on Wikipedia", destination: permalink)
                    if let history = URL(string: "https://en.wikipedia.org/w/index.php?curid=\(model.outline?.snapshot.pageID ?? "")&action=history") {
                        Link("Contributors and attribution", destination: history)
                    }
                } else if model.outline?.provenance.synthetic == true {
                    Text("Fictional data; its fixture:// links are inactive by design.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
    @ViewBuilder private var references: some View {
        switch presentation.evidence {
        case .noSection: Text("Choose a section to see what it cites.").foregroundStyle(.secondary)
        case .loading: ProgressView("Loading references…").controlSize(.small)
        case .metadataMissing:
            Label("This source supplied no reference metadata. That is not the same as an empty list.", systemImage: "questionmark.folder")
        case .unavailable(let code):
            Label(model.referenceProblem?.message ?? "References are unavailable (\(code.rawValue)).", systemImage: "exclamationmark.triangle")
        case .uncited: Text("This section cites no references.").foregroundStyle(.secondary)
        case .cited(_, let unresolved, let truncated):
            ForEach(model.citations?.references ?? [], id: \.id) { reference in
                VStack(alignment: .leading, spacing: 3) {
                    Text(reference.title).textSelection(.enabled)
                    Text(reference.synthetic ? "Fictional citation · link inactive" : (reference.url ?? "No link supplied")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.accessibilityElement(children: .combine)
            }
            if !unresolved.isEmpty {
                Label("Cited without metadata: \(unresolved.joined(separator: ", "))", systemImage: "questionmark.circle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if truncated { Label("Reference list shortened to its limit.", systemImage: "text.badge.minus").foregroundStyle(.orange) }
        }
    }
}

/// Explicit revision handling: the pinned snapshot is what the reader shows until the user
/// chooses otherwise. Checking for, comparing and switching to a newer revision are separate steps.
struct RevisionPanel: View {
    @Bindable var model: ResearchController
    let outline: Outline
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sections and references come from revision \(outline.snapshot.revisionID) until you choose otherwise. An expired revision is reported, never silently replaced.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check for a newer revision", systemImage: "arrow.triangle.2.circlepath") { model.compareWithLatestRevision() }
                        .disabled(model.isBusy)
                    if let edit = model.offlineEdit, !model.offlineEditPublished {
                        Button("Simulate an upstream edit", systemImage: "square.and.pencil") { model.publishOfflineEdit() }
                            .disabled(model.isBusy).help(edit.summary + " Offline demo only; your open revision stays pinned.")
                    }
                    if model.phase == .comparing { ProgressView().controlSize(.small) }
                }
                if model.offlineEditPublished, model.comparison == nil {
                    Text("An upstream edit was published in the offline collection. This reader still shows revision \(outline.snapshot.revisionID).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let comparison = model.comparison { result(comparison) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label("Revision", systemImage: "clock.arrow.circlepath") }
    }
    @ViewBuilder private func result(_ comparison: RevisionComparison) -> some View {
        let latest = comparison.latest.snapshot.revisionID, pinned = comparison.pinned.revisionID
        if comparison.latestIsPinned {
            Label("Revision \(pinned) is still the latest revision.", systemImage: "checkmark.circle")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Revision \(latest) is available\(comparison.latest.provenance.modifiedAt.map { " (edited \($0))" } ?? ""). You are still reading \(pinned).", systemImage: "exclamationmark.arrow.circlepath")
                switch comparison.passage {
                case .notCompared: Text("Choose a section, then check again to compare its text.").foregroundStyle(.secondary)
                case .unchanged: Text("The selected section is identical in \(latest).").foregroundStyle(.secondary)
                case .absentInLatest: Text("The selected section does not exist in \(latest).").foregroundStyle(.secondary)
                case .changed(let old, let new):
                    HStack(alignment: .top, spacing: 16) {
                        passage("Pinned \(pinned)", old)
                        passage("Latest \(latest)", new)
                    }
                }
                Button("Switch reader to \(latest)", systemImage: "arrow.right.circle") { model.adoptLatestRevision() }.disabled(model.isBusy)
            }
        }
    }
    private func passage(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .topLeading).accessibilityElement(children: .combine)
    }
}
