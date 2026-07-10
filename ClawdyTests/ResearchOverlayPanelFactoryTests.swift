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
//  full-screen-auxiliary collection behavior, excluded from the Windows menu, and —
//  critically — `sharingType == .none`).
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
        // Never leak overlay chrome into a screenshot.
        #expect(panel.sharingType == NSWindow.SharingType.none)
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

    /// The live detail panel the stacked overlay actually builds must be a
    /// `KeyableResearchPanel` (via the real render path, not just the factory in
    /// isolation) — so a future change to `makeKeyableDetailPanel` can't silently drop
    /// the keyable subclass.
    @Test func renderedDetailPanelIsKeyableResearchPanel() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "research detail"
        viewModel.statusLine = "Planning the research…"
        viewModel.isCancellable = true
        let pill = ResearchStackPillModel(id: "detail-keyable", viewModel: viewModel, isFocused: true)
        controller.render(pills: [pill], controlRow: nil, detailViewModel: viewModel)
        defer { controller.hide() }

        let detailPanel = controller.detailPanelForTesting
        #expect(detailPanel is KeyableResearchPanel,
                "the chat detail panel must be a KeyableResearchPanel so its text input can accept typing")
        #expect(detailPanel?.hasShadow == false)
        #expect(detailPanel?.collectionBehavior.contains(.stationary) == true)
        #expect(detailPanel?.sharingType == NSWindow.SharingType.none)
    }
}
