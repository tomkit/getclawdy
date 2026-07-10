//
//  ResearchToastStackingPixelRenderTests.swift
//  ClawdyTests
//
//  RUNTIME pixel evidence for the redesigned research toast:
//   (d) a full toast (`ResearchFullToastView`) wrapped in the shared `clawdyGlow(...)` — the
//       SAME composition the live overlay's `ResearchToastWindowRootView` uses — shows a
//       soft RED aura just outside its edge, keeps its dark `surface1` interior, and fades
//       to transparent past the glow's reach (a clean aura, NOT a clipped hard rectangle).
//   (a) 3+ toasts collapsed into the native STACK (front card full, the ones behind offset
//       down + scaled + dimmed via the pure `ResearchStackFanLayout.stackedCardTransform`).
//   (b) the same cluster FANNED OUT into the full vertical list (every toast full-size).
//   (c) the cluster RE-STACKED (back to the compact stack).
//
//  The overlay's real windows are `sharingType = .readOnly` (visible to recorders) and animate
//  asynchronously, so — like the other overlay pixel tests — these rasterize the ACTUAL
//  SwiftUI view tree (the real `ResearchFullToastView` + `clawdyGlow` + the real pure
//  stacked transforms) through a real `NSHostingView` + `cacheDisplay`. Each render is
//  written to `CLAWDY_PIXEL_DUMP_DIR` (when set) as a PNG so the stacking + glow can be
//  eyeballed.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchToastStackingPixelRenderTests {

    private let toastSize = ResearchFullToastGeometry.toastSize
    private let cornerRadius = ResearchFullToastGeometry.cornerRadius
    /// Clear border around the composition so the aura AND the transparent background beyond
    /// it both exist in the render (comfortably larger than the glow's reach).
    private let renderPadding: CGFloat = 44

    // MARK: - (d) Glow on the REAL full toast

    /// The real `ResearchFullToastView` + `clawdyGlow(...)` shows a soft red aura just
    /// outside its edge, keeps its dark interior, and is transparent past the glow's reach.
    @Test func fullToastWithGlowShowsContainedRedAura() {
        let toast = ResearchFullToastView(viewModel: runningViewModel(), reduceMotionEnabled: true)
            .clawdyGlow(cornerRadius: cornerRadius, radius: ClawdyGlow.maximumSafeRadius)

        let rendered = render(
            toast,
            pointSize: CGSize(width: toastSize.width + renderPadding * 2,
                              height: toastSize.height + renderPadding * 2)
        )
        dump(rendered, named: "full-toast-glow-red-aura")

        // Interior stays dark surface1 (top strip, above the vertically-centered content).
        let interior = rendered.pixel(renderPadding + toastSize.width / 2, renderPadding + 5)!
        let surfaceReference = referencePixel(for: DS.Colors.surface1)
        #expect(closeTo(interior, surfaceReference, tolerance: 0.04),
                "toast interior stays surface1 — the aura doesn't wash the content")

        // Just outside the mid-left / mid-right edge: a RED aura (red-dominant, present).
        let auraOffset: CGFloat = 4
        let auraLeft = rendered.pixel(renderPadding - auraOffset, renderPadding + toastSize.height / 2)!
        let auraRight = rendered.pixel(renderPadding + toastSize.width + auraOffset, renderPadding + toastSize.height / 2)!
        print("TOAST AURA left rgba = \(auraLeft.redComponent), \(auraLeft.greenComponent), \(auraLeft.blueComponent), \(auraLeft.alphaComponent)")
        print("TOAST AURA right rgba = \(auraRight.redComponent), \(auraRight.greenComponent), \(auraRight.blueComponent), \(auraRight.alphaComponent)")
        for auraPixel in [auraLeft, auraRight] {
            #expect(auraPixel.alphaComponent > 0.05, "there is a visible aura just outside the toast edge")
            #expect(auraPixel.redComponent > auraPixel.greenComponent + 0.15, "aura is red-dominant over green (not gray)")
            #expect(auraPixel.redComponent > auraPixel.blueComponent + 0.10, "aura is red-dominant over blue (not gray)")
        }

        // Far out (near the padding edge), past the glow's reach: transparent — a contained
        // aura, NOT a clipped hard rectangle filling the frame. This is the hard-edge check.
        let farOutside = rendered.pixel(2, renderPadding + toastSize.height / 2)!
        print("TOAST FAR-OUT rgba = \(farOutside.redComponent), \(farOutside.greenComponent), \(farOutside.blueComponent), \(farOutside.alphaComponent)")
        #expect(farOutside.alphaComponent < 0.08,
                "the aura is contained/soft — transparent well past the glow, not a hard rectangle")
    }

    // MARK: - (a)/(b)/(c) Stacked / fanned / re-stacked evidence

    /// 3 toasts collapsed into the native stack: front card full + the ones behind PEEKING out
    /// below it (offset down + scaled + dimmed). Asserting the front interior alone would pass
    /// even if only ONE toast rendered, so this also samples the 2nd- and 3rd-card peek bands
    /// below the front card's bottom edge — pixels that can ONLY be opaque if the back cards
    /// actually render at their stacked offsets.
    @Test func threeToastsStackedRendersEvidence() {
        let rendered = render(
            clusterView(fannedOut: false),
            pointSize: clusterPointSize(fannedOut: false)
        )
        dump(rendered, named: "toasts-stacked")
        assertStackedCardPeeksRender(rendered)
    }

    /// The same 3 toasts FANNED OUT into the full vertical list. Asserting the first row alone
    /// would pass with only one toast, so this proves all THREE distinct full-toast rows render
    /// at their expected `fullToastSlotStride` offsets (opaque dark surface interiors).
    @Test func threeToastsFannedRendersEvidence() {
        let rendered = render(
            clusterView(fannedOut: true),
            pointSize: clusterPointSize(fannedOut: true)
        )
        dump(rendered, named: "toasts-fanned")
        assertFannedRowsRender(rendered)
    }

    /// RE-STACKED — the fanned cluster returned to the compact stack (same as stacked): the
    /// front card plus the back-card peeks all render again.
    @Test func threeToastsReStackedRendersEvidence() {
        let rendered = render(
            clusterView(fannedOut: false),
            pointSize: clusterPointSize(fannedOut: false)
        )
        dump(rendered, named: "toasts-restacked")
        assertStackedCardPeeksRender(rendered)
    }

    // MARK: - Multi-card render assertions (prove more than the front card renders)

    /// In the compact stack, the back cards PEEK out below the front card's bottom edge. This
    /// samples two peek bands — one reachable only if the 2nd card renders, one reachable only
    /// if the 3rd (deepest) card renders — and asserts each is opaque card content, not the
    /// faint red glow aura a single card would leave there.
    private func assertStackedCardPeeksRender(_ rendered: RenderedBitmap) {
        let centerX = renderPadding + toastSize.width / 2

        // The front card's interior stays opaque at the top-left anchor.
        let frontInterior = rendered.pixel(centerX, renderPadding + 5)!
        #expect(frontInterior.alphaComponent > 0.9, "the front stacked card renders opaque")

        // Derive each back card's on-screen bottom from the PURE stacked transforms so the
        // peek-band samples track the real geometry (no magic numbers).
        let frontBottom = renderPadding + toastSize.height
        let secondCard = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 1)
        let thirdCard = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 2)
        let secondCardBottom = renderPadding + secondCard.peekOffset + toastSize.height * secondCard.scale
        let thirdCardBottom = renderPadding + thirdCard.peekOffset + toastSize.height * thirdCard.scale

        // A y strictly between the front's bottom and the 2nd card's bottom is inside the 2nd
        // card's peek — opaque only if the 2nd card actually rendered.
        let secondCardPeekY = (frontBottom + secondCardBottom) / 2
        let secondPeek = rendered.pixel(centerX, secondCardPeekY)!
        print("STACK 2nd-card peek rgba = \(secondPeek.redComponent), \(secondPeek.greenComponent), \(secondPeek.blueComponent), \(secondPeek.alphaComponent)")
        #expect(secondPeek.alphaComponent > 0.4,
                "the 2nd card peeks below the front card (opaque card content, not just aura)")

        // A y strictly between the 2nd and 3rd cards' bottoms is reachable ONLY by the 3rd
        // (deepest) card — proof a third card renders, not just the front + one peek.
        let thirdCardPeekY = (secondCardBottom + thirdCardBottom) / 2
        let thirdPeek = rendered.pixel(centerX, thirdCardPeekY)!
        print("STACK 3rd-card peek rgba = \(thirdPeek.redComponent), \(thirdPeek.greenComponent), \(thirdPeek.blueComponent), \(thirdPeek.alphaComponent)")
        #expect(thirdPeek.alphaComponent > 0.4,
                "the 3rd (deepest) card peeks below the 2nd (opaque card content, not just aura)")
    }

    /// In the fanned list, each toast is a distinct full-size row offset by `fullToastSlotStride`.
    /// This asserts all three rows' interiors render as opaque dark `surface1` at their expected
    /// offsets — impossible unless three separate toasts render (a single toast would leave the
    /// 2nd/3rd row positions transparent).
    private func assertFannedRowsRender(_ rendered: RenderedBitmap) {
        let centerX = renderPadding + toastSize.width / 2
        let surfaceReference = referencePixel(for: DS.Colors.surface1)
        let stride = ResearchToastLayout.fullToastSlotStride
        for rowIndex in 0..<clusterCount {
            let interiorY = renderPadding + stride * CGFloat(rowIndex) + 5
            let interior = rendered.pixel(centerX, interiorY)!
            print("FANNED row \(rowIndex) interior rgba = \(interior.redComponent), \(interior.greenComponent), \(interior.blueComponent), \(interior.alphaComponent)")
            #expect(interior.alphaComponent > 0.9,
                    "fanned row \(rowIndex) renders an opaque toast at its expected offset")
            #expect(closeTo(interior, surfaceReference, tolerance: 0.06),
                    "fanned row \(rowIndex) interior is the dark surface1 (a real toast, not the red aura)")
        }
    }

    // MARK: - Cluster composition (mirrors the controller's real layout)

    private let clusterCount = 3

    /// The point size of a 3-toast cluster composition. Stacked packs tight (peek stride);
    /// fanned uses the full-toast stride.
    private func clusterPointSize(fannedOut: Bool) -> CGSize {
        let stride = fannedOut ? ResearchToastLayout.fullToastSlotStride : ResearchStackFanLayout.stackedCardPeek
        let height = toastSize.height + stride * CGFloat(clusterCount - 1)
        return CGSize(width: toastSize.width + renderPadding * 2,
                      height: height + renderPadding * 2)
    }

    /// A SwiftUI composition of `clusterCount` real full toasts laid out exactly as the
    /// controller lays them out — fanned (full stride, full size) or stacked (peek stride +
    /// the pure `stackedCardTransform` scale/opacity/z, anchored top-leading).
    private func clusterView(fannedOut: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<clusterCount, id: \.self) { index in
                let toast = ResearchFullToastView(viewModel: clusterViewModel(index: index), reduceMotionEnabled: true)
                    .clawdyGlow(cornerRadius: cornerRadius, radius: ClawdyGlow.maximumSafeRadius)
                if fannedOut {
                    toast
                        .offset(y: ResearchToastLayout.fullToastSlotStride * CGFloat(index))
                        .zIndex(Double(index))
                } else {
                    let transform = ResearchStackFanLayout.stackedCardTransform(depthFromFront: index)
                    toast
                        .scaleEffect(transform.scale, anchor: .topLeading)
                        .opacity(transform.opacity)
                        .offset(y: transform.peekOffset)
                        .zIndex(transform.zPosition)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(renderPadding)
    }

    private func clusterViewModel(index: Int) -> ResearchProgressOverlayViewModel {
        let viewModel = ResearchProgressOverlayViewModel()
        let phases: [ResearchOverlayPhase] = [.running, .needsInput, .done]
        viewModel.phase = phases[index % phases.count]
        viewModel.taskDescription = ["aomori winter photos", "best espresso machines", "kyoto ryokan guide"][index % 3]
        viewModel.statusLine = ["Searching the web…", "I need a quick answer — click to reply", "View results ›"][index % 3]
        viewModel.isCancellable = viewModel.phase == .running || viewModel.phase == .needsInput
        return viewModel
    }

    private func runningViewModel() -> ResearchProgressOverlayViewModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "aomori winter photos"
        viewModel.statusLine = "Searching the web…"
        viewModel.isCancellable = true
        return viewModel
    }

    // MARK: - Render helpers (mirror the other overlay pixel tests)

    private struct RenderedBitmap {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        func pixel(_ pointX: CGFloat, _ pointY: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(pointX * scale), y: Int(pointY * scale))?.usingColorSpace(.sRGB)
        }
    }

    private func render<Content: View>(_ content: Content, pointSize: CGSize) -> RenderedBitmap {
        let hostingView = NSHostingView(rootView: content.frame(width: pointSize.width, height: pointSize.height))
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

    private func referencePixel(for color: Color) -> NSColor {
        let swatch = render(Rectangle().fill(color).frame(width: 40, height: 40),
                            pointSize: CGSize(width: 40, height: 40))
        return swatch.pixel(20, 20)!
    }

    private func closeTo(_ color: NSColor, _ reference: NSColor, tolerance: CGFloat) -> Bool {
        abs(color.redComponent - reference.redComponent) < tolerance
            && abs(color.greenComponent - reference.greenComponent) < tolerance
            && abs(color.blueComponent - reference.blueComponent) < tolerance
    }
}
