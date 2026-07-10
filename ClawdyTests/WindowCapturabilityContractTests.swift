//
//  WindowCapturabilityContractTests.swift
//  ClawdyTests
//
//  REGRESSION LOCK for the window CAPTURABILITY contract. Clawdy screenshots the
//  user's screen(s) and sends them to the model, so every window it owns is on one of
//  two sides of a hard line:
//
//   • The research RESULTS window (the WKWebView that renders the generated page) MUST
//     be CAPTURABLE — `sharingType == .readOnly`. This has regressed before: when the
//     results window was `.none`, Clawdy could not screenshot the very page it just
//     produced, so a spoken follow-up "about the page" saw nothing.
//   • The cursor/response overlay and the research chrome (stacked overlay, detail
//     panel, clarify panel) are ALWAYS `.readOnly` — VISIBLE to external screen
//     recorders (QuickTime/OBS) so Clawdy shows up in the user's demos/recordings.
//     This is safe because they never reach Clawdy's OWN model screenshots: the
//     capture path app-excludes Clawdy regardless of `sharingType`. The menu-bar
//     panel is the ONE exception — it stays `.none` always so the settings/engine
//     picker never leaks into a demo.
//
//  These tests pin both sides so a future change can't silently flip either. They are
//  strictly additive: no production code is changed. Surfaces without a headless test
//  seam are documented as skipped in `capturabilityContractSkippedSurfaces` below.
//

import Testing
import AppKit
@testable import Clawdy

@MainActor
struct WindowCapturabilityContractTests {

