//
//  ScreenshotRulers.swift
//  Clawdy
//
//  Adds a coordinate RULER along the top and left edges of a screenshot before it goes
//  to the model: a 20-px band outside the screen content with tick marks every 50 px
//  and numbers every 100 px. Vision models are poor at absolute pixel estimates on a
//  bare image (a road traced at x≈400 came back as x≈630); a visible scale gives every
//  [POINT] coordinate a reference. The band is OUTSIDE the content — nothing on the
//  user's screen is covered — and the model answers in the ruler-inclusive image space,
//  so `contentPoint(fromImagePoint:)` strips the margin before the screen mapping.
//

import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotRulers {
    /// Width of the ruler band, in pixels, on the top and left edges.
    static let marginPixels = 20
    static let minorTickEveryPixels = 50
    static let labelEveryPixels = 100

    enum RulerError: Error { case decode, context, encode }

    /// The ruled image and its new dimensions (content + margin on each of two edges).
    struct Result {
        let imageData: Data
        let widthInPixels: Int
        let heightInPixels: Int
    }

    /// Converts a coordinate the model gave in the RULED image back to content pixels.
    static func contentPoint(fromImagePoint imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imagePoint.x - CGFloat(marginPixels), y: imagePoint.y - CGFloat(marginPixels))
    }

    /// The reverse: a content pixel expressed in the ruled image (for describing strokes).
    static func imagePoint(fromContentPoint contentPoint: CGPoint) -> CGPoint {
        CGPoint(x: contentPoint.x + CGFloat(marginPixels), y: contentPoint.y + CGFloat(marginPixels))
    }

    static func addRulers(toJPEG imageData: Data, contentWidth: Int, contentHeight: Int, jpegQuality: CGFloat) throws -> Result {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let baseImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RulerError.decode }
        let margin = marginPixels
        let width = contentWidth + margin
        let height = contentHeight + margin
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RulerError.context }

        // Ruler band: white, with the content blitted upright to its bottom-right.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Bottom-left-origin context: the content sits at x = margin, y = 0..contentHeight
        // (the ruler band along the TOP is the strip y ∈ [contentHeight, height)).
        context.draw(baseImage, in: CGRect(x: margin, y: 0, width: contentWidth, height: contentHeight))

        // Ticks and labels, drawn in a top-left pixel space via a flipped CTM.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        context.setLineWidth(1)

        // Border lines separating the bands from the content.
        context.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(width) - 1, height: CGFloat(height) - 1))
        context.move(to: CGPoint(x: CGFloat(margin), y: 0)); context.addLine(to: CGPoint(x: CGFloat(margin), y: CGFloat(height))); context.strokePath()
        context.move(to: CGPoint(x: 0, y: CGFloat(margin))); context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(margin))); context.strokePath()

        for contentX in stride(from: 0, through: contentWidth, by: minorTickEveryPixels) {
            let x = CGFloat(margin + contentX)
            let isLabeled = contentX % labelEveryPixels == 0
            let tickLength: CGFloat = isLabeled ? 8 : 4
            context.move(to: CGPoint(x: x, y: CGFloat(margin) - tickLength)); context.addLine(to: CGPoint(x: x, y: CGFloat(margin))); context.strokePath()
            if isLabeled { drawLabel("\(contentX + margin)", at: CGPoint(x: x + 2, y: 3), in: context) }
        }
        for contentY in stride(from: 0, through: contentHeight, by: minorTickEveryPixels) {
            let y = CGFloat(margin + contentY)
            let isLabeled = contentY % labelEveryPixels == 0
            let tickLength: CGFloat = isLabeled ? 8 : 4
            context.move(to: CGPoint(x: CGFloat(margin) - tickLength, y: y)); context.addLine(to: CGPoint(x: CGFloat(margin), y: y)); context.strokePath()
            if isLabeled { drawLabel("\(contentY + margin)", at: CGPoint(x: 1, y: y + 2), in: context, vertical: true) }
        }

        guard let ruled = context.makeImage() else { throw RulerError.context }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { throw RulerError.encode }
        CGImageDestinationAddImage(destination, ruled, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RulerError.encode }
        return Result(imageData: output as Data, widthInPixels: width, heightInPixels: height)
    }

    /// Tiny 3×5 block digits, drawn as rectangles — no text APIs, so the output is
    /// identical on every machine (and legible to the model at 800 px).
    private static func drawLabel(_ text: String, at origin: CGPoint, in context: CGContext, vertical: Bool = false) {
        let glyphs: [Character: [String]] = [
            "0": ["111","101","101","101","111"], "1": ["010","110","010","010","111"],
            "2": ["111","001","111","100","111"], "3": ["111","001","111","001","111"],
            "4": ["101","101","111","001","001"], "5": ["111","100","111","001","111"],
            "6": ["111","100","111","101","111"], "7": ["111","001","001","001","001"],
            "8": ["111","101","111","101","111"], "9": ["111","101","111","001","111"],
        ]
        let pixel: CGFloat = 2
        var cursorX = origin.x
        var cursorY = origin.y
        for character in text {
            guard let rows = glyphs[character] else { continue }
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, bit) in row.enumerated() where bit == "1" {
                    context.fill(CGRect(x: cursorX + CGFloat(columnIndex) * pixel, y: cursorY + CGFloat(rowIndex) * pixel, width: pixel, height: pixel))
                }
            }
            if vertical { cursorY += 6 * pixel } else { cursorX += 4 * pixel }
        }
    }
}
