//
//  ResearchOverlayDarkSurfacePixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel verification that the research overlay toasts render on the app's DARK
//  window surface (`surface1`) with a HARD edge (no alpha halo) — the revert of the
//  short-lived Clawdy-blue overlay direction. The overlay panels are `sharingType = .none`
//  (non-capturable by design), so an external screencapture can't grab them; instead these
//  render the ACTUAL overlay SwiftUI views through a real `NSHostingView` +
//  `cacheDisplay(in:to:)`, which rasterizes the true AppKit/SwiftUI view tree unaffected by
//  the window's sharing type. The rendered pixels are then inspected:
//
//   • DARK surface: a clean fill pixel (on the surface, off the content) matches the
//     canonical `surface1` — rendered through the SAME pipeline so the comparison is
//     immune to cacheDisplay's color space — and is NOT the brand `accent`.
//   • No halo: with the pill drawn on a CLEAR background, the pixels just OUTSIDE the
//     pill's solid shape are fully transparent (alpha ≈ 0). A `.shadow()` or translucent
//     stroke would leave a soft semi-transparent ring there.
//
//  Each render is also written to `CLAWDY_PIXEL_DUMP_DIR` (when set) as a PNG so the
//  dark look + left alignment can be eyeballed.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchOverlayDarkSurfacePixelRenderTests {

    /// Transparent border (points) left around a pill so the "just outside the shape"
    /// samples land on background, not on the pill.
    private let renderPadding: CGFloat = 22

    private struct RenderedBitmap {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        func pixel(_ pointX: CGFloat, _ pointY: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(pointX * scale), y: Int(pointY * scale))?.usingColorSpace(.sRGB)
        }
    }

    /// Renders `content` at `pointSize` (its natural pill footprint plus `renderPadding`
    /// all around) on a CLEAR background via a real `NSHostingView` + `cacheDisplay`.
    private func render<Content: View>(_ content: Content, pointSize: CGSize) -> RenderedBitmap {
        let hostingView = NSHostingView(
            rootView: content
                .padding(renderPadding)
                .frame(width: pointSize.width, height: pointSize.height)
        )
        hostingView.frame = CGRect(origin: .zero, size: pointSize)

        let window = makeOffscreenRenderWindow(width: hostingView.frame.width, height: hostingView.frame.height)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            fatalError("no caching bitmap rep")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        window.orderOut(nil)

        let scale = CGFloat(rep.pixelsWide) / hostingView.bounds.width
        return RenderedBitmap(bitmap: rep, scale: scale)
    }

    private func dump(_ rendered: RenderedBitmap, named name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CLAWDY_PIXEL_DUMP_DIR"] else { return }
        guard let png = rendered.bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// A reference swatch of `color` rendered through the SAME `cacheDisplay` pipeline, so
    /// the fill comparison is apples-to-apples and immune to the caching bitmap's color
    /// space (a raw `.sRGB` conversion of the token is off by a fixed gamma shift here).
    private func referencePixel(for color: Color) -> NSColor {
        let swatch = render(
            Rectangle().fill(color),
            pointSize: CGSize(width: 40 + renderPadding * 2, height: 40 + renderPadding * 2)
        )
        return swatch.pixel(renderPadding + 20, renderPadding + 20)!
    }

    private func closeTo(_ color: NSColor, _ reference: NSColor, tolerance: CGFloat) -> Bool {
        abs(color.redComponent - reference.redComponent) < tolerance
            && abs(color.greenComponent - reference.greenComponent) < tolerance
            && abs(color.blueComponent - reference.blueComponent) < tolerance
    }

    /// The max alpha (0...1) found just OUTSIDE the pill's shape on all four sides, inside
    /// the transparent padding a few points off each edge (spanning the middle third to
    /// avoid the rounded corners). ≈ 0 with a hard edge; a soft shadow / translucent stroke
    /// would push it up into a visible halo ring.
    private func maxAlphaJustOutsideShape(_ rendered: RenderedBitmap, pillSize: CGSize) -> CGFloat {
        var maxAlpha: CGFloat = 0
        let leftX = renderPadding - 5
        let rightX = renderPadding + pillSize.width + 5
        let topY = renderPadding - 5
        let bottomY = renderPadding + pillSize.height + 5
        // Left/right strips over the pill's vertical middle third.
        var y = renderPadding + pillSize.height / 3
        while y <= renderPadding + pillSize.height * 2 / 3 {
            if let leftColor = rendered.pixel(leftX, y) { maxAlpha = max(maxAlpha, leftColor.alphaComponent) }
            if let rightColor = rendered.pixel(rightX, y) { maxAlpha = max(maxAlpha, rightColor.alphaComponent) }
            y += 1
        }
        // Top/bottom strips over the pill's horizontal middle third.
        var x = renderPadding + pillSize.width / 3
        while x <= renderPadding + pillSize.width * 2 / 3 {
            if let topColor = rendered.pixel(x, topY) { maxAlpha = max(maxAlpha, topColor.alphaComponent) }
            if let bottomColor = rendered.pixel(x, bottomY) { maxAlpha = max(maxAlpha, bottomColor.alphaComponent) }
            x += 1
        }
        return maxAlpha
    }

    private func runningMiniViewModel() -> ResearchProgressOverlayViewModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "aomori winter photos"
        viewModel.statusLine = "Searching the web…"
        viewModel.isCancellable = true
        return viewModel
    }

    private func doneExpandedViewModel() -> ResearchProgressOverlayViewModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .done
        viewModel.taskDescription = "aomori winter photos"
        viewModel.statusLine = "View results ›"
        viewModel.isCancellable = false
        return viewModel
    }

    /// The full toast (RUNNING) renders on the dark `surface1` (not the brand accent) with a
    /// hard edge. The toast's OWN surface carries no halo — the OpenClaw red aura is applied by
    /// the hosting window wrapper (`ResearchToastWindowRootView.clawdyGlow`), tested separately,
    /// not by the toast surface itself.
    @Test func runningFullToastIsDarkSurfaceWithNoHalo() {
        let pillSize = ResearchFullToastGeometry.toastSize
        let rendered = render(
            ResearchFullToastView(
                viewModel: runningMiniViewModel(),
                reduceMotionEnabled: true
            ),
            pointSize: CGSize(width: pillSize.width + renderPadding * 2,
                              height: pillSize.height + renderPadding * 2)
        )
        dump(rendered, named: "running-full-toast-dark")

        // Sample the clean top strip (above the vertically-centered content).
        let fill = rendered.pixel(renderPadding + pillSize.width / 2, renderPadding + 5)!
        let darkReference = referencePixel(for: DS.Colors.surface1)
        let accentReference = referencePixel(for: DS.Colors.accent)
        print("RUNNING fill rgba = \(fill.redComponent), \(fill.greenComponent), \(fill.blueComponent), \(fill.alphaComponent)")
        print("surface1 ref rgb = \(darkReference.redComponent), \(darkReference.greenComponent), \(darkReference.blueComponent)")
        print("accent ref rgb = \(accentReference.redComponent), \(accentReference.greenComponent), \(accentReference.blueComponent)")

        #expect(closeTo(fill, darkReference, tolerance: 0.03), "toast fill matches surface1")
        #expect(!closeTo(fill, accentReference, tolerance: 0.15), "toast fill is NOT the brand accent")
        #expect(fill.alphaComponent > 0.98, "toast fill is fully opaque")

        let maxAlpha = maxAlphaJustOutsideShape(rendered, pillSize: pillSize)
        print("RUNNING max alpha just outside shape = \(maxAlpha)")
        #expect(maxAlpha < 0.06, "no halo ring outside the toast surface itself, got \(maxAlpha)")
    }

    /// The full toast (DONE) renders on the dark `surface1` (not the brand accent) with a hard edge.
    @Test func doneFullToastIsDarkSurfaceWithNoHalo() {
        let pillSize = ResearchFullToastGeometry.toastSize
        let rendered = render(
            ResearchFullToastView(
                viewModel: doneExpandedViewModel(),
                reduceMotionEnabled: true
            ),
            pointSize: CGSize(width: pillSize.width + renderPadding * 2,
                              height: pillSize.height + renderPadding * 2)
        )
        dump(rendered, named: "done-full-toast-dark")

        // Sample the clean top strip (above the vertically-centered content).
        let fill = rendered.pixel(renderPadding + pillSize.width / 2, renderPadding + 5)!
        let darkReference = referencePixel(for: DS.Colors.surface1)
        let accentReference = referencePixel(for: DS.Colors.accent)
        print("DONE fill rgba = \(fill.redComponent), \(fill.greenComponent), \(fill.blueComponent), \(fill.alphaComponent)")

        #expect(closeTo(fill, darkReference, tolerance: 0.03), "toast fill matches surface1")
        #expect(!closeTo(fill, accentReference, tolerance: 0.15), "toast fill is NOT the brand accent")
        #expect(fill.alphaComponent > 0.98, "toast fill is fully opaque")

        let maxAlpha = maxAlphaJustOutsideShape(rendered, pillSize: pillSize)
        print("DONE max alpha just outside shape = \(maxAlpha)")
        #expect(maxAlpha < 0.06, "no halo ring outside the toast surface itself, got \(maxAlpha)")
    }
}
