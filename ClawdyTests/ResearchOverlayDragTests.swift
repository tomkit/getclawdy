//
//  ResearchOverlayDragTests.swift
//  ClawdyTests
//
//  Covers the draggable upper-left research overlay cluster (the toast stack + the idle
//  recents badge share ONE offset, so dragging either moves both):
//   (a) the PURE offset math — accumulation of drag deltas and the on-screen clamp,
//   (b) the toast stack LAYOUT applies the shared offset (its slot origin shifts by it),
//   (c) the idle badge LAYOUT applies the same offset (its slot origin shifts by it),
//   (d) the REAL-PATH central sync + persistence: a drag reported by one surface is stored
//       to UserDefaults and synced to BOTH controllers, and a restored offset re-hydrates.
//

import AppKit
import Testing
@testable import Clawdy

// MARK: - Pure accumulation + clamp

@MainActor
struct ResearchOverlayDragOffsetPureTests {

    /// Accumulation is additive: many small drag steps sum to the total move.
    @Test func accumulateSumsDeltasIntoTheRunningOffset() {
        let start = CGVector(dx: 10, dy: -4)
        let afterFirst = ResearchOverlayDragOffset.accumulate(current: start, delta: CGVector(dx: 5, dy: 3))
        #expect(afterFirst.dx == 15)
        #expect(afterFirst.dy == -1)
        let afterSecond = ResearchOverlayDragOffset.accumulate(current: afterFirst, delta: CGVector(dx: -20, dy: 6))
        #expect(afterSecond.dx == -5)
        #expect(afterSecond.dy == 5)
    }

    /// An offset that keeps the pill fully inside the visible frame is left untouched.
    @Test func clampLeavesAnOnScreenOffsetUnchanged() {
        // Pill near the top-left; visible frame a generous 2000×1400 screen.
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        let basePill = CGRect(x: 16, y: 1300, width: 320, height: 68)
        let offset = CGVector(dx: 200, dy: -300)
        let clamped = ResearchOverlayDragOffset.clamp(offset, basePillScreenRect: basePill, visibleFrame: visibleFrame)
        #expect(clamped.dx == offset.dx)
        #expect(clamped.dy == offset.dy)
    }

    /// Dragging far LEFT is clamped so the pill's leading edge stops at the frame's left edge.
    @Test func clampPinsPillToTheLeftEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        let basePill = CGRect(x: 16, y: 1300, width: 320, height: 68)
        // Way past the left edge (pill.minX = 16, so the most-negative allowed dx is -16).
        let clamped = ResearchOverlayDragOffset.clamp(CGVector(dx: -5000, dy: 0), basePillScreenRect: basePill, visibleFrame: visibleFrame)
        #expect(clamped.dx == -16)
        #expect(basePill.minX + clamped.dx == visibleFrame.minX)
    }

    /// Dragging far RIGHT / DOWN is clamped so the pill's trailing / bottom edge stops at the frame.
    @Test func clampPinsPillToTheRightAndBottomEdges() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        let basePill = CGRect(x: 16, y: 1300, width: 320, height: 68)
        let clamped = ResearchOverlayDragOffset.clamp(CGVector(dx: 9000, dy: -9000), basePillScreenRect: basePill, visibleFrame: visibleFrame)
        // Right: pill.maxX (336) + dx == frame.maxX (2000) → dx == 1664.
        #expect(clamped.dx == visibleFrame.maxX - basePill.maxX)
        #expect(basePill.maxX + clamped.dx == visibleFrame.maxX)
        // Down (smaller y in AppKit): pill.minY (1300) + dy == frame.minY (0) → dy == -1300.
        #expect(clamped.dy == visibleFrame.minY - basePill.minY)
        #expect(basePill.minY + clamped.dy == visibleFrame.minY)
    }

    /// A pill somehow LARGER than the visible frame pins to the lower bound (leading/bottom
    /// edge anchored) rather than producing an empty clamp range.
    @Test func clampPinsAnOversizedPillToTheLowerBound() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let basePill = CGRect(x: 0, y: 0, width: 400, height: 400)
        let clamped = ResearchOverlayDragOffset.clamp(CGVector(dx: 50, dy: 50), basePillScreenRect: basePill, visibleFrame: visibleFrame)
        #expect(clamped.dx == visibleFrame.minX - basePill.minX)
        #expect(clamped.dy == visibleFrame.minY - basePill.minY)
    }
}

// MARK: - Layout applies the offset (toast stack + badge)

@MainActor
struct ResearchOverlayDragLayoutTests {

