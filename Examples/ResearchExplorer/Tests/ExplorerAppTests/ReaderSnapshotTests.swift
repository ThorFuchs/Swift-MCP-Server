// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import AppKit
import SwiftUI
import QuartzCore
import ExplorerDomain
import WikimediaAccess
import ExplorerPresentation
@testable import ResearchExplorerApp

/// RE-03 (#35) review screenshots. Opt-in: set RE_SNAPSHOT_DIR to a writable directory.
/// The app's real root view is hosted in an on-screen window of this process and its layer tree is
/// rendered to PNG; this needs no screen-recording permission. Window-server backdrop materials
/// (the sidebar's vibrancy) are not part of the layer tree and render blank; everything the app
/// draws itself is captured. These images are for human inspection, not pixel assertions.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RE_SNAPSHOT_DIR"] != nil, "Set RE_SNAPSHOT_DIR to render review screenshots"))
@MainActor struct ReaderSnapshotTests {
    private enum Content { case app(tour: Bool, query: String?), evidence(query: String, section: Int) }
    private struct Shot { let name: String; let size: CGSize; let dark: Bool; let readerSize: Double; let content: Content }

    private func render(_ shot: Shot, into directory: URL) async throws {
        UserDefaults.standard.set(shot.readerSize, forKey: "readerSize")
        let provider = try FixtureProvider.load()
        let service = ExplorerService(provider: provider, limits: try ExplorerLimits())
        let app = AppLifetime(profile: .offlineDemo, loadSource: { _ in PreparedSource(service: service, offlineEdit: .prepared(provider)) })
        app.prepare(); await app.waitUntilPrepared()
        let research = try #require(app.research)
        let root: AnyView
        switch shot.content {
        case .app(let tour, let query):
            if tour { research.exploreOfflineCollection(); await research.waitUntilIdle() }
            if let query { research.query = query; research.search(); await research.waitUntilIdle() }
            root = AnyView(ExplorerRootView(lifetime: app))
        case .evidence(let query, let section):
            research.query = query; research.search(); await research.waitUntilIdle()
            research.open(try #require(research.page?.candidates.first)); await research.waitUntilIdle()
            for _ in 0...section { research.readAdjacent(1); await research.waitUntilIdle() }
            // The inspector column itself is window-server material; host its content directly.
            root = AnyView(EvidencePane(model: research, presentation: research.presentation))
        }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        window.title = "Research Explorer"
        window.contentView = hosting
        hosting.wantsLayer = true
        window.orderFrontRegardless()
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
        }
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let scale = window.backingScaleFactor, bounds = view.bounds
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.cgContext.setFillColor((shot.dark ? NSColor.black : NSColor.white).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
        context.cgContext.scaleBy(x: scale, y: scale)
        try #require(view.layer).render(in: context.cgContext)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "\(shot.name).png"))
        window.orderOut(nil); window.contentView = nil
        #expect(await app.quit(waitMilliseconds: 5000))
    }

    @Test func renderReviewScreenshots() async throws {
        let directory = URL(filePath: try #require(ProcessInfo.processInfo.environment["RE_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shots = [
            Shot(name: "01-first-run-light", size: .init(width: 1280, height: 800), dark: false, readerSize: 17, content: .app(tour: false, query: nil)),
            Shot(name: "02-reader-wide-light", size: .init(width: 1440, height: 900), dark: false, readerSize: 17, content: .app(tour: true, query: nil)),
            Shot(name: "03-reader-wide-dark", size: .init(width: 1440, height: 900), dark: true, readerSize: 17, content: .app(tour: true, query: nil)),
            Shot(name: "04-reader-compact-light", size: .init(width: 900, height: 640), dark: false, readerSize: 17, content: .app(tour: true, query: nil)),
            Shot(name: "05-reader-large-article-text-dark", size: .init(width: 1440, height: 900), dark: true, readerSize: 24, content: .app(tour: true, query: nil)),
            Shot(name: "06-search-results-light", size: .init(width: 1280, height: 800), dark: false, readerSize: 17, content: .app(tour: false, query: "Riverglass")),
            Shot(name: "07-evidence-cited-light", size: .init(width: 340, height: 760), dark: false, readerSize: 17, content: .evidence(query: "Riverglass Observatory", section: 1)),
            Shot(name: "08-evidence-metadata-missing-dark", size: .init(width: 340, height: 640), dark: true, readerSize: 17, content: .evidence(query: "lantern", section: 0)),
        ]
        for shot in shots { try await render(shot, into: directory) }
        UserDefaults.standard.removeObject(forKey: "readerSize")
    }
}
