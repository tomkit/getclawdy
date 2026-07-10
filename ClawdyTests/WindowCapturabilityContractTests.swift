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
//   • ALL transient CHROME (the stacked research overlay, its detail panel, the cursor/
//     response overlay, the clarify panel, the menu-bar panel) MUST be NON-capturable —
//     `sharingType == .none` — so it never leaks into a screenshot sent to the model.
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

    /// The full-screen cursor/response overlay window (`OverlayWindow`) is `.none` so the
    /// blue cursor + response bubble never leak into a screenshot. Constructed directly
    /// (its init sets the sharing type).
    @Test func cursorOverlayWindowIsScreenshotExcluded() throws {
        guard let screen = anyScreen() else {
            Issue.record("no screen available to build the cursor overlay window")
            return
        }
        let overlayWindow = OverlayWindow(screen: screen)
        #expect(overlayWindow.sharingType == .none,
                "the full-screen cursor/response overlay must never be captured (.none)")
    }

    /// The transient research overlay chrome — the stacked pill panel AND its detail
    /// panel — are `.none`. (Also covered by `ResearchOverlayTests`; re-pinned here so
    /// the whole contract lives in one place.)
    @Test func researchOverlayChromeIsScreenshotExcluded() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        let pill = makeRunningPill(id: "chrome")
        controller.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
        defer { controller.hide() }

        // NB: spell the enum type out — a bare `.none` against an Optional `sharingType`
        // resolves to `Optional.none` (nil), not `NSWindow.SharingType.none`.
        #expect(controller.toastPanelForTesting(id: "chrome")?.sharingType == NSWindow.SharingType.none,
                "each research toast window must never be captured (.none)")
        #expect(controller.detailPanelForTesting?.sharingType == NSWindow.SharingType.none,
                "the research detail panel must never be captured (.none)")
    }

    // MARK: - Consolidated contract (documents the whole invariant in one place)

    /// ONE place that documents and enforces the whole capturability invariant across
    /// every headlessly-instantiable surface:
    ///   results window            => .readOnly (CAPTURABLE)
    ///   stacked research overlay   => .none (chrome, never captured)
    ///   research detail panel      => .none
    ///   cursor/response overlay    => .none
    /// Surfaces that can't be built headlessly are listed in
    /// `capturabilityContractSkippedSurfaces` with the reason.
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

        // NON-CAPTURABLE side: the transient research overlay chrome.
        let overlayController = ResearchStackedOverlayController.offscreenForTesting()
        let pill = makeRunningPill(id: "contract")
        overlayController.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
        defer { overlayController.hide() }
        #expect(overlayController.toastPanelForTesting(id: "contract")?.sharingType == NSWindow.SharingType.none,
                "CONTRACT: each research toast window is chrome (.none)")
        #expect(overlayController.detailPanelForTesting?.sharingType == NSWindow.SharingType.none,
                "CONTRACT: the detail panel is chrome (.none)")

        // NON-CAPTURABLE side: the full-screen cursor/response overlay.
        if let screen = anyScreen() {
            #expect(OverlayWindow(screen: screen).sharingType == .none,
                    "CONTRACT: the cursor/response overlay is chrome (.none)")
        } else {
            Issue.record("no screen available to build the cursor overlay window")
        }
    }

    /// DOCUMENTATION (not an assertion target): chrome surfaces that ALSO must be `.none`
    /// but cannot be pinned here because they expose no headless test seam — their panels
    /// are private and the sharing type is set inside a private `show()`/`create…()`
    /// method, so reaching them would require adding a production accessor (out of scope
    /// for this test-only change):
    ///   • ResearchClarificationPanelManager — private `panel`, `.none` set in `show()`.
    ///   • MenuBarPanelManager                — private `panel`; constructing the manager
    ///     also needs a `CompanionManager` and spawns an `NSStatusItem`.
    /// These are asserted-by-source-review only; if a seam is added later, fold them into
    /// `windowCapturabilityContractHoldsAcrossInstantiableSurfaces`.
    static let capturabilityContractSkippedSurfaces = [
        "ResearchClarificationPanelManager.panel",
        "MenuBarPanelManager.panel",
    ]
}
