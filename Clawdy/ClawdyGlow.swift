//
//  ClawdyGlow.swift
//  Clawdy
//
//  The ONE reusable "Clawdy aura glow" primitive.
//
//  A single, shared SwiftUI modifier — `clawdyGlow(...)` / `ClawdyGlowModifier` — that
//  wraps a surface in a soft OUTER aura built from the OpenClaw brand red
//  (`DS.Colors.openClawRed` == #E5342B). Every surface that wants the "this is a Clawdy
//  thing" glow (toast, menu, results window, Recent Research …) applies THIS modifier so
//  the whole product reads as one system and the glow is tuned in exactly one place.
//
//  WHY layered red SHADOWS on a background rounded-rect (and NOT a hard stroke, a raw
//  blurred fill, or a gray shadow):
//    • It follows the ROUNDED silhouette. The aura is cast by a `RoundedRectangle` that
//      shares the caller's `cornerRadius` and sits BEHIND the content; its layered
//      `.shadow`s bloom outward following those rounded corners, so the halo hugs the
//      shape instead of leaking a square/rectangular ring. (We just removed an accidental
//      GRAY rectangular halo artifact from the toast — this primitive is the deliberate,
//      unambiguously-RED replacement.)
//    • It is an OUTER aura only. The shadow-casting rounded-rect is the SAME size as the
//      content and sits behind it, so an OPAQUE surface (e.g. the toast's `surface1`
//      #171918 pill) fully occludes it — only the soft shadow bloom that spills past the
//      edges shows. The glow therefore never washes over / lowers the contrast of the
//      text and content drawn on top of the surface.
//    • It is pure red. Each shadow layer is tinted with `DS.Colors.openClawRed`, so the
//      bloom stays a clean red hue — never the gray/translucent ring a default (black)
//      or mis-tuned shadow produces.
//    • It renders reliably. A shadow is drawn by the view layer and captured by
//      `cacheDisplay`/`ImageRenderer` bleeding PAST the view bounds — a raw `.blur`ed fill
//      in a `.background` gets clipped to the layer bounds and never reaches the pixels
//      outside the shape, so it can't be verified (or seen) as an aura.
//
//  MARGIN SAFETY (must be applied inside a transparent overlay panel):
//    The overlay panels this glow is destined for carry ~18pt of CLEAR shadow-margin
//    around their content. A SwiftUI `.blur(radius: R)` blooms visibly out to roughly
//    1.2–1.4 × R. To render as a CLEAN aura (and NOT get clipped into a hard rectangle by
//    the window bounds) the glow's outer bloom must fit inside that margin:
//
//        visibleBloom ≈ bloomFactor (1.3) × glowRadius  ≤  overlayPanelMargin (18pt)
//        ⇒ MAX SAFE glowRadius = floor(18 / 1.3) = 13pt   (13 × 1.3 = 16.9pt ≤ 18pt)
//
//    The default (`defaultRadius` = 10pt, bloom = 13pt) sits comfortably inside the 18pt
//    margin. `maximumSafeRadius` (13pt, DERIVED from `overlayPanelMargin` / `bloomFactor`)
//    is the ceiling for that same margin; a surface with a larger clear margin may pass a
//    bigger radius, but 13pt is the safe default ceiling the tests assert against. The
//    bloom relationship is asserted in code against the named `bloomFactor` /
//    `overlayPanelMargin` constants, so raising the ceiling past the safe value fails a test.
//

import SwiftUI

// MARK: - Clawdy Glow Tuning Constants

/// Namespace for the shared aura glow's canonical color and tuning constants.
/// All numbers the glow depends on live here so the aura is tuned in exactly one place.
enum ClawdyGlow {

    /// The aura color — the OpenClaw brand red (#E5342B). Routing through `DS.Colors`
    /// keeps the glow's tint in a single source of truth (the same brand red now backs the
    /// accent surfaces and the pointing cursor via `DS.Colors.openClawRed`).
    static let glowColor: Color = DS.Colors.openClawRed

    /// Default corner radius for the aura's rounded silhouette. Matches the toast pill
    /// (`r = 12`); callers pass their own surface's radius so the halo hugs their corners.
    static let defaultCornerRadius: CGFloat = 12

    /// Default glow (blur) radius in points. Bloom = 1.3 × 10 = 13pt — a soft, contained
    /// aura that fits inside the ~18pt clear shadow-margin of the overlay panels.
    static let defaultRadius: CGFloat = 10

    /// The clear shadow-margin (points) the transparent overlay panels carry around their
    /// content. The glow's visible bloom must fit inside this so it renders as a clean
    /// aura and is NOT clipped into a hard rectangle by the window bounds.
    static let overlayPanelMargin: CGFloat = 18

    /// How far a SwiftUI `.blur(radius: R)` / layer shadow visibly blooms, as a multiple of
    /// its radius (empirically ≈ 1.3 × R). Used to size the safe-radius ceiling against the
    /// panel margin.
    static let bloomFactor: CGFloat = 1.3

