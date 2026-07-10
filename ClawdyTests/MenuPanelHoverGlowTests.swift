//
//  MenuPanelHoverGlowTests.swift
//  ClawdyTests
//
//  Covers the two menu-bar-panel polish changes on `CompanionPanelView`:
//
//    1. The Clawdy aura GLOW on the menu window. The menu popover is sized exactly to
//       its content (fixed 320pt wide, no transparent margin), so an outer bloom on a
//       full-width surface would clip into a hard rectangle. `MenuPanelMetrics` insets the
//       opaque surface and pads it back out, manufacturing the clear margin the glow blooms
//       into. This file:
//         • asserts the clip-safety relationship purely (bloom ≤ manufactured margin, and the
//           inset surface + both margins add back to the fixed window width), and
//         • renders the REAL `CompanionPanelView` through a live `NSHostingView` + `cacheDisplay`
//           and checks that a soft RED aura hugs the surface edge and fades to TRANSPARENT
//           before the window edge — i.e. a contained aura, NOT a clipped hard rectangle.
//
//    2. The HOVER affordances. Hover state is @State internal to the controls and can't be
//       driven headlessly, so the shipped views resolve their per-control-type + per-hover
//       treatment through the PURE `MenuPanelHoverStyle` / `MenuButtonHoverWash` helpers in
//       `CompanionPanelView`. This file asserts those PRODUCTION helpers directly — the SAME
//       code the app renders — so a wrong hover mapping (e.g. an accent wash that lightens
//       instead of darkens) fails a test instead of passing silently.
//
//  PNGs dump to `CLAWDY_PIXEL_DUMP_DIR` when set.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct MenuPanelHoverGlowTests {

    // MARK: - Pure clip-safety contract (no rendering)

    /// The manufactured glow margin is real, the inset surface plus both margins add back to
    /// the fixed window width, and the glow's visible bloom fits inside that margin — so the
    /// aura can't clip into a hard rectangle against the window bounds. Non-vacuous: reads the
    /// real `MenuPanelMetrics` + `ClawdyGlow.bloomFactor` the view composites from.
    @Test func glowMarginIsClipSafeAndReconstructsTheWindowWidth() {
        // The inset opaque surface + a margin on each side == the fixed menu window width.
        #expect(MenuPanelMetrics.surfaceWidth + MenuPanelMetrics.glowMargin * 2 == MenuPanelMetrics.windowWidth,
                "inset surface plus both glow margins reconstructs the fixed 320pt window width")

        // The manufactured margin and inset surface are real positives.
        #expect(MenuPanelMetrics.glowMargin > 0, "there is a real transparent margin for the aura")
        #expect(MenuPanelMetrics.surfaceWidth > 0, "the opaque surface has a real positive width")

        // The ACTUAL bloom relationship — not merely `radius <= margin`. The visible bloom
        // (radius × bloomFactor) must fit inside the manufactured margin, or the aura clips.
        #expect(MenuPanelMetrics.visibleGlowBloom == MenuPanelMetrics.glowRadius * ClawdyGlow.bloomFactor,
                "the documented bloom is radius × bloomFactor")
        #expect(MenuPanelMetrics.visibleGlowBloom <= MenuPanelMetrics.glowMargin,
                "the glow's visible bloom fits inside the manufactured margin (no hard-edge clip)")

        // The radius is a real, positive blur within the primitive's own safe ceiling.
        #expect(MenuPanelMetrics.glowRadius > 0, "the glow radius is a real, positive blur")
        #expect(MenuPanelMetrics.glowRadius <= ClawdyGlow.maximumSafeRadius,
                "the menu glow radius stays within the primitive's safe ceiling")
    }

    // MARK: - Runtime pixel evidence: the glow on the REAL panel

    /// The real `CompanionPanelView` renders a soft RED aura hugging the opaque surface edge
    /// that fades to transparent before the window edge — a contained aura, not a clipped
    /// hard rectangle — AND the surface edge itself is a CLEAN opaque neutral edge, with no
    /// semi-transparent red rim bleeding onto the content (the hard alpha seam this change
    /// removes: the aura source is inset beneath the surface so its own edge stays hidden).
    @Test func realMenuPanelRendersContainedRedAuraNotAClippedRectangle() {
        let panel = CompanionPanelView(companionManager: CompanionManager())
        let renderSize = CGSize(width: MenuPanelMetrics.windowWidth, height: 480)
        let rendered = render(panel, pointSize: renderSize)
        dump(rendered, named: "menu-panel-glow")

        // Sample on the left edge, well within the surface's vertical extent (near the top).
        let sampleY: CGFloat = 90
        let surfaceLeftEdge = MenuPanelMetrics.glowMargin           // opaque surface starts here (x = 16)

        // ── 1. Interior is the opaque dark panel background — the glow doesn't wash content. ──
        let interior = rendered.pixel(MenuPanelMetrics.windowWidth / 2, sampleY)!
        let backgroundReference = referencePixel(for: DS.Colors.background)
        #expect(closeTo(interior, backgroundReference, tolerance: 0.04),
                "panel interior stays the dark background — the glow doesn't wash the content")

        // ── 2. Just outside the surface edge (inside the margin) there is a RED aura. ──
        let auraLeft = rendered.pixel(surfaceLeftEdge - 4, sampleY)!
        print("MENU AURA left rgba = \(auraLeft.redComponent), \(auraLeft.greenComponent), \(auraLeft.blueComponent), \(auraLeft.alphaComponent)")
        #expect(auraLeft.alphaComponent > 0.05, "there is a visible aura just outside the surface edge")
        #expect(auraLeft.redComponent > auraLeft.blueComponent + 0.10,
                "the aura is red-dominant over blue (an OpenClaw-red aura, not a gray shadow ring)")
        #expect(auraLeft.redComponent > auraLeft.greenComponent + 0.06,
                "the aura is red-dominant over green (not a neutral ring)")

        // ── 3. At the very window edge the aura has faded to (near) transparent — the aura is
        //       CONTAINED, proving it is not clipped into a hard filled rectangle. ──
        let windowEdge = rendered.pixel(1, sampleY)!
        print("MENU WINDOW-EDGE rgba = \(windowEdge.redComponent), \(windowEdge.greenComponent), \(windowEdge.blueComponent), \(windowEdge.alphaComponent)")
        #expect(windowEdge.alphaComponent < 0.20,
                "the aura fades before the window edge — a contained aura, not a clipped hard rectangle")

        // ── 4. The seam itself: the aura pixels IMMEDIATELY hugging the surface edge must be a
        //       SOFT band, not the bright, high-alpha red rim the seam-prone `.directOnSurface`
        //       composition leaves. That rim is a coincident-edge artifact riding the last ~1pt
        //       before the opaque surface, so it is sampled RIGHT at the edge (device-pixel
        //       resolution: the render is 2×, so points 15.5 / 15.0 land on the two device pixels
        //       immediately outside the x=16 surface edge). Measured, at those pixels (with the
        //       OpenClaw-red aura, whose dominant channel is now RED):
        //           `.directOnSurface` (seam): red ≈ 0.47–0.48, alpha ≈ 0.64–0.66
        //           `.insetBeneathSurface`   : red ≈ 0.39,      alpha ≈ 0.54–0.56
        //       The thresholds sit between the two, so flipping the production composition back to
        //       the direct glow FAILS here (the bright seam rim exceeds them). ──
        for edgeBandOffset in [CGFloat(0.5), 1.0] {
            let edgeBand = rendered.pixel(surfaceLeftEdge - edgeBandOffset, sampleY)!
            print("MENU EDGE-BAND (\(edgeBandOffset)pt out) rgba = \(edgeBand.redComponent), \(edgeBand.greenComponent), \(edgeBand.blueComponent), \(edgeBand.alphaComponent)")
            #expect(edgeBand.redComponent < 0.43,
                    "the aura band hugging the edge is soft red — NOT the bright direct-glow seam rim (red ≥ ~0.47)")
            #expect(edgeBand.alphaComponent < 0.61,
                    "the aura band hugging the edge is soft — NOT the high-alpha direct-glow seam rim (alpha ≥ ~0.64)")
        }

        // ── 5. Just INSIDE the surface edge the pixels are the CLEAN opaque neutral background —
        //       NOT a semi-transparent, red-tinted rim bleeding onto the content. A clean edge
        //       means: fully opaque (no partial alpha) and neutral (red not dominant — the dark
        //       background, not a red seam). ──
        for insideOffset in [CGFloat(2), 4, 6] {
            let insideEdge = rendered.pixel(surfaceLeftEdge + insideOffset, sampleY)!
            #expect(insideEdge.alphaComponent > 0.98,
                    "the surface interior right at the edge is fully opaque — no semi-transparent seam rim")
            #expect(insideEdge.redComponent - insideEdge.blueComponent < 0.03,
                    "the surface interior right at the edge is the neutral dark background — no red seam tint")
        }
    }

    // MARK: - The inset mechanism that removes the hard alpha seam (pure)

    /// The PRODUCTION composition the panel body renders is the seam-free `.insetBeneathSurface`
    /// — a separate aura layer tucked under the surface — and NOT the seam-prone `.directOnSurface`
    /// direct glow. `CompanionPanelView.body` switches on this exact constant to build itself, so
    /// this is a genuine structural guard: reverting the body to the direct glow means flipping
    /// this constant, which flips this assertion to red.
    @Test func panelComposesTheAuraAsASeparateInsetLayerNotADirectGlowOnTheSurface() {
        #expect(MenuPanelMetrics.glowComposition == .insetBeneathSurface,
                "the panel casts its aura from a separate layer inset beneath the surface — not a direct .clawdyGlow on the surface (which rides a hard alpha seam)")
    }

    /// The aura source is inset BENEATH the opaque surface by a real, positive amount, so the
    /// surface overhangs the aura shape's own crisp edge — that overhang is what hides the
    /// coincident-edge antialiasing (the hard alpha seam) and the brightest inner-halo band.
    /// The inset is also strictly smaller than the visible bloom, so a real soft aura still
    /// reaches past the surface edge (the fix removes the seam WITHOUT removing the aura).
    @Test func auraIsInsetBeneathSurfaceSoTheSeamHidesButTheAuraStillEscapes() {
        #expect(MenuPanelMetrics.auraEdgeInset > 0,
                "the aura is inset beneath the surface, so the surface overhangs (and hides) its crisp edge")
        #expect(MenuPanelMetrics.auraEdgeInset < MenuPanelMetrics.visibleGlowBloom,
                "the inset is smaller than the bloom, so a soft aura still spills past the surface edge")

        // The aura's ACTUAL reach past the surface edge = bloom minus the inset — a real positive.
        let auraReachPastSurfaceEdge = MenuPanelMetrics.visibleGlowBloom - MenuPanelMetrics.auraEdgeInset
        #expect(auraReachPastSurfaceEdge > 0,
                "the aura still reaches past the surface edge after accounting for the inset")

        // And that reach still fits inside the manufactured clear margin — no clip.
        #expect(auraReachPastSurfaceEdge <= MenuPanelMetrics.glowMargin,
                "the inset aura's reach stays within the clear margin (no hard-edge clip)")
    }

    // MARK: - Hover affordance mapping (asserts the PRODUCTION helpers directly)

    /// A segmented picker option's LABEL tint, per selected + hovered, comes straight from the
    /// production `MenuPanelHoverStyle.segmentLabelColor`. Selected reads Clawdy-blue accent
    /// (hover-independent); an unselected option brightens `textTertiary` → `textSecondary` on
    /// hover — and the selected and unselected treatments are visibly different.
    @Test func segmentLabelColorMapsPerSelectedAndHover() {
        // Selected reads the Clawdy-blue accent tint regardless of hover.
        #expect(sameColor(MenuPanelHoverStyle.segmentLabelColor(isSelected: true, isHovered: false), DS.Colors.accentText))
        #expect(sameColor(MenuPanelHoverStyle.segmentLabelColor(isSelected: true, isHovered: true), DS.Colors.accentText))

        // Unselected brightens toward the secondary tone on hover.
        #expect(sameColor(MenuPanelHoverStyle.segmentLabelColor(isSelected: false, isHovered: false), DS.Colors.textTertiary))
        #expect(sameColor(MenuPanelHoverStyle.segmentLabelColor(isSelected: false, isHovered: true), DS.Colors.textSecondary))

        // Selected and unselected are genuinely different treatments (guards a swapped mapping).
        #expect(!sameColor(MenuPanelHoverStyle.segmentLabelColor(isSelected: true, isHovered: false),
                           MenuPanelHoverStyle.segmentLabelColor(isSelected: false, isHovered: false)),
                "the selected accent tint differs from the unselected resting tint")
    }

    /// A segmented picker option's BACKGROUND fill, per selected + hovered, comes straight from
    /// the production `MenuPanelHoverStyle.segmentBackgroundFill`. Selected wears the accent
    /// selected-fill; an unselected option is transparent at rest and lifts a faint white fill
    /// on hover.
    @Test func segmentBackgroundFillMapsPerSelectedAndHover() {
        // Selected wears the Clawdy accent selected-fill.
        #expect(sameColor(MenuPanelHoverStyle.segmentBackgroundFill(isSelected: true, isHovered: false), DS.Colors.accentSelectedFill))

        // Unselected: transparent at rest, faint white fill on hover.
        #expect(sameColor(MenuPanelHoverStyle.segmentBackgroundFill(isSelected: false, isHovered: false), Color.clear))
        #expect(sameColor(MenuPanelHoverStyle.segmentBackgroundFill(isSelected: false, isHovered: true), Color.white.opacity(0.06)))

        // The hovered unselected fill is a real, visible lift from the transparent resting fill.
        let restingFillAlpha = alpha(MenuPanelHoverStyle.segmentBackgroundFill(isSelected: false, isHovered: false))
        let hoveredFillAlpha = alpha(MenuPanelHoverStyle.segmentBackgroundFill(isSelected: false, isHovered: true))
        #expect(hoveredFillAlpha > restingFillAlpha, "the unselected fill lifts on hover")
    }

    /// Accent fills (white labels) DARKEN on hover and neutral surfaces LIGHTEN — the AA-safe
    /// mapping the production `MenuButtonHoverWash` encodes. Asserting the two wash colors here
    /// (not a bare eyeball) means flipping accent from black to white fails this test.
    @Test func buttonHoverWashDarkensAccentAndLightensNeutral() {
        // Accent fills darken (black wash keeps white-on-blue label above WCAG-AA).
        #expect(sameColor(MenuButtonHoverWash.accent.color, Color.black),
                "accent buttons darken on hover (BLACK wash), preserving white-label contrast")
        // Neutral surfaces lighten (white wash reads as 'lit up' on the dark panel).
        #expect(sameColor(MenuButtonHoverWash.neutral.color, Color.white),
                "neutral surfaces lighten on hover (WHITE wash)")
        // The two families are opposites — not the same wash applied to both.
        #expect(!sameColor(MenuButtonHoverWash.accent.color, MenuButtonHoverWash.neutral.color),
                "accent and neutral use opposite washes")
    }

    /// The state-layer wash a filled button/card lifts on hover is 0 at rest and the shared
    /// `DS.StateLayer.hover` value when hovered — the production `buttonWashOpacity` mapping.
    @Test func buttonWashOpacityLiftsOnHover() {
        #expect(MenuPanelHoverStyle.buttonWashOpacity(isHovered: false) == 0, "no wash at rest")
        #expect(MenuPanelHoverStyle.buttonWashOpacity(isHovered: true) == DS.StateLayer.hover,
                "the wash lifts to the shared state-layer value on hover")
        #expect(MenuPanelHoverStyle.buttonWashOpacity(isHovered: true) > 0, "the hovered wash is a real, visible lift")
    }

    /// A text field's border brightens on hover: hidden (opacity 0) at rest, fully shown
    /// (opacity 1) on hover — the production `fieldBorderOpacity` mapping.
    @Test func fieldBorderBrightensOnHover() {
        #expect(MenuPanelHoverStyle.fieldBorderOpacity(isHovered: false) == 0, "border hidden at rest")
        #expect(MenuPanelHoverStyle.fieldBorderOpacity(isHovered: true) == 1, "border fully shown on hover")
    }

    /// A toggle row lifts a faint full-row highlight on hover: 0 at rest, a real positive fill
    /// on hover — the production `rowHighlightOpacity` mapping.
    @Test func toggleRowHighlightLiftsOnHover() {
        #expect(MenuPanelHoverStyle.rowHighlightOpacity(isHovered: false) == 0, "no row highlight at rest")
        #expect(MenuPanelHoverStyle.rowHighlightOpacity(isHovered: true) > 0, "a faint row highlight lifts on hover")
        #expect(MenuPanelHoverStyle.rowHighlightOpacity(isHovered: true) == 0.04, "the documented faint row-highlight opacity")
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

    // MARK: - SwiftUI Color comparison (for the pure hover-mapping assertions)

    /// Two SwiftUI `Color`s are equal (within tolerance) once resolved to sRGB RGBA. Compares
    /// alpha too, so `Color.clear` (α 0) and `Color.white.opacity(0.06)` are distinguishable.
    private func sameColor(_ lhs: Color, _ rhs: Color, tolerance: CGFloat = 0.001) -> Bool {
        guard let lhsRGBA = NSColor(lhs).usingColorSpace(.sRGB),
              let rhsRGBA = NSColor(rhs).usingColorSpace(.sRGB) else { return false }
        return abs(lhsRGBA.redComponent - rhsRGBA.redComponent) < tolerance
            && abs(lhsRGBA.greenComponent - rhsRGBA.greenComponent) < tolerance
            && abs(lhsRGBA.blueComponent - rhsRGBA.blueComponent) < tolerance
            && abs(lhsRGBA.alphaComponent - rhsRGBA.alphaComponent) < tolerance
    }

    /// The sRGB alpha of a SwiftUI `Color` — used to assert a fill lifts from transparent.
    private func alpha(_ color: Color) -> CGFloat {
        NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 0
    }
}
