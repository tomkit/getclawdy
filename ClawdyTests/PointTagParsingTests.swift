//
//  PointTagParsingTests.swift
//  ClawdyTests
//
//  Tests for the [POINT:x,y:label:screenN] / [POINT:none] tag parser. This is
//  the protocol the CLI engines must keep emitting through, so it is covered
//  independently of which engine produced the text.
//

import Testing
import Foundation
import CoreGraphics
@testable import Clawdy

@MainActor
struct PointTagParsingTests {

    @Test func parsesSingleCoordinateWithLabel() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "you'll want the run button up top. [POINT:285,11:run button]"
        )

        #expect(result.spokenText == "you'll want the run button up top.")
        #expect(result.points.count == 1)
        #expect(result.points.first?.coordinate == CGPoint(x: 285, y: 11))
        #expect(result.points.first?.elementLabel == "run button")
        #expect(result.points.first?.screenNumber == nil)
    }

    @Test func parsesSingleCoordinateWithLabelAndScreenNumber() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "that's on your other monitor. [POINT:400,300:terminal:screen2]"
        )

        #expect(result.points.count == 1)
        #expect(result.points.first?.coordinate == CGPoint(x: 400, y: 300))
        #expect(result.points.first?.elementLabel == "terminal")
        #expect(result.points.first?.screenNumber == 2)
    }

    @Test func parsesNoneTagStripsItAndReturnsNoPoints() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "html is the skeleton of a web page. [POINT:none]"
        )

        #expect(result.spokenText == "html is the skeleton of a web page.")
        #expect(result.points.isEmpty)
    }

    @Test func returnsFullTextAndNoPointsWhenNoTagPresent() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "just a plain answer with no tag"
        )

        #expect(result.spokenText == "just a plain answer with no tag")
        #expect(result.points.isEmpty)
    }

    // MARK: - Multi-point sequences

    /// The core of this feature: several inline tags parse into an ORDERED array,
    /// each carrying its coordinate, label, screen, AND the character offset of the
    /// tag within the original response text (retained for the later audio-sync
    /// stage). The spoken text has every tag stripped.
    @Test func parsesMultipleInlineTagsInOrderWithOffsets() {
        let response = "click source control [POINT:285,11:source control] then hit commit [POINT:180,540:commit button] to save."
        let result = CompanionManager.parsePointingCoordinates(from: response)

        // No tag is ever left in the spoken text.
        #expect(!result.spokenText.contains("[POINT:"))
        #expect(result.spokenText == "click source control  then hit commit  to save.")

        // Two points, in the order the model emitted them.
        #expect(result.points.count == 2)
        #expect(result.points[0].coordinate == CGPoint(x: 285, y: 11))
        #expect(result.points[0].elementLabel == "source control")
        #expect(result.points[1].coordinate == CGPoint(x: 180, y: 540))
        #expect(result.points[1].elementLabel == "commit button")

        // Character offsets point at each tag's opening '[' in the ORIGINAL text,
        // and are strictly increasing (first tag earlier than the second).
        let firstTagOffset = (response as NSString).range(of: "[POINT:285").location
        let secondTagOffset = (response as NSString).range(of: "[POINT:180").location
        #expect(result.points[0].characterOffset == firstTagOffset)
        #expect(result.points[1].characterOffset == secondTagOffset)
        #expect(result.points[0].characterOffset < result.points[1].characterOffset)
    }

    /// A three-point flow that mixes a `:screenN` tag proves order and screen
    /// numbers are preserved across the whole sequence.
    @Test func parsesThreePointSequenceAcrossScreens() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "run it [POINT:40,11:run button], open product [POINT:210,11:product menu], archive from there [POINT:230,180:archive:screen2]."
        )

        #expect(result.points.count == 3)
        #expect(result.points.map(\.elementLabel) == ["run button", "product menu", "archive"])
        #expect(result.points[0].screenNumber == nil)
        #expect(result.points[2].screenNumber == 2)
        // Offsets are strictly increasing in emission order.
        #expect(result.points[0].characterOffset < result.points[1].characterOffset)
        #expect(result.points[1].characterOffset < result.points[2].characterOffset)
    }

    /// A [POINT:none] mixed in among real tags is stripped but contributes no
    /// target (defensive — the model shouldn't do this, but we must not crash or
    /// emit a bogus point).
    @Test func noneTagAmongRealTagsIsStrippedButAddsNoPoint() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "here [POINT:10,20:a] and nothing useful [POINT:none] and there [POINT:30,40:b]"
        )
        #expect(result.points.count == 2)
        #expect(result.points.map(\.elementLabel) == ["a", "b"])
        #expect(!result.spokenText.contains("[POINT:"))
    }

    // MARK: - POINT → blue-cursor targeting

    /// The seam that drives the blue cursor: a parsed [POINT:x,y] coordinate (in the
    /// screenshot's top-left pixel space) must map to the correct GLOBAL AppKit
    /// screen location (bottom-left origin) that `detectedElementScreenLocation` is
    /// set to and `OverlayWindow`/`BlueCursorView` flies to. This guards the
    /// quick-answer POINT → blue-cursor path against a coordinate-mapping regression
    /// (the visible flight itself needs a live screen, but the target math does not).
    @Test func pointCoordinateMapsToTheCorrectGlobalCursorLocationOnThePrimaryScreen() {
        // A 800x500 screenshot of a 1600x1000-point primary display at the origin.
        // The model points at the exact center of the screenshot (400,250).
        let global = CompanionManager.mapScreenshotPointToGlobalScreenLocation(
            screenshotPoint: CGPoint(x: 400, y: 250),
            screenshotWidthInPixels: 800,
            screenshotHeightInPixels: 500,
            displayWidthInPoints: 1600,
            displayHeightInPoints: 1000,
            displayFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        // Center scales to display point (800,500); flipping the y-axis to AppKit's
        // bottom-left origin gives y = 1000 - 500 = 500. Origin is (0,0), so global
        // is (800,500).
        #expect(global == CGPoint(x: 800, y: 500))
    }

    /// A POINT on a SECONDARY display must land on that display: the mapping adds the
    /// display's global frame origin, so the cursor points at the right monitor
    /// (the multi-monitor `:screenN` case). Regressing the origin offset would send
    /// the cursor to the wrong screen — a real bug this locks down.
    @Test func pointCoordinateMapsOntoASecondaryScreensGlobalFrame() {
        // Top-left of a 1000x800-point display whose global origin is (1600, 200).
        let global = CompanionManager.mapScreenshotPointToGlobalScreenLocation(
            screenshotPoint: CGPoint(x: 0, y: 0),
            screenshotWidthInPixels: 500,
            screenshotHeightInPixels: 400,
            displayWidthInPoints: 1000,
            displayHeightInPoints: 800,
            displayFrame: CGRect(x: 1600, y: 200, width: 1000, height: 800)
        )
        // Screenshot top-left (0,0) → display-local (0,0) → AppKit-local (0, 800) →
        // global (1600 + 0, 200 + 800) = (1600, 1000).
        #expect(global == CGPoint(x: 1600, y: 1000))
    }

    /// Out-of-range coordinates are clamped to the screenshot bounds so the cursor
    /// always lands ON the target display rather than flying off-screen (which would
    /// read as "the cursor never appeared").
    @Test func pointCoordinateIsClampedToScreenshotBoundsSoTheCursorStaysOnScreen() {
        let global = CompanionManager.mapScreenshotPointToGlobalScreenLocation(
            screenshotPoint: CGPoint(x: 99999, y: -50),
            screenshotWidthInPixels: 800,
            screenshotHeightInPixels: 500,
            displayWidthInPoints: 1600,
            displayHeightInPoints: 1000,
            displayFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        // x clamps to 800 → display-local 1600 (right edge). y clamps to 0 → AppKit
        // y = 1000 (top edge). Both remain within the display frame.
        #expect(global == CGPoint(x: 1600, y: 1000))
    }

    // MARK: - Ordered pointing-sequence walk

    /// The pure walk decision: from any index below the last, ADVANCE to the next
    /// index; at (or past) the last target, RETURN to the cursor. This is the logic
    /// the overlay uses to walk targets in order and then fly back after the last.
    @Test func pointingSequenceStepAdvancesThenReturnsAtTheEnd() {
        // A 3-target sequence: 0→1, 1→2, then 2→return.
        #expect(nextPointingSequenceStep(currentIndex: 0, targetCount: 3) == .advance(toIndex: 1))
        #expect(nextPointingSequenceStep(currentIndex: 1, targetCount: 3) == .advance(toIndex: 2))
        #expect(nextPointingSequenceStep(currentIndex: 2, targetCount: 3) == .returnToCursor)
        // A single target immediately returns to the cursor after its dwell.
        #expect(nextPointingSequenceStep(currentIndex: 0, targetCount: 1) == .returnToCursor)
    }

    /// `beginPointingSequence` starts on target 0, `advanceToNextPointingTarget`
    /// walks the queue in order, stops advancing past the last target, and
    /// `clearDetectedElementLocation` ends the sequence. This is the manager-side
    /// state the overlay observes to drive (and hand off) the walk.
    @Test func managerWalksPointingTargetsInOrderAndStopsAtTheEnd() {
        let manager = CompanionManager()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let targets = [
            CompanionManager.DetectedElementTarget(screenLocation: CGPoint(x: 1, y: 1), displayFrame: frame, elementLabel: "a"),
            CompanionManager.DetectedElementTarget(screenLocation: CGPoint(x: 2, y: 2), displayFrame: frame, elementLabel: "b"),
            CompanionManager.DetectedElementTarget(screenLocation: CGPoint(x: 3, y: 3), displayFrame: frame, elementLabel: "c"),
        ]

        #expect(manager.isPointingSequenceActive == false)

        manager.beginPointingSequence(targets)
        #expect(manager.currentPointingTargetIndex == 0)
        #expect(manager.isPointingSequenceActive == true)
        #expect(manager.currentPointingTarget?.elementLabel == "a")

        manager.advanceToNextPointingTarget()
        #expect(manager.currentPointingTargetIndex == 1)
        #expect(manager.currentPointingTarget?.elementLabel == "b")

        manager.advanceToNextPointingTarget()
        #expect(manager.currentPointingTargetIndex == 2)
        #expect(manager.currentPointingTarget?.elementLabel == "c")

        // Advancing past the last target is a no-op (the overlay flies back instead).
        manager.advanceToNextPointingTarget()
        #expect(manager.currentPointingTargetIndex == 2)

        manager.clearDetectedElementLocation()
        #expect(manager.currentPointingTargetIndex == nil)
        #expect(manager.isPointingSequenceActive == false)
        #expect(manager.currentPointingTarget == nil)
    }

    /// An empty target list clears pointing rather than starting an inert sequence.
    @Test func beginningAnEmptySequenceClearsPointing() {
        let manager = CompanionManager()
        manager.beginPointingSequence([])
        #expect(manager.currentPointingTargetIndex == nil)
        #expect(manager.detectedElementTargets.isEmpty)
    }
}
