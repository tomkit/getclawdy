//
//  CompanionPanelEvidenceTests.swift
//  ClawdyTests
//
//  Runtime PNG evidence of the REAL fully-onboarded menu panel (the settings state a
//  user sees every day), for design review. Writes `menu-panel-onboarded-<engine>.png`
//  into `CLAWDY_PIXEL_DUMP_DIR` when that env var is set; otherwise only asserts the
//  panel renders at a sane height.
//

import Testing
import AppKit
import SwiftUI
@testable import Clawdy

@MainActor
struct CompanionPanelEvidenceTests {
    @Test func fullyOnboardedPanelRendersForEachEngine() {
        for engineKind in CoachEngineKind.allCases {
            let manager = CompanionManager()
            manager.markFullyOnboardedForTesting()
            manager.setSelectedEngine(engineKind)  // no-op if that CLI is not installed here
            let panel = CompanionPanelView(companionManager: manager)

            let hostingView = NSHostingView(rootView: panel)
            let fittingSize = hostingView.fittingSize
            #expect(fittingSize.height > 300, "the onboarded panel has real content")
            let size = CGSize(width: MenuPanelMetrics.windowWidth, height: ceil(fittingSize.height))
            hostingView.frame = CGRect(origin: .zero, size: size)

            let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hostingView
            window.orderFrontRegardless()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            window.orderOut(nil)

            if let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menu-panel-onboarded-\(engineKind.rawValue).png"))
            }
        }
    }
}
