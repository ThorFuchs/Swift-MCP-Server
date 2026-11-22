// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import SwiftHTML
import ExplorerDomain

public struct RenderEvidence: Sendable {
    public let pageID, revisionID, htmlVersion, htmlSHA256: String
    public let nodes, maximumDepth: Int
}
/// DOMs are synchronous actor-local values (SwiftHTML documents and nodes are not Sendable).
/// Only checked Sendable projections leave this owner. Postparse limits bound traversal only;
/// they do not promise the parser's peak allocations or CPU preemption.
public actor MediaWikiNormalizer {
    public init() {}
    public func normalize(_ page: RESTPage, retrievedAt: Date, limits: ExplorerLimits) throws -> (Snapshot, RenderEvidence) {
        try Task.checkCancellation()
        guard page.id > 0, page.latest.id > 0, page.contentModel == "wikitext",
              page.title.utf8.count <= 512, page.key.utf8.count <= 1024,
              page.html.utf8.count <= 4_194_304, !page.html.isEmpty,
              page.license.title.utf8.count <= 512, page.license.url.utf8.count <= 1024 else { throw LiveFailure.malformed }
        let licenseURL = page.license.url.hasPrefix("//") ? "https:" + page.license.url : page.license.url
        guard let license = URLComponents(string: licenseURL), license.scheme == "https", license.host != nil,
              license.user == nil, license.password == nil else { throw LiveFailure.malformed }
        let doc = try HTMLDocument.parse(page.html)
        // Bounded, cancellable preorder walk of the whole parsed tree (document node at depth 0):
        // at most 100k nodes and depth 128, otherwise the page is denied.
        var nodes: [HTMLElement] = []
        let report: HTMLTraversalReport
        do {
            report = try doc.rootNode.walk(limits: try HTMLTraversalLimits(maximumNodes: 100_000, maximumDepth: 128)) { node, _ in
                if let e = node.element { nodes.append(e) }
            }
        } catch let failure as HTMLTraversalError {
            throw failure == .nodeLimit || failure == .depthLimit ? LiveFailure.bodyLimit : LiveFailure.unsupportedHTML
        }
        let count = report.visitedNodes, maximumDepth = report.maximumDepth
        // A missing attribute reads as "", exactly as the previous DOM backend's attr(_:) did.
        func attr(_ e: HTMLElement, _ name: String) throws -> String { try e.attribute(name) ?? "" }
        // Children of an already admitted (≤100k node) tree, in document order.
        func children(_ node: HTMLNode) throws -> [HTMLNode] {
            do { return try node.children(maximumCount: 100_000) } catch { throw LiveFailure.bodyLimit }
        }
        var version: String?
        for e in nodes where e.tagName == "meta" {
            let property = try attr(e, "property"), content = try attr(e, "content")
            if property == "mw:htmlVersion" || property == "mw:html:version" {
                guard version == nil || version == content else { throw LiveFailure.identity }; version = content
            }
            if property == "mw:pageId", content != String(page.id) { throw LiveFailure.identity }
            if property == "dc:modified", content != page.latest.timestamp { throw LiveFailure.identity }
        }
        guard version == "2.8.0", let body = doc.body,
              try attr(body, "data-mw-html-version") == version,
              let html = nodes.first(where: { $0.tagName == "html" }),
              try attr(html, "about") == "//en.wikipedia.org/wiki/Special:Redirect/revision/\(page.latest.id)" else { throw LiveFailure.unsupportedHTML }
        let omitted = Set(["script", "style", "noscript", "template", "table", "figure", "img", "audio", "video", "svg", "math", "link", "meta"])
        func tokens(_ e: HTMLElement, _ name: String) throws -> Set<String> { Set(try attr(e, name).split(whereSeparator: { $0.isWhitespace }).map(String.init)) }
        func ignored(_ e: HTMLElement) throws -> Bool {
            let classes = try tokens(e, "class")
            return omitted.contains(e.tagName) || !classes.isDisjoint(with: ["mw-cite-backlink", "mw-editsection", "shortdescription", "noprint", "navbox", "metadata"])
        }
        func plain(_ root: HTMLNode, maximum: Int) throws -> String {
            var stack: [HTMLNode] = [root], text = ""
            while let node = stack.popLast() {
                try Task.checkCancellation()
                if let e = node.element, try ignored(e) { continue }
                if let value = node.wholeText {
                    guard value.utf8.count <= maximum - text.utf8.count else { throw LiveFailure.bodyLimit }
                    text += value
                } else {
                    if let e = node.element, ["p", "li", "br", "div"].contains(e.tagName) {
                        guard text.utf8.count < maximum else { throw LiveFailure.bodyLimit }; text += "\n"
                    }
                    stack.append(contentsOf: try children(node).reversed())
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The source target is opaque metadata, never a part/component ID.
        var targets: [String: String] = [:], duplicates = Set<String>(), references: [ReferenceSeed] = []
        for e in nodes where e.tagName == "li" {
            let raw = try attr(e, "id")
            guard raw.hasPrefix("cite_note-") else { continue }
            var ancestor = e.parent, referenceList = false
            while let parent = ancestor {
                if try tokens(parent, "class").contains("references") { referenceList = true; break }
                ancestor = parent.parent
            }
            guard referenceList else { continue }
            guard raw.utf8.count <= 512, references.count < 4096 else { throw LiveFailure.bodyLimit }
            if targets[raw] != nil { duplicates.insert(raw); continue }
            let id = "r\(references.count)"; targets[raw] = id
            let label = try plain(e.node, maximum: 65_536)
            let clipped = try Normalizer.prefix(label, maximumBytes: 509)
            // Citation labels are explicitly bounded excerpts, not the source.
            let title = clipped.text + (clipped.truncated ? "…" : "")
            var url: String?
            var links: [HTMLNode] = [e.node]
            while let node = links.popLast() {
                if let a = node.element, a.tagName == "a" {
                    let href = try attr(a, "href"), value = href.hasPrefix("//") ? "https:" + href : href
                    if value.utf8.count <= 2048, let c = URLComponents(string: value), ["http", "https"].contains(c.scheme),
                       c.host != nil, c.user == nil, c.password == nil { url = value; break }
                }
                links.append(contentsOf: try children(node).reversed())
            }
            references.append(.init(id: id, title: title, url: url, synthetic: false))
        }
        let ambiguous = Set(duplicates.compactMap { targets[$0] })
        references.removeAll(where: { ambiguous.contains($0.id) })
        struct Part { let id: String; let parent: String?; let depth: Int; var heading: String?; var text = ""; var citations: [String] = [] }
        var parts: [Part] = [], unknown: [String: String] = [:], textBytes = 0, associations = 0
        // A synthetic container is used only if the supported DOM has no lead
        // section. Every actual section, including pseudo/negative IDs, receives
        // a stable ordinal within this revision and normalizer version.
        var stack: [(HTMLNode, Int?)] = [(body.node, nil)]
        while let (node, inherited) = stack.popLast() {
            try Task.checkCancellation(); var current = inherited
            if let e = node.element {
                if try ignored(e) { continue }
                let cls = try tokens(e, "class"), types = try tokens(e, "typeof")
                if !cls.isDisjoint(with: ["references", "reflist", "mw-references-wrap"]) || types.contains("mw:Extension/references") { continue }
                if e.tagName == "section", try e.attribute("data-mw-section-id") != nil {
                    let depth = inherited.map { parts[$0].depth + 1 } ?? 1
                    guard parts.count < limits.parts, depth <= limits.depth else { throw LiveFailure.bodyLimit }
                    current = parts.count; parts.append(Part(id: "p\(parts.count)", parent: inherited.map { parts[$0].id }, depth: depth))
                }
                if let i = current {
                    if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(e.tagName) {
                        let heading = try plain(node, maximum: 512)
                        if parts[i].heading == nil { parts[i].heading = heading }; continue
                    }
                    if cls.contains("mw-ref") || types.contains("mw:Extension/ref") {
                        var markers: [HTMLNode] = [node]
                        while let marker = markers.popLast() {
                            if let a = marker.element, a.tagName == "a", let fragment = (try attr(a, "href")).split(separator: "#", maxSplits: 1).last,
                               (try attr(a, "href")).contains("#") {
                                let raw = String(fragment).removingPercentEncoding ?? String(fragment)
                                guard raw.utf8.count <= 512 else { throw LiveFailure.bodyLimit }
                                let href = try attr(a, "href"), base = String(href.prefix(while: { $0 != "#" }))
                                let expectedKey = page.key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
                                let source = URL(string: "https://en.wikipedia.org/wiki/" + expectedKey)!
                                let resolvedBase = base.isEmpty ? source : URL(string: base, relativeTo: source)?.absoluteURL
                                let local = resolvedBase.map { $0.scheme == "https" && $0.host == "en.wikipedia.org" && $0.user == nil && $0.password == nil && $0.port == nil && $0.path == source.path && $0.query == nil } ?? false
                                let resolved = !local || duplicates.contains(raw) ? nil : targets[raw]
                                let id: String
                                if let resolved { id = resolved }
                                else { if unknown[raw] == nil { unknown[raw] = "u\(unknown.count)" }; id = unknown[raw]! }
                                if !parts[i].citations.contains(id) {
                                    guard parts[i].citations.count < 64, associations < 8192 else { throw LiveFailure.bodyLimit }
                                    parts[i].citations.append(id); associations += 1
                                }
                            }
                            markers.append(contentsOf: try children(marker).reversed())
                        }
                        continue
                    }
                    if ["p", "li", "br", "div", "dl"].contains(e.tagName) {
                        guard textBytes < 4_194_304 else { throw LiveFailure.bodyLimit }; parts[i].text += "\n"; textBytes += 1
                    }
                }
            }
            if let text = node.wholeText, let i = current {
                guard text.utf8.count <= 4_194_304 - textBytes else { throw LiveFailure.bodyLimit }
                parts[i].text += text; textBytes += text.utf8.count
            }
            for child in try children(node).reversed() { stack.append((child, current)) }
        }
        guard !parts.isEmpty else { throw LiveFailure.unsupportedHTML }
        let identity = SnapshotID(provider: "mediawiki-rest", project: "enwiki", pageID: String(page.id), revisionID: String(page.latest.id), normalizerVersion: "mediawiki-html-1")
        let provenance = Provenance(identity: identity, title: page.title,
            sourceURL: "https://en.wikipedia.org/w/index.php?curid=\(page.id)&oldid=\(page.latest.id)",
            retrievedAt: ISO8601DateFormatter().string(from: retrievedAt), modifiedAt: page.latest.timestamp,
            language: "en", license: page.license.title + " · " + licenseURL, synthetic: false)
        let snapshot = Snapshot(provenance: provenance,
            parts: parts.map { .init(id: $0.id, parentID: $0.parent, depth: $0.depth, heading: $0.heading,
                                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), citations: $0.citations) },
            references: targets.isEmpty && associations > 0 ? nil : references, tables: nil, tableCount: 0, contentBytes: 0)
        return (try LiveSnapshotAdmission.validate(snapshot, limits: limits),
                .init(pageID: identity.pageID, revisionID: identity.revisionID, htmlVersion: version!, htmlSHA256: SHA256.hash(data: Data(page.html.utf8)).map { String(format: "%02x", $0) }.joined(), nodes: count, maximumDepth: maximumDepth))
    }
}
