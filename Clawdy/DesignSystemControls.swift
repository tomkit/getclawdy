//
//  DesignSystemControls.swift
//  Clawdy
//
//  Canonical, COMPACT shared SwiftUI controls tuned to the app's real overlay look
//  (11–13pt), built on the DesignSystem tokens. These replace the per-surface ad-hoc
//  control recipes that are currently duplicated across the research overlays:
//    - `CircularIconButton`  ← unifies `ResearchToastIconButton` + `ResearchRecentsInlineIconButton`
//    - `TextLinkButton`      ← the "View results ›" text-link recipe
//    - `ControlRowButton`    ← unifies `ResearchStackControlRowButton` + `ResearchStackCollapseButton`
//
//  Every control here is LAYOUT-STABLE: hover only changes background / opacity / text
//  color, NEVER the frame. That invariant is what the earlier hover-resize fixes
//  established, so keeping it here means adopting these controls can never re-introduce
//  a hover-driven layout jump.
//
//  This file only DEFINES these controls. Existing call sites are migrated in a later
//  phase, so the duplicated recipes still live in their feature files for now — these
//  reproduce their CURRENT rendered look exactly so the migration is appearance-neutral.
//

import SwiftUI

// MARK: - Shared hover primitive

/// The ONE shared hover treatment for the compact controls: it owns nothing itself
/// (the caller keeps the `@State` so the control can drive its own color/opacity from
/// the hover flag) but centralizes the two things every control previously wired up by
/// hand — reporting pointer enter/leave into the caller's flag AND the pointing-hand
/// cursor. `showsPointerCursor` exists because some overlay panels never become key, so
/// the `addCursorRect`-based `.pointerCursor()` is dead there and is intentionally
/// omitted (the panel supplies the cursor via its own tracking area instead).
struct HoverStateModifier: ViewModifier {
    @Binding var isHovering: Bool
    var showsPointerCursor: Bool

    func body(content: Content) -> some View {
        content
            .pointerCursor(isEnabled: showsPointerCursor)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

extension View {
    /// Reports hover into `isHovering` and (optionally) shows the pointing-hand cursor.
    /// The shared replacement for the ad-hoc `.pointerCursor().onHover { ... }` pair each
    /// compact control used to repeat.
    func trackingHover(_ isHovering: Binding<Bool>, showsPointerCursor: Bool = true) -> some View {
        modifier(HoverStateModifier(isHovering: isHovering, showsPointerCursor: showsPointerCursor))
    }
}

// MARK: - Pure appearance logic (unit-tested)

/// The pure, AppKit-free hover→appearance mapping shared by the compact controls. Kept
/// separate from the SwiftUI views so the exact resting/hover color + opacity decisions
/// can be unit-tested without rendering a view. Every value here reproduces the current
/// look of the recipe it canonicalizes.
enum DSControlAppearance {

    // ── Circular icon button ─────────────────────────────────────────
    // Reproduces `ResearchToastIconButton` / `ResearchRecentsInlineIconButton`.

    /// The glyph color — muted at rest, primary on hover.
    static func circularIconForeground(isHovering: Bool) -> Color {
        isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary
    }

    /// The circular fill — surface2 at rest, surface3 on hover.
    static func circularIconBackground(isHovering: Bool) -> Color {
        isHovering ? DS.Colors.surface3 : DS.Colors.surface2
    }

    // ── Text link ────────────────────────────────────────────────────
    // Opacity-only hover so the frame is untouched.

    /// The text-link opacity — slightly dimmed at rest, full on hover.
    static func textLinkOpacity(isHovering: Bool) -> Double {
        isHovering ? 1.0 : 0.85
    }

    // ── Control row button ───────────────────────────────────────────
    // Reproduces `ResearchStackControlRowButton` / `ResearchStackCollapseButton`.

    /// The label color — muted at rest, primary on hover.
    static func controlRowForeground(isHovering: Bool) -> Color {
        isHovering ? DS.Colors.textPrimary : DS.Colors.textSecondary
    }

    /// The row fill — surface1 at rest, surface3 on hover, both at 0.97 opacity so the
    /// dark surface behind reads through very slightly (matching the current recipe).
    static func controlRowFill(isHovering: Bool) -> Color {
        (isHovering ? DS.Colors.surface3 : DS.Colors.surface1).opacity(0.97)
    }
}

// MARK: - Circular icon button

/// A compact circular icon button — the canonical form of the icon control duplicated
/// as `ResearchToastIconButton` and `ResearchRecentsInlineIconButton`. The ONLY reason
/// those two differed was the pointer cursor (the recents-list variant lives on a panel
/// that never becomes key, so its `addCursorRect` cursor is dead), so that difference is
/// a single `showsPointerCursor` flag here. Layout-stable: hover swaps the glyph color
/// and the circular fill only.
struct CircularIconButton: View {
    let systemName: String
    let helpText: String
    var iconSize: CGFloat = 10
    var padding: CGFloat = 5
    /// Opt OUT of the pointing-hand cursor on panels that never become key window
    /// (where `.pointerCursor()`'s cursor rect is dead anyway).
    var showsPointerCursor: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundColor(DSControlAppearance.circularIconForeground(isHovering: isHovering))
                .padding(padding)
                .background(Circle().fill(DSControlAppearance.circularIconBackground(isHovering: isHovering)))
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering, showsPointerCursor: showsPointerCursor)
        .help(helpText)
    }
}

// MARK: - Text link button

/// A compact text-link / pill button — the canonical form of the "View results ›"
/// recipe. Constant padding, opacity-only hover (so the frame never moves). Defaults to
/// the accent color and the 13pt-semibold link label; callers can override the color and
/// padding for a pill-shaped variant.
struct TextLinkButton: View {
    let title: String
    var color: Color = DS.Colors.accent
    var horizontalPadding: CGFloat = 0
    var verticalPadding: CGFloat = 0
    var showsPointerCursor: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.linkLabel)
                .foregroundColor(color)
                .opacity(DSControlAppearance.textLinkOpacity(isHovering: isHovering))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering, showsPointerCursor: showsPointerCursor)
    }
}

// MARK: - Control row button

/// A compact full-width control-row button — the canonical form of the recipe
/// duplicated as `ResearchStackControlRowButton` (the "+N more" / "show less" row) and
/// `ResearchStackCollapseButton` (the "collapse" row, which adds a leading glyph). An
/// optional `systemImage` covers the collapse variant. Layout-stable: hover swaps the
/// label color and the rounded fill only, never the frame.
struct ControlRowButton: View {
    let label: String
    var systemImage: String? = nil
    let helpText: String
    /// An explicit content width so stacked rows line up (the callers pass their pill
    /// width). `nil` lets the row size to its content.
    var width: CGFloat? = nil
    var showsPointerCursor: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            rowContent
                .foregroundColor(DSControlAppearance.controlRowForeground(isHovering: isHovering))
                .frame(width: width)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DSControlAppearance.controlRowFill(isHovering: isHovering))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering, showsPointerCursor: showsPointerCursor)
        .help(helpText)
    }

    @ViewBuilder
    private var rowContent: some View {
        if let systemImage {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(DS.Font.controlLabel)
            }
        } else {
            Text(label)
                .font(DS.Font.controlLabel)
        }
    }
}
