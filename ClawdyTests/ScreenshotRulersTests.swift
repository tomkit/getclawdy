//
//  ScreenshotRulersTests.swift
//  ClawdyTests
//
//  The coordinate rulers added to every screenshot before it reaches the model, and
//  the stroke-path description: both exist so the model's [POINT] coordinates come from
//  a printed scale (or a given path) rather than a visual estimate.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Clawdy

struct ScreenshotRulersTests {
    private func solidJPEG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func pixel(_ data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = ((image.height - 1 - y) * image.width + x) * 4   // top-left pixel coordinates
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    @Test func rulersAddAMarginOutsideTheContentAndTheMappingStripsIt() throws {
        let ruled = try ScreenshotRulers.addRulers(toJPEG: solidJPEG(width: 800, height: 450), contentWidth: 800, contentHeight: 450, jpegQuality: 0.9)
        let margin = ScreenshotRulers.marginPixels
        #expect(ruled.widthInPixels == 800 + margin)
        #expect(ruled.heightInPixels == 450 + margin)
        // The band is light (ruler), the content is untouched blue just inside it.
        let band = pixel(ruled.imageData, x: 4, y: 12)
        #expect(band.r > 200 && band.g > 200 && band.b > 200)
        let content = pixel(ruled.imageData, x: margin + 40, y: margin + 40)
        #expect(content.b > 180 && content.r < 80)
        // A model coordinate in the ruled image maps back to content pixels by the margin.
        #expect(ScreenshotRulers.contentPoint(fromImagePoint: CGPoint(x: 420, y: 160)) == CGPoint(x: 400, y: 140))
        #expect(ScreenshotRulers.imagePoint(fromContentPoint: CGPoint(x: 400, y: 140)) == CGPoint(x: 420, y: 160))
    }

    @MainActor @Test func strokeDescriptionListsEachPathInRuledImagePixels() {
        let capture = CompanionScreenCapture(
            imageData: Data(), label: "screen 1", isCursorScreen: true,
            displayWidthInPoints: 1920, displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 800, screenshotHeightInPixels: 450
        )
        // Display-relative AppKit points (bottom-left origin): (960, 540) is the center.
        let stroke = AnnotationStroke(displayIndex: 0, points: [CGPoint(x: 960, y: 540), CGPoint(x: 1920, y: 1080)])
        let description = CompanionManager.describeAnnotationStrokes([stroke], in: capture)
        // Center → content (400,225) → ruled (420,245); top-right corner → content (800,0) → ruled (820,20).
        #expect(description.contains("stroke 1: (420,245) → (820,20)"), Comment(rawValue: description))
        #expect(CompanionManager.describeAnnotationStrokes([AnnotationStroke(displayIndex: 0, points: [CGPoint(x: 1, y: 1)])], in: capture).isEmpty, "a click is not a stroke")
    }
}
