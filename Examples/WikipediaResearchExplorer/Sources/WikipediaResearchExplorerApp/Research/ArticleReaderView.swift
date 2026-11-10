// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ExplorerDomain
import ExplorerPresentation

struct ArticleReaderView: View {
    @Bindable var model: ResearchController
    let outline: Outline
    @AppStorage("readerSize") private var readerSize = 17.0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(outline.provenance.title).font(.largeTitle).fontWeight(.bold).textSelection(.enabled)
                    Label(outline.provenance.synthetic ? "Offline demo · Fictional article" : "Wikipedia English · Fetched snapshot · Plain text", systemImage: outline.provenance.synthetic ? "externaldrive" : "globe").font(.callout).foregroundStyle(.secondary)
                    Menu {
                        ForEach(outline.sections, id: \.location) { part in
                            Button(part.heading ?? "Introduction") { model.read(part.location) }
                        }
                    } label: { Label(model.selectedPart.flatMap { chosen in outline.sections.first { $0.location == chosen }?.heading } ?? "Contents: choose a section", systemImage: "list.bullet") }
                    if outline.truncated { Label(outline.introductionTruncated ? "Introduction shortened to its bounded excerpt" : "Outline omits additional sections", systemImage: "text.badge.minus").font(.callout) }
                }
                if let passage = model.passage {
                    Text(passage.textAvailable ? passage.text.isEmpty ? "This section contains no supplied text." : passage.text : "Text was not supplied for this section.")
                        .font(.system(size: min(26, max(14, readerSize)))).textSelection(.enabled).lineSpacing(5)
                    if passage.truncated { Label("Section shortened to the text budget", systemImage: "text.badge.minus").foregroundStyle(.secondary) }
                } else {
                    Text(outline.introduction ?? "No introduction was supplied.").font(.system(size: min(26, max(14, readerSize)))).lineSpacing(5).textSelection(.enabled)
                    if model.isBusy { ProgressView("Reading section and associated references…") }
                    else { Text("Choose a section from Contents to read its text and citation associations.").foregroundStyle(.secondary) }
                }
                Divider()
                ReferencesView(citations: model.citations, problem: model.referenceProblem, loading: model.phase == .references)
                Divider()
                DisclosureGroup("Provenance and attribution") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(outline.snapshot.provider) / \(outline.snapshot.project) / \(outline.snapshot.pageID)")
                        Text("Revision \(outline.snapshot.revisionID) · \(outline.snapshot.normalizerVersion)")
                        Text("Retrieved \(outline.provenance.retrievedAt)")
                        Text(outline.provenance.license)
                        if outline.provenance.synthetic { Text("Synthetic fixture; no Wikimedia content or live endpoint is represented.") }
                        else {
                            Text("Plain-text projection. Tables, media and mathematical rendering omitted. Citation labels may be shortened; sources are not independently verified.")
                            if let url = URL(string: outline.provenance.sourceURL) { Link("Open exact revision on Wikipedia", destination: url) }
                            if let history = URL(string: "https://en.wikipedia.org/w/index.php?curid=\(outline.snapshot.pageID)&action=history") { Link("Contributor history and attribution", destination: history) }
                        }
                    }.font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(32).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}
struct ReferencesView: View {
    let citations: SectionReferences?
    let problem: ExplorerProblem?
    let loading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("References").font(.title2.bold()); Spacer(); Label("Not independently verified", systemImage: "exclamationmark.shield").font(.callout).foregroundStyle(.secondary) }
            if loading { ProgressView("Loading associated references…") }
            else if let problem { Text(problem.message + " " + problem.recovery).foregroundStyle(.secondary) }
            else if let citations {
                if citations.references.isEmpty { Text("No resolved references for this section.").foregroundStyle(.secondary) }
                ForEach(citations.references, id: \.id) { reference in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(reference.title, systemImage: "doc.text").textSelection(.enabled)
                        Text(reference.synthetic ? "Fictional citation · link inactive" : "Reference metadata; source not independently verified").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if !citations.unresolvedIDs.isEmpty { Text("\(citations.unresolvedIDs.count) unresolved citation identifiers").foregroundStyle(.secondary) }
                if citations.truncated { Text("Reference projection shortened to its limit.") }
            } else { Text("Read a section to inspect its associated references.").foregroundStyle(.secondary) }
        }
    }
}
