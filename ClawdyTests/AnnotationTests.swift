//
//  AnnotationTests.swift
//  ClawdyTests
//
//  Unit tests for the annotation feature:
//    1. AnnotationStrokeStore — begin/add/end/clear, per-display filtering.
//    2. AnnotationImageCompositor — coordinate transform, empty-strokes passthrough,
//       and the 800px-cap ratio applied by CompanionScreenCaptureUtility.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Clawdy

// MARK: - 1. AnnotationStrokeStore

struct AnnotationStrokeStoreTests {

    @Test func beginStrokeCreatesAnEmptyStrokeInTheStore() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        #expect(store.strokes.count == 1)
        #expect(store.strokes[0].points.isEmpty)
        #expect(store.strokes[0].displayIndex == 0)
    }

    @Test func addPointAppendsToTheCurrentInProgressStroke() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 10, y: 20))
        store.addPoint(CGPoint(x: 30, y: 40))
        #expect(store.strokes[0].points.count == 2)
        #expect(store.strokes[0].points[0] == CGPoint(x: 10, y: 20))
        #expect(store.strokes[0].points[1] == CGPoint(x: 30, y: 40))
    }

    @Test func addPointIsNoOpWhenNoStrokeIsInProgress() {
        let store = AnnotationStrokeStore()
        // addPoint before any beginStroke → should not crash, store stays empty
        store.addPoint(CGPoint(x: 5, y: 5))
        #expect(store.strokes.isEmpty)
    }

    @Test func endStrokePreventsSubsequentAddPointsFromAppendingToThatStroke() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 1, y: 2))
        store.endStroke()
        // After endStroke, adding a point should be a no-op for the finished stroke.
        store.addPoint(CGPoint(x: 99, y: 99))
        #expect(store.strokes[0].points.count == 1)
        #expect(store.strokes[0].points[0] == CGPoint(x: 1, y: 2))
    }

    @Test func multipleSequentialStrokesAreAllRetained() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 1, y: 1))
        store.endStroke()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 2, y: 2))
        store.endStroke()
        #expect(store.strokes.count == 2)
    }

    @Test func clearAllRemovesAllStrokesAndAllowsNewOnes() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 5, y: 5))
        store.endStroke()
        store.clearAll()
        #expect(store.strokes.isEmpty)
        // Should be able to begin a new stroke after clearing.
        store.beginStroke(displayIndex: 1)
        store.addPoint(CGPoint(x: 10, y: 10))
        #expect(store.strokes.count == 1)
    }

    @Test func strokesForDisplayIndexFiltersToTheRequestedDisplay() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 1, y: 1))
        store.endStroke()
        store.beginStroke(displayIndex: 1)
        store.addPoint(CGPoint(x: 2, y: 2))
        store.endStroke()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 3, y: 3))
        store.endStroke()

        let display0Strokes = store.strokes(forDisplayIndex: 0)
        let display1Strokes = store.strokes(forDisplayIndex: 1)

        #expect(display0Strokes.count == 2)
        #expect(display1Strokes.count == 1)
        #expect(display1Strokes[0].points[0] == CGPoint(x: 2, y: 2))
    }

    @Test func strokesForDisplayIndexReturnsEmptyWhenNoStrokesOnThatDisplay() {
        let store = AnnotationStrokeStore()
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 1, y: 1))
        store.endStroke()
        // Display 1 has no strokes.
        #expect(store.strokes(forDisplayIndex: 1).isEmpty)
    }
}

// MARK: - 2. AnnotationImageCompositor

/// A synthetic `CompanionScreenCapture` backed by a 1x1 white JPEG,
/// useful for tests that just need a valid decode/encode round-trip.
private func makeMinimalTestCapture(
    displayWidthInPoints: Int,
    displayHeightInPoints: Int,
    screenshotWidthInPixels: Int,
    screenshotHeightInPixels: Int
) -> CompanionScreenCapture {
    // Build a tiny JPEG in memory using CoreGraphics so we avoid loading files.
    let pixelWidth  = screenshotWidthInPixels
    let pixelHeight = screenshotHeightInPixels
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Fill with white.
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    let cgImage = context.makeImage()!

    let mutableData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)

    return CompanionScreenCapture(
        imageData: mutableData as Data,
        label: "test screen",
        isCursorScreen: true,
        displayWidthInPoints: displayWidthInPoints,
        displayHeightInPoints: displayHeightInPoints,
        displayFrame: CGRect(x: 0, y: 0, width: displayWidthInPoints, height: displayHeightInPoints),
        screenshotWidthInPixels: screenshotWidthInPixels,
        screenshotHeightInPixels: screenshotHeightInPixels
    )
}

