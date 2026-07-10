//
//  DesignSystemControlsTests.swift
//  ClawdyTests
//
//  Tests for the pure hover→appearance logic behind the canonical compact controls
//  (`DSControlAppearance`) plus the completeness of the token layer this phase adds
//  (`DS.Font`, `DS.CornerRadius`, `DS.Spacing`). The SwiftUI controls themselves are
//  thin wrappers over these pure decisions, so testing the decisions covers the
//  layout-stable, appearance-neutral contract without rendering a view.
//

import Testing
import SwiftUI
@testable import Clawdy

struct DesignSystemControlsTests {

    // MARK: - Circular icon button appearance

    @Test func circularIconForegroundMutedAtRestPrimaryOnHover() {
        #expect(DSControlAppearance.circularIconForeground(isHovering: false) == DS.Colors.textSecondary)
        #expect(DSControlAppearance.circularIconForeground(isHovering: true) == DS.Colors.textPrimary)
    }

    @Test func circularIconBackgroundSurface2AtRestSurface3OnHover() {
        #expect(DSControlAppearance.circularIconBackground(isHovering: false) == DS.Colors.surface2)
        #expect(DSControlAppearance.circularIconBackground(isHovering: true) == DS.Colors.surface3)
    }

    // MARK: - Text link appearance (opacity-only hover, layout-stable)

    @Test func textLinkDimmedAtRestFullOnHover() {
        #expect(DSControlAppearance.textLinkOpacity(isHovering: false) == 0.85)
        #expect(DSControlAppearance.textLinkOpacity(isHovering: true) == 1.0)
    }

    // MARK: - Control row appearance

    @Test func controlRowForegroundMutedAtRestPrimaryOnHover() {
        #expect(DSControlAppearance.controlRowForeground(isHovering: false) == DS.Colors.textSecondary)
        #expect(DSControlAppearance.controlRowForeground(isHovering: true) == DS.Colors.textPrimary)
    }

    @Test func controlRowFillSurface1AtRestSurface3OnHoverBothSlightlyTranslucent() {
        #expect(DSControlAppearance.controlRowFill(isHovering: false) == DS.Colors.surface1.opacity(0.97))
        #expect(DSControlAppearance.controlRowFill(isHovering: true) == DS.Colors.surface3.opacity(0.97))
    }

    // MARK: - showsPointerCursor opt-out is honored on the shared controls

    // The opt-out is plumbed as a stored config on each control that it forwards into the
    // shared `HoverStateModifier` (whose `showsPointerCursor` gates `.pointerCursor`).
    // The observable contract is therefore: the flag defaults ON, and the value the caller
    // passes is the value the control carries into the hover modifier.

    @Test func hoverStateModifierCarriesPointerCursorFlag() {
        let optedOut = HoverStateModifier(isHovering: .constant(false), showsPointerCursor: false)
        let optedIn = HoverStateModifier(isHovering: .constant(false), showsPointerCursor: true)
        #expect(optedOut.showsPointerCursor == false)
        #expect(optedIn.showsPointerCursor == true)
    }

    @Test func circularIconButtonHonorsPointerCursorOptOut() {
        let defaulted = CircularIconButton(systemName: "xmark", helpText: "close", action: {})
        let optedOut = CircularIconButton(systemName: "xmark", helpText: "close", showsPointerCursor: false, action: {})
        #expect(defaulted.showsPointerCursor == true)
        #expect(optedOut.showsPointerCursor == false)
    }

    @Test func textLinkButtonHonorsPointerCursorOptOut() {
        let defaulted = TextLinkButton(title: "View results ›", action: {})
        let optedOut = TextLinkButton(title: "View results ›", showsPointerCursor: false, action: {})
        #expect(defaulted.showsPointerCursor == true)
        #expect(optedOut.showsPointerCursor == false)
    }

    @Test func controlRowButtonHonorsPointerCursorOptOut() {
        let defaulted = ControlRowButton(label: "+2 more", helpText: "show all", action: {})
        let optedOut = ControlRowButton(label: "+2 more", helpText: "show all", showsPointerCursor: false, action: {})
        #expect(defaulted.showsPointerCursor == true)
        #expect(optedOut.showsPointerCursor == false)
    }

    // MARK: - Typography scale maps 1:1 onto EVERY recurring inline (size, weight) pair

    @Test func fontScaleMapsEveryRecurringPairOneToOne() {
        // size 10
        #expect(DS.Font.microCaption == .system(size: 10, weight: .regular))
        #expect(DS.Font.microCaptionEmphasized == .system(size: 10, weight: .semibold))
        #expect(DS.Font.iconGlyph == .system(size: 10, weight: .bold))
        // size 11
        #expect(DS.Font.overlayCaptionRegular == .system(size: 11, weight: .regular))
        #expect(DS.Font.overlayCaption == .system(size: 11, weight: .medium))
        #expect(DS.Font.overlayCaptionEmphasized == .system(size: 11, weight: .semibold))
        // size 12
        #expect(DS.Font.overlayBodyRegular == .system(size: 12, weight: .regular))
        #expect(DS.Font.overlayBody == .system(size: 12, weight: .medium))
        #expect(DS.Font.controlLabel == .system(size: 12, weight: .semibold))
        #expect(DS.Font.overlayBodyBold == .system(size: 12, weight: .bold))
        // size 13
        #expect(DS.Font.detailBodyRegular == .system(size: 13, weight: .regular))
        #expect(DS.Font.detailBody == .system(size: 13, weight: .medium))
        #expect(DS.Font.linkLabel == .system(size: 13, weight: .semibold))
        // size 14
        #expect(DS.Font.title == .system(size: 14, weight: .semibold))
        #expect(DS.Font.titleBold == .system(size: 14, weight: .bold))
        // size 16
        #expect(DS.Font.cta == .system(size: 16, weight: .medium))
    }

    // MARK: - Corner-radius single source of truth covers the real radii

    @Test func cornerRadiusCoversEveryRadiusTheAppUses() {
        #expect(DS.CornerRadius.small == 6)
        #expect(DS.CornerRadius.viewResultsPill == 7)
        #expect(DS.CornerRadius.medium == 8)
        #expect(DS.CornerRadius.composerField == 9)
        #expect(DS.CornerRadius.large == 10)
        #expect(DS.CornerRadius.resultsPill == 11)
        #expect(DS.CornerRadius.extraLarge == 12)
        #expect(DS.CornerRadius.clarificationCard == 14)
        #expect(DS.CornerRadius.detailPanel == 16)
        #expect(DS.CornerRadius.pill == .infinity)
    }

    // MARK: - Spacing scale covers the common padding values

    @Test func spacingScaleCoversCommonPaddingValues() {
        #expect(DS.Spacing.hairline == 2)
        #expect(DS.Spacing.xs == 4)
        #expect(DS.Spacing.compact == 5)
        #expect(DS.Spacing.snug == 6)
        #expect(DS.Spacing.sm == 8)
        #expect(DS.Spacing.control == 10)
        #expect(DS.Spacing.md == 12)
        #expect(DS.Spacing.comfortable == 14)
        #expect(DS.Spacing.lg == 16)
        #expect(DS.Spacing.xl == 20)
        #expect(DS.Spacing.xxl == 24)
        #expect(DS.Spacing.xxxl == 32)
    }
}
