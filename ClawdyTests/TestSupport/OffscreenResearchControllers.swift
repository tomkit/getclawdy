import AppKit
@testable import Clawdy

//  Shared test seam for the three LOAD-BEARING research overlay controllers whose real
//  production positioning anchors an NSPanel at the screen's top-left (and calls
//  `orderFrontRegardless()` / `makeKeyAndOrderFront`). Under `xcodebuild test` those real
//  panels flash in the upper-left of the display. Each controller exposes a
//  `testAnchorOriginOffset` positioning offset (production default `.zero`, so on-screen
//  positioning is byte-for-byte unchanged); these factories create a controller with that
//  offset pre-set FAR off-screen, so tests exercise the exact same real behavior (window
//  created, frame size, tracking rect, registry binding, morph, teardown) without the flash.
//
//  This reuses the same off-screen approach as `makeOffscreenRenderWindow` (the pixel-render
//  helper) — a large negative origin that every connected screen lies far away from, while
//  AppKit still composites the panel's content normally.

/// A large negative offset that pushes an overlay panel far outside every connected screen,
/// mirroring `makeOffscreenRenderWindow`'s `-10000` off-screen origin (with extra margin for
/// panels anchored relative to a screen's visible frame).
let offscreenResearchAnchorOffset = CGVector(dx: -30000, dy: -30000)

@MainActor
extension ResearchStackedOverlayController {
    /// A stacked-overlay controller whose real panels are anchored off-screen for tests.
    static func offscreenForTesting() -> ResearchStackedOverlayController {
        let controller = ResearchStackedOverlayController()
        controller.testAnchorOriginOffset = offscreenResearchAnchorOffset
        return controller
    }
}

@MainActor
extension ResearchRecentsBadgeController {
    /// A recents-badge controller whose real badge window is anchored off-screen for tests.
    static func offscreenForTesting() -> ResearchRecentsBadgeController {
        let controller = ResearchRecentsBadgeController()
        controller.testAnchorOriginOffset = offscreenResearchAnchorOffset
        return controller
    }
}

@MainActor
extension ResearchResultsWindowController {
    /// A results-window controller whose real window is anchored off-screen for tests.
    static func offscreenForTesting() -> ResearchResultsWindowController {
        let controller = ResearchResultsWindowController()
        controller.testAnchorOriginOffset = offscreenResearchAnchorOffset
        return controller
    }
}