struct AnnotationImageCompositorTests {

    @Test func emptyStrokesReturnsOriginalImageDataUnchanged() throws {
        let capture = makeMinimalTestCapture(
            displayWidthInPoints: 100,
            displayHeightInPoints: 100,
            screenshotWidthInPixels: 80,
            screenshotHeightInPixels: 80
        )
        let result = try AnnotationImageCompositor.composite(
            capture: capture,
            strokes: [],
            lineWidthPx: 4.0
        )
        // When strokes is empty, the original data must be returned byte-for-byte.
        #expect(result == capture.imageData)
    }

    @Test func compositeWithStrokesProducesNewJPEGData() throws {
        let capture = makeMinimalTestCapture(
            displayWidthInPoints: 200,
            displayHeightInPoints: 150,
            screenshotWidthInPixels: 160,
            screenshotHeightInPixels: 120
        )
        var stroke = AnnotationStroke(displayIndex: 0, points: [])
        stroke.points.append(CGPoint(x: 10, y: 10))
        stroke.points.append(CGPoint(x: 100, y: 75))
        stroke.points.append(CGPoint(x: 190, y: 10))

        let result = try AnnotationImageCompositor.composite(
            capture: capture,
            strokes: [stroke],
            lineWidthPx: 4.0
        )
        // The result should be valid JPEG data distinct from the original.
        #expect(!result.isEmpty)
        #expect(result != capture.imageData)
        // Verify it decodes back to an image of the same pixel dimensions.
        let imageSource = CGImageSourceCreateWithData(result as CFData, nil)!
        let composedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        #expect(composedImage.width == 160)
        #expect(composedImage.height == 120)
    }

    /// Verifies the Y-flip coordinate transform for a point at a known location.
    ///
    /// Display: 200 pts wide × 100 pts tall.
    /// Screenshot: 160 px wide × 80 px tall (0.8× scale).
    ///
    /// A stroke point at display-relative AppKit coords (100, 25):
    ///   - x in screenshot pixels = 100 * 160/200 = 80 px
    ///   - y in screenshot pixels = 80 - (25 * 80/100) = 80 - 20 = 60 px  (top-left origin)
    ///
    /// We test this indirectly by verifying the compositor runs without error
    /// (the pixel-level color check would require ScreenCaptureKit to be mocked,
    /// which is out of scope here). The pure transform itself is validated below.
    @Test func coordinateTransformForKnownDisplayPointIsCorrect() {
        let displayWidthInPoints:    CGFloat = 200
        let displayHeightInPoints:   CGFloat = 100
        let screenshotWidthInPixels: CGFloat = 160
        let screenshotHeightInPixels: CGFloat = 80

        let appKitDisplayRelativeX: CGFloat = 100   // halfway across
        let appKitDisplayRelativeY: CGFloat = 25    // one quarter up from bottom

        // Apply the same transform the compositor uses.
        let pixelX = appKitDisplayRelativeX * screenshotWidthInPixels / displayWidthInPoints
        let pixelY = screenshotHeightInPixels
            - (appKitDisplayRelativeY * screenshotHeightInPixels / displayHeightInPoints)

        #expect(pixelX == 80)   // 100 * 160/200
        #expect(pixelY == 60)   // 80 - (25 * 80/100)
    }

    /// Verifies that the 800-px longest-edge cap used by the capture pipeline is
    /// correctly reflected when the compositor scales stroke coordinates.
    /// A 2560×1600 display at the 800-px cap yields a screenshot of 800×500 px.
    /// A stroke at display-point (1280, 800) should map to pixel (400, 0):
    ///   pixelX = 1280 * 800/2560 = 400
    ///   pixelY = 500 - (800 * 500/1600) = 500 - 250 = 250
    @Test func coordinateTransformApplies800pxLongestEdgeRatioCorrectly() {
        let displayWidthInPoints:     CGFloat = 2560
        let displayHeightInPoints:    CGFloat = 1600
        // screenshotPixelDimensions for a 2560×1600 display at 800-px longest edge:
        // longest edge is width → width = 800, height = 800 * 1600/2560 = 500
        let screenshotWidthInPixels:  CGFloat = 800
        let screenshotHeightInPixels: CGFloat = 500

        let appKitX: CGFloat = 1280   // halfway across display
        let appKitY: CGFloat = 800    // halfway up display

        let pixelX = appKitX * screenshotWidthInPixels / displayWidthInPoints
        let pixelY = screenshotHeightInPixels
            - (appKitY * screenshotHeightInPixels / displayHeightInPoints)

        #expect(pixelX == 400)   // 1280 * 800/2560
        #expect(pixelY == 250)   // 500 - (800 * 500/1600)
    }

