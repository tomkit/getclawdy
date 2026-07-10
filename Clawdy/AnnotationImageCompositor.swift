//
//  AnnotationImageCompositor.swift
//  Clawdy
//
//  Pure, headless CoreGraphics helper that burns freehand annotation strokes
//  into a screenshot's JPEG data. No AppKit or SwiftUI dependencies so it is
//  fully unit-testable without a live display.
//
//  Coordinate transform (display-point → screenshot-pixel):
//    The strokes are stored in display-point space: AppKit logical coords,
//    NSScreen.frame-relative, bottom-left origin, y increasing upward.
//    The screenshot JPEG uses image (top-left) coordinates.
//
//    pixelX = appKitX  * screenshotWidthInPixels  / displayWidthInPoints
//    pixelY = screenshotHeightInPixels
//           - (appKitY * screenshotHeightInPixels / displayHeightInPoints)
//
//  The base screenshot is blitted upright in the default (bottom-left origin)
//  context; the CTM is then flipped so ONLY the vector stroke drawing works in
//  top-left pixel coordinates matching the JPEG's row layout. (A raster blit
//  inverts under a flipped CTM, so the base image must be drawn before the flip.)
//

import CoreGraphics
import Foundation
import ImageIO

enum AnnotationCompositorError: Error {
    case failedToDecodeImage
    case failedToCreateContext
    case failedToCreateComposedImage
    case failedToEncodeJPEG
}

enum AnnotationImageCompositor {

    /// The OpenClaw red stroke color components (r, g, b) for CGContext, DERIVED from the
    /// single brand-red source of truth in the design system
    /// (`DS.Colors.openClawRedComponents`, parsed from `DS.Colors.openClawRedHex` =
    /// #E5342B) rather than parallel literals — so changing the brand hex in ONE place
    /// updates both the SwiftUI accent and this composited stroke together. MUST stay
    /// identical to the live on-screen stroke (`AnnotationOverlayView` uses
    /// `DS.Colors.openClawRed`) so the model sees the exact color the user drew.
    private static let openClawRedRed:   CGFloat = CGFloat(DS.Colors.openClawRedComponents.red)
    private static let openClawRedGreen: CGFloat = CGFloat(DS.Colors.openClawRedComponents.green)
    private static let openClawRedBlue:  CGFloat = CGFloat(DS.Colors.openClawRedComponents.blue)

    /// Burns `strokes` drawn in display-point space into `capture`'s JPEG data.
    ///
    /// - Parameters:
    ///   - capture: The screenshot to annotate. Its geometry fields (`displayWidth/
    ///     HeightInPoints`, `screenshotWidth/HeightInPixels`) drive the coordinate
    ///     transform.
    ///   - strokes: Freehand strokes in display-point space (AppKit logical,
    ///     NSScreen.frame-relative, bottom-left origin). Only strokes with ≥ 2
    ///     points contribute a visible line.
    ///   - lineWidthPx: Stroke width in screenshot pixels.
    ///   - jpegQuality: JPEG recompression quality (0…1). Defaults to the same
    ///     value the capture pipeline uses (0.5).
    ///
    /// - Returns: Re-JPEG-encoded `Data` with the strokes burned in, or the
    ///   original `capture.imageData` unchanged when `strokes` is empty.
    ///
    /// - Throws: `AnnotationCompositorError` if image decoding, context creation,
    ///   or JPEG encoding fails.
    static func composite(
        capture: CompanionScreenCapture,
        strokes: [AnnotationStroke],
        lineWidthPx: CGFloat,
        jpegQuality: CGFloat = 0.5
    ) throws -> Data {
        // Short-circuit: if there are no strokes, return the original data unchanged.
        guard !strokes.isEmpty else { return capture.imageData }

        // STEP 1: Decode the screenshot JPEG to a CGImage.
        guard let imageSource = CGImageSourceCreateWithData(capture.imageData as CFData, nil),
              let baseImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw AnnotationCompositorError.failedToDecodeImage
        }

        let pixelWidth  = capture.screenshotWidthInPixels
        let pixelHeight = capture.screenshotHeightInPixels

        // STEP 2: Create a CGContext at the screenshot's pixel dimensions using sRGB.
        let sRGBColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGBColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationCompositorError.failedToCreateContext
        }

        // STEP 3: Draw the base screenshot UPRIGHT in the default (unflipped,
        // bottom-left origin) context. A raster blit inverts under a y-flipped
        // CTM, so the base image must be drawn BEFORE the flip below — otherwise
        // the composited JPEG comes out vertically mirrored.
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Now flip the CTM so the subsequent STROKE drawing uses top-left pixel
        // coordinates matching the JPEG's natural row layout. Only the vector
        // stroke paths (drawn below) are placed in this flipped, top-left space;
        // the raster base image was already blitted upright above (raster blits
        // invert under a flipped CTM, vector strokes do not).
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        // STEP 4: Configure stroke appearance — OpenClaw red, rounded caps/joins.
        context.setStrokeColor(red: openClawRedRed, green: openClawRedGreen, blue: openClawRedBlue, alpha: 1.0)
        context.setLineWidth(lineWidthPx)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let displayWidthInPoints  = CGFloat(capture.displayWidthInPoints)
        let displayHeightInPoints = CGFloat(capture.displayHeightInPoints)
        let screenshotWidthPx     = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeightPx    = CGFloat(capture.screenshotHeightInPixels)

        // STEP 5: Draw each stroke using the display-point → screenshot-pixel transform.
        for stroke in strokes {
            // Require at least two points for a visible line segment.
            guard stroke.points.count >= 2 else { continue }

            context.beginPath()
            for (pointIndex, appKitDisplayRelativePoint) in stroke.points.enumerated() {
                // Scale x proportionally to the screenshot's pixel width.
                let pixelX = appKitDisplayRelativePoint.x * screenshotWidthPx / displayWidthInPoints

                // Flip y: AppKit display-relative coords have bottom-left origin
                // (y increases upward). The flipped CGContext uses top-left origin
                // (y increases downward), so we subtract from the image height.
                let pixelY = screenshotHeightPx
                    - (appKitDisplayRelativePoint.y * screenshotHeightPx / displayHeightInPoints)

                let pixelPoint = CGPoint(x: pixelX, y: pixelY)
                if pointIndex == 0 {
                    context.move(to: pixelPoint)
                } else {
                    context.addLine(to: pixelPoint)
                }
            }
            context.strokePath()
        }

        // STEP 6: Extract the composed CGImage from the context.
        guard let composedImage = context.makeImage() else {
            throw AnnotationCompositorError.failedToCreateComposedImage
        }

        // STEP 7: Re-encode as JPEG at the requested quality.
        let mutableOutputData = NSMutableData()
        guard let jpegDestination = CGImageDestinationCreateWithData(
            mutableOutputData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw AnnotationCompositorError.failedToEncodeJPEG
        }
        let compressionOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(jpegDestination, composedImage, compressionOptions as CFDictionary)
        guard CGImageDestinationFinalize(jpegDestination) else {
            throw AnnotationCompositorError.failedToEncodeJPEG
        }

        return mutableOutputData as Data
    }
}
