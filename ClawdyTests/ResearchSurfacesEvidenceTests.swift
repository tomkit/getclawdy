//
//  ResearchSurfacesEvidenceTests.swift
//  ClawdyTests
//
//  Runtime PNG evidence of the REAL recents badge (resting + open list) and the REAL
//  History window, driven by their real controllers over a temp manifest with realistic
//  rows, for design review. Writes PNGs into `CLAWDY_PIXEL_DUMP_DIR` when set.
//

import Testing
import AppKit
import Foundation
@testable import Clawdy

@MainActor
struct ResearchSurfacesEvidenceTests {
    private func makeSeededStore() throws -> ResearchManifestStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawdy-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var clock = Date(timeIntervalSinceNow: -3 * 3600)
        let store = ResearchManifestStore(fileURL: dir.appendingPathComponent("manifest.json"), dateProvider: { clock })
        func tick(_ minutes: Double) { clock = clock.addingTimeInterval(minutes * 60) }
        store.recordRootSession(sessionId: "root-1", title: "Quick answers", workingDir: "/Users/me", transcriptPath: "")
        tick(12)
        store.recordResearchSessionStarted(sessionId: "r1", title: "Three laptops under $900", task: "find three laptops under $900 and build a comparison page", workingDir: "/tmp/r1", transcriptPath: "")
        tick(4); store.recordResearchSessionOutcome(sessionId: "r1", status: .completed, deliverablePath: "/tmp/r1/report.html")
        tick(40)
        store.recordResearchSessionStarted(sessionId: "r2", title: "Best noise-cancelling headphones", task: "find the best noise-cancelling headphones and build a page", workingDir: "/tmp/r2", transcriptPath: "")
        tick(3); store.recordResearchSessionOutcome(sessionId: "r2", status: .failed, deliverablePath: nil)
        tick(50)
        store.recordResearchSessionStarted(sessionId: "r3", title: "Three days in Kyoto", task: "plan a 3-day kyoto itinerary with places to eat", workingDir: "/tmp/r3", transcriptPath: "", engineKind: .claudeCode, skillID: "trip-planner")
        tick(5); store.recordResearchSessionOutcome(sessionId: "r3", status: .completed, deliverablePath: "/tmp/r3/report.html")
        tick(20)
        store.recordResearchSessionStarted(sessionId: "r4", title: "Summarize the open PDF", task: "summarize the pdf", workingDir: "/tmp/r4", transcriptPath: "", engineKind: .claudeCode, skillID: "pdf")
        tick(1); store.recordResearchSessionOutcome(sessionId: "r4", status: .completed, deliverablePath: nil)
        tick(10)
        store.recordResearchSessionStarted(sessionId: "r5", title: "Ramen spots in Tokyo", task: "put together a page of ramen spots in tokyo", workingDir: "/tmp/r5", transcriptPath: "")
        return store
    }

    private func dump(_ view: NSView, named name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @Test func recentsBadgeRestingAndOpenList() throws {
        let store = try makeSeededStore()
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.recentRowsProvider = { ResearchRecentsListBuilder.recentRows(from: store.loadSessions(), now: Date()) }
        controller.liveDismissedSessionIDsProvider = { [] }
        controller.show()
        let panel = try #require(controller.badgePanelForTesting)
        dump(try #require(panel.contentView), named: "recents-badge-resting")
        controller.toggleListForTesting()
        #expect(controller.isListOpenForTesting)
        dump(try #require(panel.contentView), named: "recents-badge-list")
        controller.hide()
    }

    @Test func historyWindowWithASelection() throws {
        let store = try makeSeededStore()
        let controller = ResearchHistoryWindowController(manifestStore: store)
        controller.show(selectSessionID: "r3")
        let window = try #require(controller.windowForTesting)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        dump(try #require(window.contentView), named: "history-window")
        window.orderOut(nil)
    }
}