    /// The MAXIMUM glow radius that still renders as a clean aura inside `overlayPanelMargin`
    /// — DERIVED so the relationship is self-consistent: the largest whole-point radius whose
    /// bloom (`radius × bloomFactor`) fits within the margin. With an 18pt margin and a 1.3×
    /// bloom this floors to 13pt (13 × 1.3 = 16.9pt ≤ 18pt). Larger radii risk the outer
    /// bloom being clipped into a hard rectangle by the window bounds; surfaces with more
    /// clear margin may exceed this deliberately.
    static let maximumSafeRadius: CGFloat = (overlayPanelMargin / bloomFactor).rounded(.down)

    /// Default intensity multiplier (1.0 = the tuned baseline). Subtler surfaces pass a
    /// value below 1.0; stronger, attention-drawing surfaces pass above 1.0.
    static let defaultIntensity: Double = 1.0

    // ── Two-layer falloff ────────────────────────────────────────────────────────
    // The aura is cast by ONE background rounded-rect wearing TWO stacked red `.shadow`s
    // that share the caller's corner radius: a WIDE, faint outer bloom plus a TIGHTER,
    // brighter inner halo that hugs the silhouette. Layering (rather than one shadow)
    // gives a natural, candle-like falloff.

    /// Base opacity of the wide, soft OUTER shadow bloom (full glow radius, faintest).
    static let outerLayerOpacity: Double = 0.45

    /// Base opacity of the tighter, brighter INNER shadow halo that defines the red edge.
    static let innerLayerOpacity: Double = 0.65

    /// The inner halo is cast at this FRACTION of the glow radius, so it hugs the
    /// silhouette more tightly than the full-radius outer bloom.
    static let innerLayerRadiusFraction: CGFloat = 0.5
}

// MARK: - Clawdy Glow View Modifier

/// Renders the shared soft red OUTER aura behind a surface, following the surface's
/// rounded-rect silhouette. Apply via `someSurface.clawdyGlow()`.
///
/// The aura is cast by a `RoundedRectangle` wearing two stacked red `.shadow`s in a
/// `.background`, so it sits BEHIND the content and an opaque surface occludes the aura's
/// interior — the glow is a clean outer bloom that never washes the content it surrounds.
struct ClawdyGlowModifier: ViewModifier {

    /// Corner radius the aura's rounded silhouette follows — pass the surface's own radius.
    let cornerRadius: CGFloat

    /// Blur radius of the outer bloom, in points. Keep at or below
    /// `ClawdyGlow.maximumSafeRadius` when inside a transparent overlay panel.
    let glowRadius: CGFloat

    /// Multiplier on the aura's opacity. 1.0 is the tuned baseline; lower is subtler.
    let intensity: Double

    func body(content: Content) -> some View {
        content
            .background(alignment: .center) {
                // One rounded-rect the SAME size as the content, filled with the brand red
                // and wearing two stacked red shadows. The opaque surface on top occludes
                // this shape entirely; only the shadow bloom that spills past the edges —
                // following the rounded corners — shows, as the outer aura.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ClawdyGlow.glowColor)
                    // Inner halo — tighter and brighter, hugging the silhouette edge so the
                    // aura reads unmistakably as RED right at the shape's outline.
                    .shadow(
                        color: ClawdyGlow.glowColor.opacity(ClawdyGlow.innerLayerOpacity * intensity),
                        radius: glowRadius * ClawdyGlow.innerLayerRadiusFraction
                    )
                    // Outer bloom — full radius, faintest. Gives the aura its soft reach.
                    .shadow(
                        color: ClawdyGlow.glowColor.opacity(ClawdyGlow.outerLayerOpacity * intensity),
                        radius: glowRadius
                    )
                    // The decorative aura is non-interactive.
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - View Extension

extension View {

    /// Wraps this surface in the shared Clawdy aura glow — a soft OUTER red bloom
    /// that follows the given `cornerRadius`. Intended for OPAQUE surfaces (the surface
    /// occludes the aura's interior, so the content is never washed).
    ///
    /// - Parameters:
    ///   - cornerRadius: The corner radius the aura follows. Pass the surface's own radius
    ///     so the halo hugs its corners. Defaults to `ClawdyGlow.defaultCornerRadius`.
    ///   - radius: The glow (blur) radius in points. Keep ≤ `ClawdyGlow.maximumSafeRadius`
    ///     (14pt) inside a transparent overlay panel with ~18pt of clear margin.
    ///     Defaults to `ClawdyGlow.defaultRadius` (10pt).
    ///   - intensity: Opacity multiplier on the aura (1.0 = tuned baseline). Pass below
    ///     1.0 for a subtler glow, above 1.0 for a stronger one.
    ///     Defaults to `ClawdyGlow.defaultIntensity`.
    func clawdyGlow(
        cornerRadius: CGFloat = ClawdyGlow.defaultCornerRadius,
        radius: CGFloat = ClawdyGlow.defaultRadius,
        intensity: Double = ClawdyGlow.defaultIntensity
    ) -> some View {
        modifier(
            ClawdyGlowModifier(
                cornerRadius: cornerRadius,
                glowRadius: radius,
                intensity: intensity
            )
        )
    }
}