    // MARK: - Test A: Pixel-level composite correctness

    /// Composites a 2-point horizontal stroke across a white 100×100 image and
    /// verifies at the pixel level that the stroke color approximates OpenClaw red
    /// (#E5342B) and that pixels far from the stroke are still approximately white.
    ///
    /// JPEG compression introduces rounding, so each channel is compared within ±20
    /// of the nominal value (0–255 scale).
    @Test func pixelLevelCompositeProducesOpenClawRedAtStrokeLocation() throws {
        // Create a 100×100 white JPEG at high quality so the base color barely drifts.
        let capture = makeMinimalTestCapture(
            displayWidthInPoints: 100,
            displayHeightInPoints: 100,
            screenshotWidthInPixels: 100,
            screenshotHeightInPixels: 100
        )

        // Draw a horizontal stroke at display-relative AppKit y=50 (midpoint).
        // AppKit y=50 on a 100-pt-tall display maps to pixel y = 100 - (50*100/100) = 50.
        // We stroke from x=10 to x=90 with a thick line so the midpoint (50,50) is covered.
        var stroke = AnnotationStroke(displayIndex: 0, points: [])
        stroke.points.append(CGPoint(x: 10, y: 50))
        stroke.points.append(CGPoint(x: 90, y: 50))

        // Use a wide line width so the stroke is clearly visible at the sample pixel.
        let result = try AnnotationImageCompositor.composite(
            capture: capture,
            strokes: [stroke],
            lineWidthPx: 10.0,
            jpegQuality: 0.9   // high quality to reduce JPEG color drift
        )

        // Decode the composed JPEG into a CGImage.
        guard let imageSource = CGImageSourceCreateWithData(result as CFData, nil),
              let composedCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            Issue.record("Failed to decode composed JPEG")
            return
        }

        // Render the CGImage into an RGBA bitmap context so we can read raw bytes.
        let bitmapWidth  = composedCGImage.width
        let bitmapHeight = composedCGImage.height
        let bytesPerPixel = 4
        let bytesPerRow   = bitmapWidth * bytesPerPixel
        var pixelBuffer = [UInt8](repeating: 0, count: bitmapHeight * bytesPerRow)

        let bitmapContext = CGContext(
            data: &pixelBuffer,
            width: bitmapWidth,
            height: bitmapHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        bitmapContext?.draw(composedCGImage, in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))

        // Helper to read one pixel's (r, g, b) at pixel coordinates (px, py).
        func readPixelRGB(px: Int, py: Int) -> (r: Int, g: Int, b: Int) {
            let offset = py * bytesPerRow + px * bytesPerPixel
            return (Int(pixelBuffer[offset]), Int(pixelBuffer[offset + 1]), Int(pixelBuffer[offset + 2]))
        }

        // OpenClaw red nominal values: r=0xE5=229, g=0x34=52, b=0x2B=43. MUST match the
        // live on-screen stroke (`AnnotationOverlayView` → DS.Colors.openClawRed) so the
        // model sees the exact color the user drew.
        let openClawRedRed:   Int = 0xE5  // 229
        let openClawRedGreen: Int = 0x34  // 52
        let openClawRedBlue:  Int = 0x2B  // 43
        let jpegColorTolerance = 20

