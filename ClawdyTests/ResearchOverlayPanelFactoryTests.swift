//
//  ResearchOverlayPanelFactoryTests.swift
//  ClawdyTests
//
//  Locks the per-type behavior of the shared overlay-panel factory
//  `ResearchToastPanel.makeOverlayPanel(size:panelType:hasShadow:includesStationaryCollectionBehavior:)`
//  after the two forked panel constructors (the keyable chat detail panel and the
//  clarification panel) were folded back onto it. The factory must reproduce EACH
//  fork's exact panel properties, so these tests pin:
//    • the DEFAULT (toast/control) shape — plain NSPanel, no shadow, `.stationary`;
//    • the DETAIL shape — a KeyableResearchPanel that otherwise matches the default;
//    • the CLARIFICATION shape — a KeyableResearchPanel WITH a drop shadow and
//      WITHOUT `.stationary`.
//  All three still share the invariant flags (borderless + non-activating style,
//  `.statusBar` level, transparent, `hidesOnDeactivate == false`, all-Spaces +
//  full-screen-auxiliary collection behavior, and excluded from the Windows menu).
//  `sharingType` is now MODE-AWARE rather than always `.none`: the factory reads the
//  "Show Clawdy in screen recordings" (Recording Mode) setting at construction, so a
//  panel is `.none` (hidden from external recorders — the default) when the mode is
//  off and `.readOnly` (visible to recorders, for demos) when it's on. Tests that
//  assert a specific value force the mode explicitly via `withRecordingMode`.
//

import Testing
import AppKit
@testable import Clawdy

@MainActor
struct ResearchOverlayPanelFactoryTests {

    private let size = CGSize(width: 320, height: 120)

