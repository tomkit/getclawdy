//
//  ClawdyGlowTests.swift
//  ClawdyTests
//
//  Verifies the shared `clawdyGlow(...)` primitive — the ONE reusable Clawdy aura
//  glow — both structurally and with RUNTIME pixel evidence:
//
//   • Tuning contract: the glow color derives from the canonical `DS.Colors.openClawRed`
//     token, and the default radius sits within the documented safe margin
//     (`maximumSafeRadius`, 14pt vs the overlay panels' ~18pt clear margin).
//   • Pixel evidence: a sample dark `surface1` pill (~320×68, r=12) rendered WITH
//     `clawdyGlow()` on a CLEAR background through a real `NSHostingView` +
//     `cacheDisplay(in:to:)` produces, just outside the pill's edge, a soft RED aura
//     (red channel clearly dominant — NOT a gray ring), while the pill's own interior
//     fill stays the dark `surface1` (the glow does not wash the content), and far out
//     past the glow's reach the pixels are transparent (a CONTAINED aura, not a filled
//     rectangle clipped by the bounds).
//
//  Each render is written to `CLAWDY_PIXEL_DUMP_DIR` (when set) as a PNG so the red
//  aura can be eyeballed.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ClawdyGlowTests {

    // The toast reference pill: dark `surface1`, ~320×68, corner radius 12.
    private let pillSize = CGSize(width: 320, height: 68)
    private let pillCornerRadius: CGFloat = 12

    /// Clear border (points) left around the pill so samples can land on the aura AND on
    /// the fully-transparent background beyond the glow's reach. Comfortably larger than
    /// the default glow radius so both regions exist in the render.
    private let renderPadding: CGFloat = 40

    // MARK: - Structural / tuning contract (no rendering)

    /// The glow's color IS the canonical OpenClaw red, and the default radius is within the
    /// documented safe ceiling for the ~18pt overlay margin. Non-vacuous: it reads the
    /// real tuning constants the modifier composites from.
    @Test func glowTuningDerivesFromOpenClawRedAndStaysWithinSafeMargin() {
        // Color derives from the canonical token (compare through a shared render pipeline
        // so the comparison is immune to color-space quirks — see referencePixel).
        let glowReference = referencePixel(for: ClawdyGlow.glowColor)
        let openClawRedReference = referencePixel(for: DS.Colors.openClawRed)
        #expect(closeTo(glowReference, openClawRedReference, tolerance: 0.02),
                "glow color is the canonical openClawRed token")

        // The ACTUAL bloom relationship — NOT merely `radius <= 18`. Assert that the
        // visible bloom (radius × bloomFactor) of BOTH the default radius AND the safe
        // ceiling fits inside the overlay panel's clear margin. This FAILS if someone
        // raises `maximumSafeRadius` past the safe value (e.g. 18 → 18 × 1.3 = 23.4 > 18).
        #expect(ClawdyGlow.defaultRadius * ClawdyGlow.bloomFactor <= ClawdyGlow.overlayPanelMargin,
                "default radius bloom fits inside the overlay panel margin")
        #expect(ClawdyGlow.maximumSafeRadius * ClawdyGlow.bloomFactor <= ClawdyGlow.overlayPanelMargin,
                "safe-radius ceiling bloom fits inside the overlay panel margin")

        // The default stays at or below the derived ceiling, and both are real positives.
        #expect(ClawdyGlow.defaultRadius <= ClawdyGlow.maximumSafeRadius,
                "default glow radius is within the derived safe ceiling")
        #expect(ClawdyGlow.defaultRadius > 0, "default glow radius is a real, positive blur")
        #expect(ClawdyGlow.defaultIntensity > 0, "default intensity is positive")
    }

    // MARK: - Runtime pixel evidence

    /// A dark `surface1` pill WITH `clawdyGlow()` shows a soft RED aura hugging its edge,
    /// keeps its dark interior, and fades to transparent past the glow's reach.
    @Test func glowRendersSoftRedAuraWithoutWashingContent() {
        let glowRadius = ClawdyGlow.defaultRadius
        let samplePill = RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
            .fill(DS.Colors.surface1)
            .frame(width: pillSize.width, height: pillSize.height)
            .clawdyGlow(cornerRadius: pillCornerRadius, radius: glowRadius)

        let rendered = render(
            samplePill,
            pointSize: CGSize(width: pillSize.width + renderPadding * 2,
                              height: pillSize.height + renderPadding * 2)
        )
        dump(rendered, named: "clawdy-glow-red-aura")

        // ── 1. Interior fill is untouched dark surface1 (glow does not wash content). ──
        let interior = rendered.pixel(renderPadding + pillSize.width / 2,
                                      renderPadding + pillSize.height / 2)!
        let surfaceReference = referencePixel(for: DS.Colors.surface1)
        #expect(closeTo(interior, surfaceReference, tolerance: 0.03),
                "pill interior stays surface1 — the glow doesn't wash the content")

        // ── 2. Just outside the pill's edge there IS a red aura (not transparent, and
        //       red-dominant — not a gray ring). Sample a few points off the mid-left
        //       and mid-right edges, within the glow's reach. ──
        let auraOffset: CGFloat = 4
        let auraLeft = rendered.pixel(renderPadding - auraOffset,
                                      renderPadding + pillSize.height / 2)!
        let auraRight = rendered.pixel(renderPadding + pillSize.width + auraOffset,
                                       renderPadding + pillSize.height / 2)!
        print("AURA left rgba = \(auraLeft.redComponent), \(auraLeft.greenComponent), \(auraLeft.blueComponent), \(auraLeft.alphaComponent)")
        print("AURA right rgba = \(auraRight.redComponent), \(auraRight.greenComponent), \(auraRight.blueComponent), \(auraRight.alphaComponent)")

        for auraPixel in [auraLeft, auraRight] {
            #expect(auraPixel.alphaComponent > 0.05,
                    "there is a visible aura just outside the pill edge")
            // Red clearly dominates green & blue ⇒ a RED aura, not a gray/neutral ring.
            #expect(auraPixel.redComponent > auraPixel.greenComponent + 0.15,
                    "aura is red-dominant over green (not gray)")
            #expect(auraPixel.redComponent > auraPixel.blueComponent + 0.10,
                    "aura is red-dominant over blue (not gray)")
        }

        // ── 3. Far out, past the glow's reach (near the padding edge), it fades to
        //       transparent — a CONTAINED aura, not a filled rectangle clipped by bounds. ──
        let farOutside = rendered.pixel(2, renderPadding + pillSize.height / 2)!
        print("FAR-OUT rgba = \(farOutside.redComponent), \(farOutside.greenComponent), \(farOutside.blueComponent), \(farOutside.alphaComponent)")
        #expect(farOutside.alphaComponent < 0.08,
                "the aura is contained — transparent well past the glow radius, not a filled rectangle")
    }

    // MARK: - Render helpers (mirror ResearchOverlayDarkSurfacePixelRenderTests)

    private struct RenderedBitmap {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        func pixel(_ pointX: CGFloat, _ pointY: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(pointX * scale), y: Int(pointY * scale))?.usingColorSpace(.sRGB)
        }
    }

    /// Renders `content` at `pointSize` on a CLEAR background via a real `NSHostingView` +
    /// `cacheDisplay`, so the true SwiftUI/AppKit view tree (blur included) is rasterized.
    private func render<Content: View>(_ content: Content, pointSize: CGSize) -> RenderedBitmap {
        let hostingView = NSHostingView(
            rootView: content
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
    /// color comparisons are apples-to-apples and immune to the caching bitmap's color space.
    private func referencePixel(for color: Color) -> NSColor {
        let swatch = render(
            Rectangle().fill(color).frame(width: 40, height: 40),
            pointSize: CGSize(width: 40, height: 40)
        )
        return swatch.pixel(20, 20)!
    }

    private func closeTo(_ color: NSColor, _ reference: NSColor, tolerance: CGFloat) -> Bool {
        abs(color.redComponent - reference.redComponent) < tolerance
            && abs(color.greenComponent - reference.greenComponent) < tolerance
            && abs(color.blueComponent - reference.blueComponent) < tolerance
    }
}
