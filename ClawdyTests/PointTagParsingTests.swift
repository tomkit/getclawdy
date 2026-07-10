//
//  PointTagParsingTests.swift
//  ClawdyTests
//
//  Tests for the [POINT:x,y:label:screenN] / [POINT:none] tag parser. This is
//  the protocol the CLI engines must keep emitting through, so it is covered
//  independently of which engine produced the text.
//

import Testing
import CoreGraphics
@testable import Clawdy

@MainActor
struct PointTagParsingTests {

    @Test func parsesCoordinateWithLabel() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "you'll want the run button up top. [POINT:285,11:run button]"
        )

        #expect(result.spokenText == "you'll want the run button up top.")
        #expect(result.coordinate == CGPoint(x: 285, y: 11))
        #expect(result.elementLabel == "run button")
        #expect(result.screenNumber == nil)
    }

    @Test func parsesCoordinateWithLabelAndScreenNumber() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "that's on your other monitor. [POINT:400,300:terminal:screen2]"
        )

        #expect(result.coordinate == CGPoint(x: 400, y: 300))
        #expect(result.elementLabel == "terminal")
        #expect(result.screenNumber == 2)
    }

    @Test func parsesNoneTagStripsItAndReturnsNoCoordinate() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "html is the skeleton of a web page. [POINT:none]"
        )

        #expect(result.spokenText == "html is the skeleton of a web page.")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
    }

    @Test func returnsFullTextWhenNoTagPresent() {
        let result = CompanionManager.parsePointingCoordinates(
            from: "just a plain answer with no tag"
        )

        #expect(result.spokenText == "just a plain answer with no tag")
        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
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
}