    private func makePill(id: ResearchSessionID) -> ResearchStackPillModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "research \(id)"
        viewModel.statusLine = "Planning…"
        return ResearchStackPillModel(id: id, viewModel: viewModel, isFocused: false)
    }

    /// The toast stack's laid-out slot origin shifts by exactly the applied drag offset.
    @Test func toastStackSlotOriginShiftsByTheDragOffset() throws {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        defer { controller.hide() }
        controller.render(pills: [makePill(id: "a")], controlRow: nil, detailViewModel: nil)

        let baseline = try #require(controller.slotTopLeftForTesting(id: "a"))
        let dragOffset = CGVector(dx: 120, dy: -80)
        controller.applyUserColumnDragOffset(dragOffset)

        let shifted = try #require(controller.slotTopLeftForTesting(id: "a"))
        #expect(shifted.x == baseline.x + dragOffset.dx)
        #expect(shifted.y == baseline.y + dragOffset.dy)
        #expect(controller.userColumnDragOffsetForTesting == dragOffset)
    }

    /// The idle badge's laid-out slot origin shifts by exactly the applied drag offset.
    @Test func badgeSlotOriginShiftsByTheDragOffset() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        defer { controller.hide() }
        controller.show()

        let baseline = controller.slotTopLeftForTesting
        let dragOffset = CGVector(dx: -60, dy: 140)
        controller.applyUserColumnDragOffset(dragOffset)

        let shifted = controller.slotTopLeftForTesting
        #expect(shifted.x == baseline.x + dragOffset.dx)
        #expect(shifted.y == baseline.y + dragOffset.dy)
        #expect(controller.userColumnDragOffsetForTesting == dragOffset)
    }
}

// MARK: - Real-path central sync + persistence through the manager

@MainActor
struct ResearchOverlayDragPersistenceTests {

    private func makeTempDefaults() -> UserDefaults {
        let suiteName = "clawdy-drag-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeManager(userDefaults: UserDefaults) -> ResearchSessionManager {
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drag-manifest-\(UUID().uuidString).json")
        return ResearchSessionManager(
            resolveClaudeBinaryPath: { "/usr/bin/true" },
            manifestStore: ResearchManifestStore(fileURL: manifestURL),
            testAnchorOriginOffset: offscreenResearchAnchorOffset,
            userDefaults: userDefaults
        )
    }

    /// A drag reported by one surface is stored to UserDefaults AND synced to BOTH the toast
    /// stack and the idle badge (only one is ever on screen, but the hidden one adopts it too).
    @Test func draggingPersistsAndSyncsToBothSurfaces() {
        let userDefaults = makeTempDefaults()
        let manager = makeManager(userDefaults: userDefaults)
        defer { manager.stopAll() }

        // Simulate a live drag reported by the toast-stack controller.
        let draggedOffset = CGVector(dx: 90, dy: -40)
        manager.stackedOverlayForTesting.onUserColumnDragged?(draggedOffset)

        // Persisted to UserDefaults under the new key.
        let persisted = userDefaults.vector(forKey: .researchOverlayDragOffset)
        #expect(persisted?.dx == draggedOffset.dx)
        #expect(persisted?.dy == draggedOffset.dy)

        // Synced to BOTH controllers.
        #expect(manager.stackedOverlayForTesting.userColumnDragOffsetForTesting == draggedOffset)
        #expect(manager.recentsBadgeControllerForTesting.userColumnDragOffsetForTesting == draggedOffset)
    }

    /// A persisted offset is restored into both surfaces when a new manager is constructed
    /// (so a moved position survives relaunch), and restoring does NOT re-persist a change.
    @Test func aPersistedOffsetIsRestoredOnRelaunch() {
        let userDefaults = makeTempDefaults()
        let savedOffset = CGVector(dx: 210, dy: -150)
        userDefaults.set(savedOffset, forKey: .researchOverlayDragOffset)

        let manager = makeManager(userDefaults: userDefaults)
        defer { manager.stopAll() }

        #expect(manager.stackedOverlayForTesting.userColumnDragOffsetForTesting == savedOffset)
        #expect(manager.recentsBadgeControllerForTesting.userColumnDragOffsetForTesting == savedOffset)
        // Still exactly the saved value — restore is not a change and must not rewrite it.
        let stillPersisted = userDefaults.vector(forKey: .researchOverlayDragOffset)
        #expect(stillPersisted?.dx == savedOffset.dx)
        #expect(stillPersisted?.dy == savedOffset.dy)
    }
}