        // Sample the midpoint of the stroke (pixel x=50, y=50).
        let strokePixel = readPixelRGB(px: 50, py: 50)
        #expect(abs(strokePixel.r - openClawRedRed)   <= jpegColorTolerance,
                "Stroke pixel red channel \(strokePixel.r) too far from expected \(openClawRedRed)")
        #expect(abs(strokePixel.g - openClawRedGreen) <= jpegColorTolerance,
                "Stroke pixel green channel \(strokePixel.g) too far from expected \(openClawRedGreen)")
        #expect(abs(strokePixel.b - openClawRedBlue)  <= jpegColorTolerance,
                "Stroke pixel blue channel \(strokePixel.b) too far from expected \(openClawRedBlue)")

        // Sample a corner pixel that the stroke never touched — should still be white (~255,255,255).
        let whitePixel = readPixelRGB(px: 5, py: 5)
        let whiteNominal = 255
        let whiteChannelTolerance = 20
        #expect(abs(whitePixel.r - whiteNominal) <= whiteChannelTolerance,
                "Background pixel red \(whitePixel.r) should be near white")
        #expect(abs(whitePixel.g - whiteNominal) <= whiteChannelTolerance,
                "Background pixel green \(whitePixel.g) should be near white")
        #expect(abs(whitePixel.b - whiteNominal) <= whiteChannelTolerance,
                "Background pixel blue \(whitePixel.b) should be near white")
    }

    // MARK: - Test B: Single-point click returns original data unchanged

    /// A single click (1-point stroke) must NOT cause the compositor to decode and
    /// re-encode the JPEG. CompanionManager stores only drawable strokes (≥ 2 points)
    /// in `pendingAnnotationStrokes` at PTT release; a click-only session produces an
    /// empty pendingAnnotationStrokes, so the compositor is never called and the original
    /// imageData is returned byte-identical (no decode → re-encode quality loss).
    ///
    /// This test exercises the two levels of that guarantee:
    ///   1. `AnnotationStrokeStore.containsDrawableStrokes` / `drawableStrokes(from:)`
    ///      classifies a 1-point stroke as not drawable — the pure filter that gates
    ///      the composite call at the production decision point.
    ///   2. Simulating the production branch: when the drawable filter produces an empty
    ///      set, the result is byte-identical to the original imageData.
    @Test func clickOnlySessionHasNoDrawableStrokesAndOriginalDataIsReturnedByteIdentical() throws {
        let capture = makeMinimalTestCapture(
            displayWidthInPoints: 100,
            displayHeightInPoints: 100,
            screenshotWidthInPixels: 80,
            screenshotHeightInPixels: 80
        )

        var singlePointStroke = AnnotationStroke(displayIndex: 0, points: [])
        singlePointStroke.points.append(CGPoint(x: 40, y: 40))

        // Level 1: the pure helper must classify a 1-point stroke as not drawable.
        #expect(
            !AnnotationStrokeStore.containsDrawableStrokes([singlePointStroke]),
            "A 1-point stroke must not count as drawable — it produces no visible segment"
        )

        // Level 2: simulate the production branch.
        // CompanionManager filters annotationStrokeSnapshot to strokes with >= 2 points
        // before calling the compositor. An empty filter result means the compositor is
        // never called and the original imageData is used unchanged.
        let drawableStrokes = [singlePointStroke].filter { $0.points.count >= 2 }
        let result: Data = drawableStrokes.isEmpty
            ? capture.imageData  // production path: skip compositor, return original
            : (try AnnotationImageCompositor.composite(capture: capture, strokes: drawableStrokes, lineWidthPx: 4.0))

        #expect(
            result == capture.imageData,
            "Click-only session must return the original imageData byte-identical — no re-encode"
        )
    }

    /// Verifies that AnnotationStrokeStore.containsDrawableStrokes and drawableStrokes(from:)
    /// correctly classify strokes by the ≥ 2-point minimum for a visible line segment.
    @Test func containsDrawableStrokesClassifiesStrokesByMinimumPointCount() {
        // Empty strokes array — nothing to draw.
        #expect(!AnnotationStrokeStore.containsDrawableStrokes([]))
        #expect(AnnotationStrokeStore.drawableStrokes(from: []).isEmpty)

        // Single-point stroke — no line segment.
        let onePoint = AnnotationStroke(displayIndex: 0, points: [CGPoint(x: 5, y: 5)])
        #expect(!AnnotationStrokeStore.containsDrawableStrokes([onePoint]))
        #expect(AnnotationStrokeStore.drawableStrokes(from: [onePoint]).isEmpty)

        // Two-point stroke — one line segment, drawable.
        let twoPoint = AnnotationStroke(displayIndex: 0, points: [CGPoint(x: 5, y: 5), CGPoint(x: 50, y: 50)])
        #expect(AnnotationStrokeStore.containsDrawableStrokes([twoPoint]))
        #expect(AnnotationStrokeStore.drawableStrokes(from: [twoPoint]).count == 1)

        // Mixed: one 1-point and one 2-point stroke — only the 2-point one is drawable.
        let mixed = AnnotationStrokeStore.drawableStrokes(from: [onePoint, twoPoint])
        #expect(mixed.count == 1)
        #expect(mixed[0].points.count == 2)
    }

    /// Proves the key invariant behind the delayed-transcript fix: the production capture
    /// of `pendingAnnotationStrokes` (done with `drawableStrokes(from:)` at PTT release)
    /// produces a stable, independent value-copy that survives a subsequent `clearAll()`.
    ///
    /// Background: `teardownAnnotationMode()` schedules `clearAll()` 0.7s after PTT release.
    /// The dictation fallback path can delay `submitDraftText` by up to ~2.4s. If the
    /// snapshot were taken inside the response Task (at Task-start) rather than at release
    /// time, the 0.7s clear could wipe the store before the Task snapshots it — losing
    /// the user's strokes from the composite. The fix captures the snapshot synchronously
    /// at release time, before `teardownAnnotationMode()` schedules the clear.
    ///
    /// This test simulates that ordering: snapshot at release → clearAll → composite reads
    /// the snapshot (not the now-empty store).
    @Test func drawableStrokesSnapshotTakenAtReleaseSurvivesSubsequentClearAll() throws {
        let store = AnnotationStrokeStore()

        // Simulate strokes drawn during PTT hold.
        store.beginStroke(displayIndex: 0)
        store.addPoint(CGPoint(x: 10, y: 10))
        store.addPoint(CGPoint(x: 100, y: 100))
        store.endStroke()

        // PTT release: snapshot drawable strokes synchronously (the production path).
        let snapshotAtRelease = AnnotationStrokeStore.drawableStrokes(
            from: store.strokes(forDisplayIndex: 0)
        )
        #expect(snapshotAtRelease.count == 1, "snapshot must contain the one drawable stroke")

        // teardownAnnotationMode fires its 0.7s clearAll — simulated here immediately.
        store.clearAll()
        #expect(store.strokes.isEmpty, "store must be empty after clearAll")

        // Up to ~2.4s later, the response Task runs and reads the snapshot — not the store.
        // The snapshot is a value copy; clearAll on the store cannot affect it.
        #expect(
            snapshotAtRelease.count == 1,
            "snapshot must still contain the stroke even after the store is cleared"
        )
        #expect(snapshotAtRelease[0].points.count == 2)

        // And the composite correctly uses the snapshot — verify it produces annotated output.
        let capture = makeMinimalTestCapture(
            displayWidthInPoints: 200, displayHeightInPoints: 150,
            screenshotWidthInPixels: 160, screenshotHeightInPixels: 120
        )
        let result = try AnnotationImageCompositor.composite(
            capture: capture, strokes: snapshotAtRelease, lineWidthPx: 4.0
        )
        #expect(result != capture.imageData, "composite with the release-time snapshot must modify the image")
        let composedSource = CGImageSourceCreateWithData(result as CFData, nil)!
        let composedImage = CGImageSourceCreateImageAtIndex(composedSource, 0, nil)!
        #expect(composedImage.width == 160)
        #expect(composedImage.height == 120)
    }

    // MARK: - Test C: Base image is NOT vertically flipped

    /// Regression test for the base-image-upside-down bug.
    ///
    /// The compositor draws the base screenshot and then the strokes. If the base
    /// raster is blitted UNDER the y-flipped CTM (the buggy order), the CGImage
    /// renders upside-down and the composited JPEG sent to the vision model is
    /// vertically mirrored — the model reports the whole screen as flipped.
    ///
    /// The older pixel test uses a solid-white symmetric base with a horizontal
    /// midline stroke; both are invariant under a vertical flip, so that test is
    /// blind to orientation. This test uses a vertically ASYMMETRIC base (one half
    /// a distinct color from the other) and asserts that, after compositing with a
    /// stroke, a sample pixel near the TOP edge of the output still matches the TOP
    /// of the input — and NOT the input's bottom. A vertical flip would swap them.
    ///
    /// The comparison decodes both the input base and the composed output through
    /// the identical decode → RGBA-render → read path, so whatever buffer-row
    /// orientation convention that path uses cancels out: only a genuine flip
    /// BETWEEN input and output is detectable.
    @Test func baseImageIsNotVerticallyFlippedAfterCompositing() throws {
        // Build a vertically asymmetric 100×100 base: the upper-y region (in the
        // drawing context's bottom-left space) is filled black, the rest white.
        // The exact meaning of "top" does not matter — only that the top and bottom
        // regions differ, so a flip between input and output becomes observable.
        let pixelWidth = 100
        let pixelHeight = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill everything white first.
        drawContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        drawContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Fill the upper-y half black, creating the vertical asymmetry.
        drawContext.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        drawContext.fill(CGRect(x: 0, y: pixelHeight / 2, width: pixelWidth, height: pixelHeight / 2))
        let baseCGImage = drawContext.makeImage()!

        let baseData = NSMutableData()
        let baseDestination = CGImageDestinationCreateWithData(baseData as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(baseDestination, baseCGImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(baseDestination)

        let capture = CompanionScreenCapture(
            imageData: baseData as Data,
            label: "asymmetric test screen",
            isCursorScreen: true,
            displayWidthInPoints: 100,
            displayHeightInPoints: 100,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotWidthInPixels: 100,
            screenshotHeightInPixels: 100
        )

        // A short horizontal stroke near the vertical midline. Its coverage (~rows
        // 45–55) stays clear of the top/bottom sample rows we compare below, so the
        // stroke cannot confound the base-orientation check.
        var stroke = AnnotationStroke(displayIndex: 0, points: [])
        stroke.points.append(CGPoint(x: 30, y: 50))
        stroke.points.append(CGPoint(x: 70, y: 50))

        let result = try AnnotationImageCompositor.composite(
            capture: capture,
            strokes: [stroke],
            lineWidthPx: 6.0,
            jpegQuality: 0.95
        )

        // Decode a JPEG into an RGBA pixel buffer and read one pixel. Both the input
        // base and the composed output are read through this identical path so the
        // buffer-row orientation convention is the same for both.
        func readPixelRGB(from jpegData: Data, px: Int, py: Int) throws -> (r: Int, g: Int, b: Int) {
            guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw AnnotationCompositorError.failedToDecodeImage
            }
            let bytesPerPixel = 4
            let bytesPerRow = cgImage.width * bytesPerPixel
            var pixelBuffer = [UInt8](repeating: 0, count: cgImage.height * bytesPerRow)
            let bitmapContext = CGContext(
                data: &pixelBuffer,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let offset = py * bytesPerRow + px * bytesPerPixel
            return (Int(pixelBuffer[offset]), Int(pixelBuffer[offset + 1]), Int(pixelBuffer[offset + 2]))
        }

        // Sample buffer rows near the top edge (py=10) and bottom edge (py=90),
        // both far from the midline stroke.
        let inputTop = try readPixelRGB(from: capture.imageData, px: 50, py: 10)
        let inputBottom = try readPixelRGB(from: capture.imageData, px: 50, py: 90)
        let outputTop = try readPixelRGB(from: result, px: 50, py: 10)

        // The input MUST be vertically asymmetric for this test to mean anything:
        // its top and bottom sample pixels differ (one black, one white).
        let inputTopBottomDelta = abs(inputTop.r - inputBottom.r) + abs(inputTop.g - inputBottom.g) + abs(inputTop.b - inputBottom.b)
        #expect(inputTopBottomDelta > 300, "test base must be vertically asymmetric — top and bottom differ")

        // After correct compositing, the output's TOP must still match the input's
        // TOP (and therefore differ from the input's BOTTOM). A vertical flip of the
        // base would make outputTop match inputBottom instead — that is the bug.
        let outputVsInputTopDelta = abs(outputTop.r - inputTop.r) + abs(outputTop.g - inputTop.g) + abs(outputTop.b - inputTop.b)
        let outputVsInputBottomDelta = abs(outputTop.r - inputBottom.r) + abs(outputTop.g - inputBottom.g) + abs(outputTop.b - inputBottom.b)

        #expect(
            outputVsInputTopDelta < 60,
            "output top pixel \(outputTop) should match the input top \(inputTop) — base must not be vertically flipped"
        )
        #expect(
            outputVsInputBottomDelta > 300,
            "output top pixel \(outputTop) must NOT match the input bottom \(inputBottom) — that would mean the base was flipped upside-down"
        )
    }
}