    /// Every panel the factory produces — regardless of type/shadow/stationary — shares
    /// these flags. Asserting them once per case proves the parameters only change the
    /// three intended dimensions and nothing else drifted.
    ///
    /// `sharingType` is NO LONGER an absolute `.none`: it now follows the "Show Clawdy
    /// in screen recordings" (Recording Mode) setting the factory reads at
    /// construction. So we compute the expected value from the CURRENT default (which
    /// each caller sets deterministically) — `.none` when off, `.readOnly` when on —
    /// and assert against that. The dedicated `overlayPanelSharingTypeFollowsRecordingMode`
    /// test pins the mapping in both modes explicitly.
    private func assertSharedInvariants(_ panel: NSPanel) {
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .statusBar)
        #expect(panel.isOpaque == false)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.ignoresMouseEvents == false)
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.isExcludedFromWindowsMenu == true)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        // Recording-Mode-aware: matches the setting the factory read at construction.
        let expectedSharingType = RecordingMode.overlaySharingType(
            recordingEnabled: UserDefaults.standard.bool(forKey: .recordingModeEnabled)
        )
        #expect(panel.sharingType == expectedSharingType)
    }

    /// Runs `body` with the Recording Mode default forced to `enabled`, restoring the
    /// prior value afterwards so the shared standard domain is never left mutated.
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

    /// DEFAULT (the 5 existing toast/control callers): a plain `NSPanel`, NO shadow,
    /// WITH `.stationary`. This is the exact shape those callers depended on.
    @Test func defaultOverlayPanelIsPlainNSPanelWithStationaryAndNoShadow() {
        let panel = ResearchToastPanel.makeOverlayPanel(size: size)
        assertSharedInvariants(panel)
        // The default type is a plain NSPanel — NOT the keyable subclass.
        #expect(type(of: panel) == NSPanel.self)
        #expect((panel as? KeyableResearchPanel) == nil)
        #expect(panel.hasShadow == false)
        #expect(panel.collectionBehavior.contains(.stationary))
    }

    /// DETAIL panel: a `KeyableResearchPanel` (must become key to accept typing) that is
    /// otherwise byte-for-byte the default shape — NO shadow, WITH `.stationary`.
    @Test func detailPanelIsKeyableWithStationaryAndNoShadow() {
        let panel = ResearchToastPanel.makeOverlayPanel(
            size: size,
            panelType: KeyableResearchPanel.self
        )
        assertSharedInvariants(panel)
        #expect(panel is KeyableResearchPanel)
        #expect(panel.canBecomeKey == true)
        #expect(panel.hasShadow == false)
        #expect(panel.collectionBehavior.contains(.stationary))
    }

    /// CLARIFICATION panel: a `KeyableResearchPanel` WITH a system drop shadow and
    /// WITHOUT `.stationary` — the two ways it deliberately differs from the toasts.
    @Test func clarificationPanelIsKeyableWithShadowAndNoStationary() {
        let panel = ResearchToastPanel.makeOverlayPanel(
            size: size,
            panelType: KeyableResearchPanel.self,
            hasShadow: true,
            includesStationaryCollectionBehavior: false
        )
        assertSharedInvariants(panel)
        #expect(panel is KeyableResearchPanel)
        #expect(panel.canBecomeKey == true)
        #expect(panel.hasShadow == true)
        #expect(panel.collectionBehavior.contains(.stationary) == false)
    }

    /// MODE-AWARE sharingType: the factory reads the Recording Mode setting at
    /// construction, so a panel built while it's OFF is `.none` (hidden from external
    /// recorders — the default) and one built while it's ON is `.readOnly` (visible to
    /// recorders for demos). Neither ever affects Clawdy's OWN model screenshots.
    @Test func overlayPanelSharingTypeFollowsRecordingMode() {
        withRecordingMode(false) {
            let offPanel = ResearchToastPanel.makeOverlayPanel(size: size)
            #expect(offPanel.sharingType == NSWindow.SharingType.none,
                    "Recording Mode OFF → research overlay panels are hidden from external recorders (.none)")
        }
        withRecordingMode(true) {
            let onPanel = ResearchToastPanel.makeOverlayPanel(size: size)
            #expect(onPanel.sharingType == .readOnly,
                    "Recording Mode ON → research overlay panels are visible to external recorders (.readOnly)")
        }
        // Toggling back off fully reverts for newly-built panels.
        withRecordingMode(false) {
            let revertedPanel = ResearchToastPanel.makeOverlayPanel(size: size)
            #expect(revertedPanel.sharingType == NSWindow.SharingType.none)
        }
    }

    /// The live detail panel the stacked overlay actually builds must be a
    /// `KeyableResearchPanel` (via the real render path, not just the factory in
    /// isolation) — so a future change to `makeKeyableDetailPanel` can't silently drop
    /// the keyable subclass. Its `sharingType` is Recording-Mode-aware, so the
    /// assertion forces the mode explicitly rather than depending on the ambient
    /// default: `.none` when off (the default), `.readOnly` when on.
    @Test func renderedDetailPanelIsKeyableResearchPanel() {
        withRecordingMode(false) {
            let controller = ResearchStackedOverlayController.offscreenForTesting()
            let viewModel = ResearchProgressOverlayViewModel()
            viewModel.phase = .running
            viewModel.taskDescription = "research detail"
            viewModel.statusLine = "Planning the research…"
            viewModel.isCancellable = true
            let pill = ResearchStackPillModel(id: "detail-keyable-off", viewModel: viewModel, isFocused: true)
            controller.render(pills: [pill], controlRow: nil, detailViewModel: viewModel)
            defer { controller.hide() }

            let detailPanel = controller.detailPanelForTesting
            #expect(detailPanel is KeyableResearchPanel,
                    "the chat detail panel must be a KeyableResearchPanel so its text input can accept typing")
            #expect(detailPanel?.hasShadow == false)
            #expect(detailPanel?.collectionBehavior.contains(.stationary) == true)
            #expect(detailPanel?.sharingType == NSWindow.SharingType.none,
                    "Recording Mode OFF → the rendered detail panel is hidden from recorders (.none)")
        }

        // Recording Mode ON → the same rendered detail panel is visible to recorders.
        withRecordingMode(true) {
            let controller = ResearchStackedOverlayController.offscreenForTesting()
            let viewModel = ResearchProgressOverlayViewModel()
            viewModel.phase = .running
            viewModel.taskDescription = "research detail"
            viewModel.statusLine = "Planning the research…"
            viewModel.isCancellable = true
            let pill = ResearchStackPillModel(id: "detail-keyable-on", viewModel: viewModel, isFocused: true)
            controller.render(pills: [pill], controlRow: nil, detailViewModel: viewModel)
            defer { controller.hide() }

            #expect(controller.detailPanelForTesting?.sharingType == .readOnly,
                    "Recording Mode ON → the rendered detail panel is visible to recorders (.readOnly)")
        }
    }
}
