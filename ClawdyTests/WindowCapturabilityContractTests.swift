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
//   • The transient CHROME's capturability is now MODE-AWARE, governed by the "Show
//     Clawdy in screen recordings" (Recording Mode) setting. When it's OFF (the
//     default) the stacked research overlay, its detail panel, the clarify panel, and
//     the cursor/response overlay are `.none` (NON-capturable) so nothing leaks into a
//     screenshot sent to the model; when it's ON they become `.readOnly` (visible to
//     external recorders, for demos). The menu-bar panel is deliberately excluded from
//     the flip and stays `.none` always (its settings must never leak into a demo).
//     Either way, chrome never reaches Clawdy's OWN model screenshots, which
//     app-exclude Clawdy regardless of `sharingType`. Mode-specific tests force the
//     mode explicitly via `withRecordingMode`.
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

    /// Runs `body` with the Recording Mode default forced to `enabled`, restoring the
    /// prior value afterwards so the shared standard domain is never left mutated.
    /// The overlay windows read this setting at construction, so the chrome tests set
    /// it deterministically instead of depending on the ambient default.
    private func withRecordingMode(_ enabled: Bool, _ body: () -> Void) {
        let key = DefaultsKey.recordingModeEnabled
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

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

    /// The full-screen cursor/response overlay window (`OverlayWindow`) is MODE-AWARE:
    /// `.none` (never captured) when Recording Mode is OFF — the default that keeps the
    /// blue cursor + response bubble out of screenshots — and `.readOnly` (visible to
    /// external recorders) when it's ON for demos. Either way it never reaches Clawdy's
    /// OWN model screenshots, which app-exclude Clawdy regardless of `sharingType`.
    @Test func cursorOverlayWindowSharingTypeFollowsRecordingMode() throws {
        guard let screen = anyScreen() else {
            Issue.record("no screen available to build the cursor overlay window")
            return
        }
        withRecordingMode(false) {
            #expect(OverlayWindow(screen: screen).sharingType == .none,
                    "Recording Mode OFF → the cursor/response overlay is hidden from recorders (.none)")
        }
        withRecordingMode(true) {
            #expect(OverlayWindow(screen: screen).sharingType == .readOnly,
                    "Recording Mode ON → the cursor/response overlay is visible to recorders (.readOnly)")
        }
    }

    /// The transient research overlay chrome — the stacked pill panel AND its detail
    /// panel — is MODE-AWARE: `.none` when Recording Mode is OFF (never captured, the
    /// default) and `.readOnly` when it's ON. (Also covered by `ResearchOverlayTests`;
    /// re-pinned here so the whole contract lives in one place.)
    @Test func researchOverlayChromeSharingTypeFollowsRecordingMode() {
        // NB: spell the enum type out — a bare `.none` against an Optional `sharingType`
        // resolves to `Optional.none` (nil), not `NSWindow.SharingType.none`.
        withRecordingMode(false) {
            let controller = ResearchStackedOverlayController.offscreenForTesting()
            let pill = makeRunningPill(id: "chrome-off")
            controller.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
            defer { controller.hide() }
            #expect(controller.toastPanelForTesting(id: "chrome-off")?.sharingType == NSWindow.SharingType.none,
                    "Recording Mode OFF → each research toast window is hidden from recorders (.none)")
            #expect(controller.detailPanelForTesting?.sharingType == NSWindow.SharingType.none,
                    "Recording Mode OFF → the research detail panel is hidden from recorders (.none)")
        }
        withRecordingMode(true) {
            let controller = ResearchStackedOverlayController.offscreenForTesting()
            let pill = makeRunningPill(id: "chrome-on")
            controller.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
            defer { controller.hide() }
            #expect(controller.toastPanelForTesting(id: "chrome-on")?.sharingType == .readOnly,
                    "Recording Mode ON → each research toast window is visible to recorders (.readOnly)")
            #expect(controller.detailPanelForTesting?.sharingType == .readOnly,
                    "Recording Mode ON → the research detail panel is visible to recorders (.readOnly)")
        }
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

        // NON-CAPTURABLE side (in the DEFAULT Recording-Mode-OFF state): the transient
        // research overlay chrome and the cursor/response overlay are `.none`. Pinned
        // to OFF explicitly so the contract is deterministic; the mode-aware
        // `…FollowsRecordingMode` tests above cover the ON state.
        withRecordingMode(false) {
            let overlayController = ResearchStackedOverlayController.offscreenForTesting()
            let pill = makeRunningPill(id: "contract")
            overlayController.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
            defer { overlayController.hide() }
            #expect(overlayController.toastPanelForTesting(id: "contract")?.sharingType == NSWindow.SharingType.none,
                    "CONTRACT: each research toast window is chrome (.none) when Recording Mode is off")
            #expect(overlayController.detailPanelForTesting?.sharingType == NSWindow.SharingType.none,
                    "CONTRACT: the detail panel is chrome (.none) when Recording Mode is off")

            // NON-CAPTURABLE side: the full-screen cursor/response overlay.
            if let screen = anyScreen() {
                #expect(OverlayWindow(screen: screen).sharingType == .none,
                        "CONTRACT: the cursor/response overlay is chrome (.none) when Recording Mode is off")
            } else {
                Issue.record("no screen available to build the cursor overlay window")
            }
        }
    }

    /// DOCUMENTATION (not an assertion target): chrome surfaces that cannot be pinned
    /// here because they expose no headless test seam — their panels are private and the
    /// sharing type is set inside a private `show()`/`create…()` method, so reaching them
    /// would require adding a production accessor (out of scope for this test-only
    /// change):
    ///   • ResearchClarificationPanelManager — private `panel`, built via the shared
    ///     `ResearchToastPanel.makeOverlayPanel`, so its `sharingType` is MODE-AWARE
    ///     (`.none` when Recording Mode off, `.readOnly` when on) like the other research
    ///     chrome; the factory itself is pinned in `ResearchOverlayPanelFactoryTests`.
    ///   • MenuBarPanelManager                — private `panel`, `.none` ALWAYS (excluded
    ///     from the Recording Mode flip); constructing the manager also needs a
    ///     `CompanionManager` and spawns an `NSStatusItem`.
    /// These are asserted-by-source-review only; if a seam is added later, fold them into
    /// `windowCapturabilityContractHoldsAcrossInstantiableSurfaces`.
    static let capturabilityContractSkippedSurfaces = [
        "ResearchClarificationPanelManager.panel",
        "MenuBarPanelManager.panel",
    ]
}
