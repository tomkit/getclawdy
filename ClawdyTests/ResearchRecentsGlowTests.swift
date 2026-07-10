//
//  ResearchRecentsGlowTests.swift
//  ClawdyTests
//
//  Verifies the "Recent Research" badge / inline list wears the shared Clawdy aura
//  glow, with RUNTIME pixel evidence, AND that adding the glow did NOT enlarge the badge's
//  tight resting hover/cursor hit region (the glow is purely visual — the hit region is
//  driven by the controller's pill rect, not the SwiftUI view).
//
//   • Pixel evidence: the REAL resting badge surface and the REAL inline list content —
//     both rendered through the live `ResearchRecentsMorphingSurface` at their respective
//     resting/list-open endpoints (the exact production layer) — on a CLEAR background through
//     a real `NSHostingView` + `cacheDisplay`, each show a soft RED aura hugging their
//     edge (red-dominant — not a gray ring) while the dark interior stays dark, and far
//     out past the glow's reach the pixels are transparent (a CONTAINED soft aura, NOT a
//     clipped hard rectangle).
//   • Hit-region invariant: with the glow applied, the badge controller's installed resting
//     hover tracking rect still equals exactly the badge's own square (no phantom enlargement).
//
//  Renders are written to `CLAWDY_PIXEL_DUMP_DIR` (when set) as PNGs.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ResearchRecentsGlowTests {

    /// Clear border (points) around the surface so samples can land on the aura AND on the
    /// fully-transparent background beyond the glow's reach.
    private let renderPadding: CGFloat = 40

    // MARK: - Resting badge pixel evidence

    @Test func restingBadgeCarriesRedAuraWithoutWashingContent() {
        let pillSize = ResearchRecentsLayout.restingBadgeSize
        // The live production layer at its resting endpoint: the ONE shared morphing surface
        // (fill + aura) at the resting square's size + corner radius. We sample the surface
        // edge/interior, so clear inner content is sufficient.
        let badge = ResearchRecentsMorphingSurface(
            size: ResearchRecentsSurfaceMorph.restingSize,
            cornerRadius: ResearchRecentsSurfaceMorph.restingCornerRadius
        ) {
            Color.clear
        }

        let rendered = render(
            badge,
            pointSize: CGSize(width: pillSize.width + renderPadding * 2,
                              height: pillSize.height + renderPadding * 2)
        )
        dump(rendered, named: "recents-badge-red-aura")

        assertRedAuraContainedWithoutWashing(rendered, pillSize: pillSize)
    }

    // MARK: - Inline list pixel evidence

    @Test func inlineListCarriesRedAuraWithoutWashingContent() {
        let listSize = ResearchRecentsLayout.inlineListSize
        let model = ResearchRecentsBadgeModel()
        model.state = .listOpen
        model.rows = []   // empty state is enough — we sample the surface edge, not rows.

        // The live production layer at its list-open endpoint: the ONE shared morphing surface
        // wrapping the real inline-list content (the exact body the deleted standalone wrapper
        // rendered), so this still asserts the shipped surfaced list.
        let list = ResearchRecentsMorphingSurface(
            size: ResearchRecentsSurfaceMorph.listOpenSize,
            cornerRadius: ResearchRecentsSurfaceMorph.listOpenCornerRadius
        ) {
            ResearchRecentsInlineListContent(model: model)
        }
        let rendered = render(
            list,
            pointSize: CGSize(width: listSize.width + renderPadding * 2,
                              height: listSize.height + renderPadding * 2)
        )
        dump(rendered, named: "recents-list-red-aura")

        assertRedAuraContainedWithoutWashing(rendered, pillSize: listSize)
    }

    // MARK: - Mid-morph single-surface pixel evidence

    /// The crux of the square→list morph: the ONE shared `ResearchRecentsMorphingSurface`,
    /// rendered at a MID-progress size + corner radius, still shows a SINGLE soft red aura
    /// hugging its (intermediate-size) edge with a dark interior and transparent far out.
    /// Because the surface owns exactly one dark fill + one `.clawdyGlow`, an intermediate
    /// size can only render as one contained aura — proving the surface GROWS as one layer
    /// rather than cross-fading two separately-backed shapes that pop in at final size.
    @Test func morphingSurfaceRendersOneContainedAuraAtMidProgress() {
        let midSize = ResearchRecentsSurfaceMorph.size(atListOpenProgress: 0.5)
        let midCornerRadius = ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: 0.5)

        // The surface with empty (clear) content — we sample the shared surface fill + aura,
        // which is the single layer under test, independent of either state's inner content.
        let surface = ResearchRecentsMorphingSurface(size: midSize, cornerRadius: midCornerRadius) {
            Color.clear
        }
        let rendered = render(
            surface,
            pointSize: CGSize(width: midSize.width + renderPadding * 2,
                              height: midSize.height + renderPadding * 2)
        )
        dump(rendered, named: "recents-surface-mid-morph-red-aura")

        // Same contract as the endpoints — one contained red aura, dark interior — but at a
        // size STRICTLY between the square and the full list.
        #expect(midSize.width > ResearchRecentsSurfaceMorph.restingSize.width)
        #expect(midSize.width < ResearchRecentsSurfaceMorph.listOpenSize.width)
        assertRedAuraContainedWithoutWashing(rendered, pillSize: midSize)
    }

    /// Shared assertions: red aura at the mid-left edge, dark interior, transparent far out.
    private func assertRedAuraContainedWithoutWashing(_ rendered: RenderedBitmap, pillSize: CGSize) {
        // ── Interior is the dark surface (glow does not wash content). Sample NEAR the left
        //    edge (a small 8pt inset, at mid-height so the rounded corner doesn't cut in) to
        //    avoid the badge's centered white cursor glyph / any centered content — we want
        //    the surface fill, not a glyph. 8pt keeps it left of the glyph even on the narrow
        //    square badge (where a larger inset would land on the centered glyph). ──
        let interior = rendered.pixel(renderPadding + 8,
                                      renderPadding + pillSize.height / 2)!
        #expect(interior.alphaComponent > 0.9, "the surface interior is opaque")
        #expect(interior.blueComponent < 0.4 && interior.redComponent < 0.4,
                "the interior stays the dark surface — the glow doesn't wash it red")

        // ── Just outside the mid-left edge there IS a red-dominant aura (not gray). ──
        let auraOffset: CGFloat = 4
        let auraLeft = rendered.pixel(renderPadding - auraOffset,
                                      renderPadding + pillSize.height / 2)!
        let auraRight = rendered.pixel(renderPadding + pillSize.width + auraOffset,
                                       renderPadding + pillSize.height / 2)!
        print("RECENTS AURA left rgba = \(auraLeft.redComponent), \(auraLeft.greenComponent), \(auraLeft.blueComponent), \(auraLeft.alphaComponent)")
        print("RECENTS AURA right rgba = \(auraRight.redComponent), \(auraRight.greenComponent), \(auraRight.blueComponent), \(auraRight.alphaComponent)")

        for auraPixel in [auraLeft, auraRight] {
            #expect(auraPixel.alphaComponent > 0.05,
                    "there is a visible aura just outside the surface edge")
            #expect(auraPixel.redComponent > auraPixel.greenComponent + 0.15,
                    "aura is red-dominant over green (not gray)")
            #expect(auraPixel.redComponent > auraPixel.blueComponent + 0.10,
                    "aura is red-dominant over blue (not gray)")
        }

        // ── Far out, past the glow's reach, it fades to transparent — a CONTAINED aura,
        //    NOT a clipped hard rectangle. ──
        let farOutside = rendered.pixel(2, renderPadding + pillSize.height / 2)!
        print("RECENTS FAR-OUT rgba = \(farOutside.redComponent), \(farOutside.greenComponent), \(farOutside.blueComponent), \(farOutside.alphaComponent)")
        #expect(farOutside.alphaComponent < 0.08,
                "the aura is contained — transparent well past the glow radius (no hard rectangle)")
    }

    // MARK: - Hit-region invariant (glow is purely visual)

    /// The glow must NOT enlarge the resting hover hit region. The region is set from the
    /// controller's pill rect (independent of the SwiftUI glow), so with the glow applied
    /// the installed resting hover tracking rect still equals exactly the mini pill rect.
    @Test func glowDoesNotEnlargeRestingHitRegion() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.show()
        defer { controller.hide() }

        let restingPillRect = ResearchToastLayout.pillRect(
            inWindowOfSize: ResearchRecentsLayout.restingWindowContentSize,
            pillSize: ResearchRecentsLayout.restingBadgeSize
        )
        #expect(controller.installedHoverTrackingRectForTesting == restingPillRect,
                "the resting hover hit region is exactly the badge's own square — the glow doesn't enlarge it")
        // The hover hit region is the tight square badge, strictly smaller than the window —
        // proving the (visually larger, glowing) surface didn't grow the interactive area.
        #expect(restingPillRect.width < ResearchRecentsLayout.restingWindowContentSize.width)
        #expect(restingPillRect.height < ResearchRecentsLayout.restingWindowContentSize.height)
    }

    // MARK: - Render helpers (mirror ClawdyGlowTests)

    private struct RenderedBitmap {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
        func pixel(_ pointX: CGFloat, _ pointY: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(pointX * scale), y: Int(pointY * scale))?.usingColorSpace(.sRGB)
        }
    }

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
}
