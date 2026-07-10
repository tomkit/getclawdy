//
//  ResearchResultsGlowTests.swift
//  ClawdyTests
//
//  Verifies the results window reads as the SAME window family as the History window: a
//  standard, OPAQUE, titled `NSWindow` with a real system titlebar + frame (its visible defined
//  edge), themed with the History window's own base surface token — NOT the old borderless
//  transparent glow card whose only "edge" was an invisible 1pt hairline and so read as no
//  border at all.
//
//  These are STRUCTURAL assertions on the real `NSWindow` the controller builds. They would have
//  CAUGHT the original regression: the old window was `isOpaque = false`, `backgroundColor =
//  .clear`, `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, so every check
//  below would have failed on it. (The visible frame itself is OS chrome — a titlebar
//  visual-effect view + WKWebView both render out-of-process, so `cacheDisplay` can't rasterize
//  them offscreen; the rendered visual proof is produced separately by screen-capturing the real
//  on-screen windows over a neutral backdrop, saved outside the repo.)
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchResultsGlowTests {

    // MARK: - Theming contract (no rendering)

    /// The results window's opaque fill is the History window's OWN base surface token
    /// (`DS.Colors.background`) — so the two opaque windows share one base color and read as one
    /// system. FAILS if someone re-points the fill at a bespoke color, or back at a translucent
    /// treatment.
    @Test func resultsWindowStyleUsesHistoryBaseSurfaceToken() {
        #expect(ResearchResultsWindowStyle.backgroundColor == NSColor(DS.Colors.background),
                "the results window fill is the History window's base background token")
        // The opaque fill must actually be opaque — a transparent/clear fill is exactly the old
        // ghost-card regression this guards against.
        #expect(ResearchResultsWindowStyle.backgroundColor.alphaComponent == 1,
                "the results window fill is fully opaque (never the old clear/transparent card)")
        #expect(ResearchResultsWindowStyle.minimumContentSize.width > 0
                && ResearchResultsWindowStyle.minimumContentSize.height > 0,
                "the resizable window keeps a sensible minimum footprint")
    }

    /// The REAL shipped window, once on screen, is configured as a standard OPAQUE TITLED window
    /// with a VISIBLE titlebar + a titled frame — the same window family as History — rather than
    /// the old transparent, borderless, hidden-titlebar glow card. This asserts the actual
    /// `NSWindow` the controller builds; every check here would have failed on the old window.
    @Test func resultsWindowIsOpaqueTitledWithVisibleTitlebar() {
        let controller = ResearchResultsWindowController.offscreenForTesting()
        let htmlFileURL = makeTempHTMLFile()
        controller.show(htmlFileURL: htmlFileURL, title: "Best espresso machines under $500", sessionID: "session-opaque")
        defer { controller.hide() }

        guard let window = controller.windowForTesting else {
            Issue.record("results window was not created")
            return
        }

        #expect(window.isOpaque, "the results window is opaque (not the old transparent card)")
        #expect(window.backgroundColor == ResearchResultsWindowStyle.backgroundColor,
                "the window wears the opaque themed background fill")
        #expect(!window.titlebarAppearsTransparent,
                "the titlebar is a standard visible titlebar (not the old transparent one)")
        #expect(window.titleVisibility == .visible,
                "the window title is visible (not the old hidden-title glow card)")
        #expect(window.styleMask.contains(.titled),
                "the window has a real titled system frame — its visible defined edge")
        // The old glow card used `.fullSizeContentView` so the page + aura owned the whole
        // window under a hidden titlebar; a standard titled window drops it so the titlebar is
        // its own defined strip.
        #expect(!window.styleMask.contains(.fullSizeContentView),
                "the content no longer bleeds under the titlebar (a real, separate titlebar strip)")
        #expect(window.title == "Best espresso machines under $500",
                "the system titlebar shows the research task title, like History's 'Clawdy History'")
        // The deliverable must still be screenshottable for spoken follow-ups.
        #expect(window.sharingType == .readOnly,
                "the window stays capturable (.readOnly) so follow-up screenshots see the page")
    }

    // MARK: - Helpers

    /// Writes a tiny self-contained HTML file to a temp dir and returns its URL, so the results
    /// window has a real local page to load.
    private func makeTempHTMLFile() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-results-window-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("report.html")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body><h1>Best espresso machines under $500</h1></body></html>
        """
        try? html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
