//
//  DesignSystem.swift
//  Clawdy
//
//  Centralized design system using the OpenClaw red accent on dark surfaces.
//  Colors, typography, spacing, corner radii, and interaction tokens are
//  defined here as the single source of truth. The compact shared controls
//  built on these tokens live in DesignSystemControls.swift.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(hex: "#171918")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(hex: "#202221")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#272A29")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text used on top of the accent fill (#C42B22 red), like the primary button label.
        /// White on #C42B22 achieves ~5.65:1 contrast — WCAG AA compliant.
        /// White on #B4271F hover achieves ~6.5:1 — also WCAG AA compliant.
        static let textOnAccent: Color = .white

        // ── Tailwind Blue Scale ─────────────────────────────────────
        // Full Tailwind CSS v4 blue palette for consistent blue usage.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest blue — near-black tinted backgrounds

        static let blue50  = Color(hex: "#eff6ff")
        static let blue100 = Color(hex: "#dbeafe")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue300 = Color(hex: "#93c5fd")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")
        static let blue950 = Color(hex: "#172554")

        // ── Accent (unified with the overlay cursor — single source of truth) ──
        // The in-app accent and the pointing cursor are the SAME OpenClaw red family so
        // the whole product reads as one system. `openClawRedHex` is the ONE canonical
        // brand value; `openClawRed` is derived from it and every accent surface routes
        // through it. The overlay cursor (`overlayCursorBlue`) uses the AA-safe deeper
        // shade `openClawRedButtonFill` because it fills behind white bubble text.

        /// The legacy Clawdy blue — retained as a named token for reference, but no longer
        /// the brand accent (the brand migrated to `openClawRed`). Kept defined so any
        /// remaining non-brand blue graphic can still reference the exact original hue.
        static let clawdyBlue = Color(hex: "#3380FF")

        /// The OpenClaw brand-red HEX — the ONE canonical string the whole brand red
        /// derives from. The SwiftUI `openClawRed` Color below is built from it, AND the
        /// annotation stroke burned into the screenshot derives from it too: the pure
        /// `AnnotationImageCompositor` reads `openClawRedComponents` (parsed from this same
        /// string) instead of its own literals, so the SwiftUI accent and the composited
        /// stroke can NEVER drift. Retune the brand red by editing this ONE value.
        static let openClawRedHex = "E5342B"

        /// The brand red decomposed into sRGB components (0…1), parsed once from
        /// `openClawRedHex`. This is the shared source the CoreGraphics annotation
        /// compositor consumes (as `CGFloat`s) so the composited-into-screenshot stroke is
        /// byte-for-byte the same red as the SwiftUI accent / live overlay stroke.
        static let openClawRedComponents: (red: Double, green: Double, blue: Double) =
            Color.sRGBComponents(fromHex: openClawRedHex)

        /// The OpenClaw brand red — the SINGLE source of truth for the brand accent.
        /// Backs the aura/glow (see `ClawdyGlow`) AND every in-app accent surface (links,
        /// selection, status text, icons) via the `accent` family below. Non-text-fill
        /// red graphics (annotation strokes, toast triangle, hot-reload glow) also derive
        /// from this. DERIVED from `openClawRedHex` so there is exactly one hex literal.
        static let openClawRed = Color(
            red: openClawRedComponents.red,
            green: openClawRedComponents.green,
            blue: openClawRedComponents.blue
        )

        /// AA-safe filled-button red — a slightly deeper shade of `openClawRed` used ONLY
        /// as the filled background behind WHITE button labels (e.g. CTAs, the results-window
        /// "Updated" pill), so white-on-fill clears WCAG AA. `openClawRed` (#E5342B) on
        /// white text is only ~4.32:1 (below the 4.5:1 minimum); this deeper red restores
        /// legibility while still reading as the same red family. The brand red is
        /// UNCHANGED — this token is the ONE surface (white text on a solid fill) that
        /// needs it. #C42B22 on #FFFFFF ≈ 5.65:1 (AA pass).
        static let openClawRedButtonFill = Color(hex: "#C42B22")

        /// Accent fill — used for every in-app accent (pills, strokes, icons, text
        /// accents, selection tints). Unified to the OpenClaw brand red.
        static let accent = openClawRed

        /// Primary-BUTTON fill — the AA-safe deeper red used ONLY as the filled background
        /// behind WHITE button labels (e.g. the results-window "Updated" pill), so
        /// white-on-fill clears WCAG AA. See `openClawRedButtonFill` for the contrast math.
        static let accentButtonFill = openClawRedButtonFill

        /// Accent hover — slightly darker shade of the brand red for hover state.
        /// The hover path DARKENS (never a white wash, which would drop white labels below AA).
        static let accentHover = Color(hex: "#B4271F")

        /// Accent text — accent-colored text and icons on dark backgrounds (links,
        /// active nav items, highlighted labels). The SAME brand red as the fills
        /// so text and fills read as one system.
        static let accentText = openClawRed

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Derived from the brand red so it stays in the family.
        static let accentSubtle = openClawRed.opacity(0.10)

        /// Slightly stronger accent tint — used for a SELECTED segment in a segmented
        /// picker (engine / voice) so the active choice reads as the brand red while its
        /// label stays legible as `accentText` on top. Derived from the brand red.
        static let accentSelectedFill = openClawRed.opacity(0.16)

        // ── AppKit (NSColor) bridges ─────────────────────────────────
        // AppKit chrome (Core Animation layers, NSView backgrounds) can't take a
        // SwiftUI `Color`, so these expose the SAME canonical tokens as `NSColor`.
        // They are BRIDGED from the SwiftUI values (not re-typed hex) so there is
        // still exactly one source of truth for each blue.

        /// `clawdyBlue` as an NSColor — the legacy blue bridge, retained for any non-brand
        /// blue graphic that still needs the original hue. No longer the cursor/accent color
        /// (the brand migrated to `openClawRed`).
        static let clawdyBlueNSColor = NSColor(clawdyBlue)

        /// `openClawRedButtonFill` as an NSColor — the AA-safe deeper red for AppKit fills
        /// that sit behind WHITE TEXT (e.g. the results-window "Updated" pill).
        static let openClawRedButtonFillNSColor = NSColor(openClawRedButtonFill)

        /// `accentButtonFill` as an NSColor — the AA-safe deeper red for AppKit fills
        /// that sit behind WHITE TEXT (e.g. the results-window "Updated" pill).
        static let accentButtonFillNSColor = NSColor(accentButtonFill)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the red accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// Lighter than accentText so informational elements are visually distinct
        /// from interactive accent-colored elements.
        static let info = Color(hex: "#70B8FF")               // Radix Blue 9

        /// Inline code text color — slightly brighter blue for monospace code snippets.
        static let codeText = Color(hex: "#9DC2FF")           // Radix Blue 11 variant

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow. Uses the AA-safe deeper red
        /// (`openClawRedButtonFill`, #C42B22) rather than the lighter `openClawRed`
        /// because this token is the FILL behind WHITE normal-weight text in several
        /// overlay speech/response bubbles (white-on-#E5342B is only 4.32:1, below AA;
        /// white-on-#C42B22 is 5.65:1). Its other uses (the cursor triangle, listening
        /// waveform bars, processing spinner) are pure graphics with no text, so the
        /// deeper red is equally fine there. Kept as a named alias so the overlay code
        /// reads intent ("the cursor color") while sharing a single source of truth.
        static let overlayCursorBlue = openClawRedButtonFill

        // ── Floating Button Gradient ─────────────────────────────────

        /// The floating session button gradient colors (unchanged from original —
        /// this gradient is intentionally distinct from the rest of the palette
        /// to make the floating button stand out as a "jewel" on the desktop).
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background in the help chat.
        /// Blue 800 — deep blue that's clearly distinct from the dark surface
        /// while keeping white text highly readable (~9:1 contrast).
        static let helpChatUserBubble = blue800

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static let helpChatUserBubbleHover = blue700

        /// Footer/backdrop behind the floating help chat.
        /// Slightly lighter than the main window background so the chat zone reads
        /// as a distinct docked surface even before the pill input is visible.
        static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing

    /// The padding / gap scale. Values are chosen to cover the padding literals the
    /// app actually uses across its overlay controls and panels (surveyed from the
    /// real `.padding(...)` call sites), so adoption in later phases can replace the
    /// numeric literals 1:1 without changing any layout. All cases are module-internal
    /// (accessible anywhere in the target). This phase only DEFINES the scale — no call
    /// site is migrated yet.
    enum Spacing {
        /// Hairline gap — 2pt (e.g. the toast title/status vertical spacing).
        static let hairline: CGFloat = 2
        /// Extra small — 4pt.
        static let xs: CGFloat = 4
        /// Compact — 5pt, the tight inset on the small circular icon buttons.
        static let compact: CGFloat = 5
        /// Snug — 6pt, common compact control padding.
        static let snug: CGFloat = 6
        /// Small — 8pt.
        static let sm: CGFloat = 8
        /// Control — 10pt, the single most common control padding across overlays.
        static let control: CGFloat = 10
        /// Medium — 12pt.
        static let md: CGFloat = 12
        /// Comfortable — 14pt, the toast's horizontal content inset.
        static let comfortable: CGFloat = 14
        /// Large — 16pt.
        static let lg: CGFloat = 16
        /// Extra large — 20pt.
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Typography

    /// The typography scale capturing EVERY recurring inline `.system(size:weight:)`
    /// font across the app. Each token maps 1:1 onto an EXISTING size/weight pairing
    /// that appears more than once in the codebase — this is a NAMING layer only; it
    /// does not change any rendered font. The set was derived by enumerating the
    /// distinct (size, weight) pairs actually in use, so Phase 2 can replace every real
    /// font call site with a token 1:1 with no appearance change. One-off sizes/weights
    /// (9 medium, 15, 18, 30, the two `design:` variants, etc.) intentionally have NO
    /// token — only recurring pairs do. Adoption at call sites is a later phase.
    ///
    /// Note on the `*Regular` tokens: SwiftUI renders a weightless `.system(size: N)`
    /// as regular, so each `*Regular` token covers BOTH the explicit
    /// `.system(size: N, weight: .regular)` sites and the bare `.system(size: N)` sites
    /// (they render identically here — no ambient `.fontWeight` overrides them).
    enum Font {
        // ── size 10 — micro tier ─────────────────────────────────────
        /// 10pt regular — the smallest secondary text. Covers `.system(size: 10)`.
        static let microCaption: SwiftUI.Font = .system(size: 10, weight: .regular)
        /// 10pt semibold — emphasized micro text.
        static let microCaptionEmphasized: SwiftUI.Font = .system(size: 10, weight: .semibold)
        /// 10pt bold — the compact circular icon-button glyph.
        static let iconGlyph: SwiftUI.Font = .system(size: 10, weight: .bold)

        // ── size 11 — caption tier ───────────────────────────────────
        /// 11pt regular — plain caption text. Covers `.system(size: 11)`.
        static let overlayCaptionRegular: SwiftUI.Font = .system(size: 11, weight: .regular)
        /// 11pt medium — the most common caption text (toast task label, small hints,
        /// list row subtitles).
        static let overlayCaption: SwiftUI.Font = .system(size: 11, weight: .medium)
        /// 11pt semibold — an emphasized caption (small headers, status emphasis).
        static let overlayCaptionEmphasized: SwiftUI.Font = .system(size: 11, weight: .semibold)

        // ── size 12 — body tier ──────────────────────────────────────
        /// 12pt regular — plain body text. Covers `.system(size: 12)`.
        static let overlayBodyRegular: SwiftUI.Font = .system(size: 12, weight: .regular)
        /// 12pt medium — standard overlay body text.
        static let overlayBody: SwiftUI.Font = .system(size: 12, weight: .medium)
        /// 12pt semibold — control labels (the "+N more" / "show less" / collapse rows).
        static let controlLabel: SwiftUI.Font = .system(size: 12, weight: .semibold)
        /// 12pt bold — emphasized body / small numeric emphasis.
        static let overlayBodyBold: SwiftUI.Font = .system(size: 12, weight: .bold)

        // ── size 13 — detail tier ────────────────────────────────────
        /// 13pt regular — plain detail body text. Covers `.system(size: 13)`.
        static let detailBodyRegular: SwiftUI.Font = .system(size: 13, weight: .regular)
        /// 13pt medium — the larger detail body text (chat bubbles, detail rows).
        static let detailBody: SwiftUI.Font = .system(size: 13, weight: .medium)
        /// 13pt semibold — text link / pill labels (e.g. "View results ›").
        static let linkLabel: SwiftUI.Font = .system(size: 13, weight: .semibold)

        // ── size 14 — title tier ─────────────────────────────────────
        /// 14pt semibold — small section titles / prominent labels.
        static let title: SwiftUI.Font = .system(size: 14, weight: .semibold)
        /// 14pt bold — the boldest small-title variant.
        static let titleBold: SwiftUI.Font = .system(size: 14, weight: .bold)

        // ── size 16 — CTA ────────────────────────────────────────────
        /// 16pt medium — the primary call-to-action label size.
        static let cta: SwiftUI.Font = .system(size: 16, weight: .medium)
    }

    // MARK: - Corner Radii

    /// The single source of truth for corner radii. The cases cover every radius the
    /// app actually renders (surveyed from the real `cornerRadius:` call sites): HUD
    /// bubbles 6, view-results pill 7, clarification field 8, composer field 9, control
    /// rows / results pill 10, results pill 11, toast 12, clarification card 14, detail
    /// panel 16. The original generic `small/medium/large/extraLarge/pill` names are
    /// KEPT (they already have call sites — renaming would break them); the additional
    /// semantic cases fill the gaps so no surface needs a bare numeric literal. This
    /// phase only completes the enum — call sites are migrated in a later phase.
    enum CornerRadius {
        /// 6pt — small elements like tags, badges, and the HUD bubbles.
        static let small: CGFloat = 6
        /// 7pt — the compact "View results ›" pill.
        static let viewResultsPill: CGFloat = 7
        /// 8pt — buttons, input fields, small cards, and the clarification text field.
        static let medium: CGFloat = 8
        /// 9pt — the follow-up composer text field.
        static let composerField: CGFloat = 9
        /// 10pt — cards, dialogs, chat bubbles, control rows, and the results pill.
        static let large: CGFloat = 10
        /// 11pt — the alternate results pill radius.
        static let resultsPill: CGFloat = 11
        /// 12pt — large panels, permission cards, and the research toast surface.
        static let extraLarge: CGFloat = 12
        /// 14pt — the clarification card.
        static let clarificationCard: CGFloat = 14
        /// 16pt — the research detail / recents-list panel.
        static let detailPanel: CGFloat = 16
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Parse a hex string like "#FF5733" or "FF5733" into sRGB components in 0…1.
    /// Shared by `init(hex:)` AND the design-system brand-color derivation
    /// (`DS.Colors.openClawRedComponents`) so hex parsing lives in exactly one place —
    /// the annotation compositor can read the same components the accent Color is built
    /// from without re-implementing the parse.
    static func sRGBComponents(fromHex hex: String) -> (red: Double, green: Double, blue: Double) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        return (red: red, green: green, blue: blue)
    }

    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let components = Color.sRGBComponents(fromHex: hex)
        self.init(red: components.red, green: components.green, blue: components.blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