    /// A screen to build screen-scoped windows against; the CI host has at least one.
    private func anyScreen() -> NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// Writes a tiny self-contained report.html so the results-window controller has a
    /// real file:// URL to load.
    private func makeTemporaryReportHTML() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturability-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("report.html")
        try "<!doctype html><html><body><h1>report</h1></body></html>"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Builds a running pill model to drive the stacked overlay headlessly.
    private func makeRunningPill(id: ResearchSessionID) -> ResearchStackPillModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "research \(id)"
        viewModel.statusLine = "Planning the research…"
        viewModel.isCancellable = true
        return ResearchStackPillModel(id: id, viewModel: viewModel, isFocused: true)
    }

    // MARK: - THE critical one: results window must be CAPTURABLE

    /// The research RESULTS window (WKWebView) is `.readOnly` — CAPTURABLE — NOT `.none`.
    /// This is the exact regression that made Clawdy unable to screenshot its own
    /// generated page. If this ever reads `.none`, the follow-up-about-the-page flow is
    /// broken again.
    @Test func researchResultsWindowIsCapturableReadOnly() throws {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        let reportURL = try makeTemporaryReportHTML()
        let controller = ResearchResultsWindowController.offscreenForTesting()
        controller.show(htmlFileURL: reportURL, title: "report", sessionID: "sess-capturable")
        defer { controller.hide() }

        let window = controller.windowForTesting
        #expect(window != nil, "showing the results window must create it")
        #expect(window?.sharingType == .readOnly,
                "the results window MUST stay CAPTURABLE (.readOnly) so Clawdy can screenshot the page it generated — never .none")
        // Guard the specific past regression explicitly.
        #expect(window?.sharingType != NSWindow.SharingType.none,
                "the results window must never be .none (the exact prior break)")
    }

    // MARK: - Chrome must NOT be capturable

    /// The full-screen cursor/response overlay window (`OverlayWindow`) is ALWAYS
    /// `.readOnly` — VISIBLE to external recorders so the blue cursor + response
    /// bubble show up in demos/recordings. It never reaches Clawdy's OWN model
    /// screenshots, which app-exclude Clawdy regardless of `sharingType`.
    @Test func cursorOverlayWindowIsAlwaysReadOnly() throws {
        guard let screen = anyScreen() else {
            Issue.record("no screen available to build the cursor overlay window")
            return
        }
        let overlayWindow = OverlayWindow(screen: screen)
        #expect(overlayWindow.sharingType == .readOnly,
                "the cursor/response overlay is always visible to recorders (.readOnly)")
        // Guard the flip: it must never be back to `.none` (that would hide Clawdy
        // from the user's screen recordings — the exact thing we now want on).
        #expect(overlayWindow.sharingType != NSWindow.SharingType.none)
    }

    /// The transient research overlay chrome — the stacked pill panel AND its detail
    /// panel — is ALWAYS `.readOnly` (visible to recorders). (Also covered by
    /// `ResearchOverlayPanelFactoryTests`; re-pinned here so the whole contract lives
    /// in one place.)
    @Test func researchOverlayChromeIsAlwaysReadOnly() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        let pill = makeRunningPill(id: "chrome")
        controller.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
        defer { controller.hide() }

        #expect(controller.toastPanelForTesting(id: "chrome")?.sharingType == .readOnly,
                "each research toast window is visible to recorders (.readOnly)")
        #expect(controller.detailPanelForTesting?.sharingType == .readOnly,
                "the research detail panel is visible to recorders (.readOnly)")
    }

    // MARK: - Consolidated contract (documents the whole invariant in one place)

    /// ONE place that documents and enforces the whole capturability invariant across
    /// every headlessly-instantiable surface:
    ///   results window            => .readOnly (CAPTURABLE)
    ///   stacked research overlay   => .readOnly (visible to recorders)
    ///   research detail panel      => .readOnly
    ///   cursor/response overlay    => .readOnly
    /// The menu-bar panel is the sole `.none` surface (not headlessly instantiable —
    /// see `capturabilityContractSkippedSurfaces`). Every capturable Clawdy window is
    /// still kept OUT of the model screenshots by app-level exclusion in
    /// `CompanionScreenCaptureUtility`, not by `sharingType`.
    @Test func windowCapturabilityContractHoldsAcrossInstantiableSurfaces() throws {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        // CAPTURABLE side: the results WKWebView window.
        let reportURL = try makeTemporaryReportHTML()
        let resultsController = ResearchResultsWindowController.offscreenForTesting()
        resultsController.show(htmlFileURL: reportURL, title: "report", sessionID: "sess-contract")
        defer { resultsController.hide() }
        #expect(resultsController.windowForTesting?.sharingType == .readOnly,
                "CONTRACT: the results window is CAPTURABLE (.readOnly)")

        // ALSO-CAPTURABLE side: the transient research overlay chrome and the
        // cursor/response overlay are now `.readOnly` (visible to recorders). They
        // stay out of the MODEL screenshots via app-level exclusion, not sharingType.
        let overlayController = ResearchStackedOverlayController.offscreenForTesting()
        let pill = makeRunningPill(id: "contract")
        overlayController.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
        defer { overlayController.hide() }
        #expect(overlayController.toastPanelForTesting(id: "contract")?.sharingType == .readOnly,
                "CONTRACT: each research toast window is visible to recorders (.readOnly)")
        #expect(overlayController.detailPanelForTesting?.sharingType == .readOnly,
                "CONTRACT: the detail panel is visible to recorders (.readOnly)")

        // ALSO-CAPTURABLE side: the full-screen cursor/response overlay.
        if let screen = anyScreen() {
            #expect(OverlayWindow(screen: screen).sharingType == .readOnly,
                    "CONTRACT: the cursor/response overlay is visible to recorders (.readOnly)")
        } else {
            Issue.record("no screen available to build the cursor overlay window")
        }
    }

    // MARK: - The ONE non-capturable overlay: the menu-bar dropdown

    /// The menu-bar dropdown panel is `.none` — NON-capturable — so the settings /
    /// engine-picker / hints it renders never leak into a screen recording, even though
    /// every OTHER Clawdy overlay is now `.readOnly` (visible to recorders). Built
    /// through the manager's REAL panel factory (`MenuBarPanelManager.makeMenuBarPanel`,
    /// which `createPanel` delegates to) so a regression that flips it to `.readOnly`
    /// (leaking the settings into a demo) fails here. We use the static factory rather
    /// than constructing the whole manager because the manager's `init` spawns an
    /// `NSStatusItem` whose icon can't render in a headless test host.
    @Test func menuBarPanelIsNeverCapturable() {
        let panel = MenuBarPanelManager.makeMenuBarPanel(
            companionManager: CompanionManager(),
            width: 320,
            height: 380
        )
        #expect(panel.sharingType == NSWindow.SharingType.none,
                "the menu-bar dropdown must never be visible to screen recorders (.none)")

        // Contrast pin: an overlay built alongside is `.readOnly`, so this locks the
        // exact divergence — settings chrome stays hidden while demo overlays show.
        if let screen = anyScreen() {
            #expect(OverlayWindow(screen: screen).sharingType == .readOnly,
                    "overlays are visible to recorders (.readOnly) while the menu panel stays .none")
        }
    }

    /// DOCUMENTATION (not an assertion target): chrome surfaces that cannot be pinned
    /// here because they expose no headless test seam — their panels are private and the
    /// sharing type is set inside a private `show()`/`create…()` method:
    ///   • ResearchClarificationPanelManager — private `panel`, built via the shared
    ///     `ResearchToastPanel.makeOverlayPanel`, so its `sharingType` is `.readOnly`
    ///     (visible to recorders) like the other research chrome; the factory itself is
    ///     pinned in `ResearchOverlayPanelFactoryTests`.
    /// (The menu-bar panel USED to live here; it is now pinned directly by
    /// `menuBarPanelIsNeverCapturable` above via a read-only test seam.)
    /// These are asserted-by-source-review only; if a seam is added later, fold them into
    /// `windowCapturabilityContractHoldsAcrossInstantiableSurfaces`.
    static let capturabilityContractSkippedSurfaces = [
        "ResearchClarificationPanelManager.panel",
    ]
}
