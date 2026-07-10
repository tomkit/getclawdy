//
//  AccentContrastTests.swift
//  ClawdyTests
//
//  WCAG AA guard for the primary-button fill after the brand migration from Clawdy blue
//  to OpenClaw red. The brand accent (links, selection, icons, cursor) is now the OpenClaw
//  red (#E5342B). White-on-#E5342B is only ~4.32:1 (below the 4.5:1 AA minimum), so the
//  filled primary-button background routes through a slightly deeper `openClawRedButtonFill`
//  (#C42B22, ~5.65:1). These tests pin both: the fill clears AA on white, and the whole
//  accent family resolves to the single OpenClaw red source of truth.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct AccentContrastTests {

    /// sRGB components (0...1) of a SwiftUI Color, via its AppKit bridge.
    private func sRGBComponents(_ color: Color) -> (red: Double, green: Double, blue: Double) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(nsColor.redComponent), Double(nsColor.greenComponent), Double(nsColor.blueComponent))
    }

    /// WCAG 2.x relative luminance of an sRGB color.
    private func relativeLuminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.red) + 0.7152 * linearize(rgb.green) + 0.0722 * linearize(rgb.blue)
    }

    /// WCAG contrast ratio between two colors (order-independent).
    private func contrastRatio(_ first: Color, _ second: Color) -> Double {
        let luminanceFirst = relativeLuminance(sRGBComponents(first))
        let luminanceSecond = relativeLuminance(sRGBComponents(second))
        let lighter = max(luminanceFirst, luminanceSecond)
        let darker = min(luminanceFirst, luminanceSecond)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test func primaryButtonFillMeetsAAAgainstWhiteText() {
        // White label on the filled primary button must clear the 4.5:1 AA minimum.
        let ratio = contrastRatio(DS.Colors.accentButtonFill, DS.Colors.textOnAccent)
        #expect(DS.Colors.textOnAccent == Color.white)
        #expect(ratio >= 4.5)
    }

    @Test func openClawRedButtonFillIsTheIntendedAASafeCTAFill() {
        // The AA-safe CTA fill is `openClawRedButtonFill` (#C42B22), and `accentButtonFill`
        // routes through it so every filled CTA inherits the legible-on-white red.
        let rgb = sRGBComponents(DS.Colors.openClawRedButtonFill)
        #expect(Int((rgb.red * 255).rounded()) == 0xC4)
        #expect(Int((rgb.green * 255).rounded()) == 0x2B)
        #expect(Int((rgb.blue * 255).rounded()) == 0x22)
        // White text on the CTA fill clears AA.
        #expect(contrastRatio(DS.Colors.openClawRedButtonFill, Color.white) >= 4.5)
        // `accentButtonFill` is the SAME token, so CTAs inherit it.
        #expect(contrastRatio(DS.Colors.accentButtonFill, DS.Colors.openClawRedButtonFill) == 1.0)
    }

    @Test func brandAccentIsExactlyOpenClawRed() {
        // The brand accent is now the OpenClaw red (#E5342B) — the migration repointed the
        // accent family to the single `openClawRed` source of truth.
        let rgb = sRGBComponents(DS.Colors.openClawRed)
        #expect(Int((rgb.red * 255).rounded()) == 0xE5)
        #expect(Int((rgb.green * 255).rounded()) == 0x34)
        #expect(Int((rgb.blue * 255).rounded()) == 0x2B)
        #expect(contrastRatio(DS.Colors.accent, DS.Colors.openClawRed) == 1.0)
        #expect(contrastRatio(DS.Colors.accentText, DS.Colors.openClawRed) == 1.0)
    }

    @Test func brandRedIsTrulySingleSourced() {
        // The whole brand red flows from ONE hex string (`openClawRedHex`). Verify the
        // chain that lets the SwiftUI accent and the CoreGraphics annotation stroke share
        // it and never drift:
        //   1. `openClawRedHex` is the canonical #E5342B string.
        //   2. `openClawRedComponents` is that string parsed into sRGB components.
        //   3. `openClawRed` (the SwiftUI Color) is built from those same components.
        //   4. The annotation compositor consumes `openClawRedComponents` (proven by the
        //      byte-pinning composite test in AnnotationTests), so it can't diverge.
        #expect(DS.Colors.openClawRedHex == "E5342B")

        let componentsFromHex = Color.sRGBComponents(fromHex: DS.Colors.openClawRedHex)
        #expect(DS.Colors.openClawRedComponents.red == componentsFromHex.red)
        #expect(DS.Colors.openClawRedComponents.green == componentsFromHex.green)
        #expect(DS.Colors.openClawRedComponents.blue == componentsFromHex.blue)

        // The published `openClawRed` Color resolves to the SAME components the shared
        // tuple exposes (within rounding to 8-bit channels), so the accent surface and the
        // annotation stroke are guaranteed to be the identical red.
        let colorComponents = sRGBComponents(DS.Colors.openClawRed)
        #expect(Int((colorComponents.red * 255).rounded())
                == Int((DS.Colors.openClawRedComponents.red * 255).rounded()))
        #expect(Int((colorComponents.green * 255).rounded())
                == Int((DS.Colors.openClawRedComponents.green * 255).rounded()))
        #expect(Int((colorComponents.blue * 255).rounded())
                == Int((DS.Colors.openClawRedComponents.blue * 255).rounded()))

        // And those components are exactly #E5342B — the one brand red.
        #expect(Int((DS.Colors.openClawRedComponents.red * 255).rounded()) == 0xE5)
        #expect(Int((DS.Colors.openClawRedComponents.green * 255).rounded()) == 0x34)
        #expect(Int((DS.Colors.openClawRedComponents.blue * 255).rounded()) == 0x2B)
    }

    @Test func overlayCursorUsesTheAASafeDeeperRedForLegibleTextBubbles() {
        // The overlay cursor token is the FILL behind WHITE normal-weight text in several
        // OverlayWindow speech/response bubbles. White-on-#E5342B is only ~4.32:1 (below AA),
        // so the token must be the deeper `openClawRedButtonFill` (#C42B22, ~5.65:1), NOT the
        // lighter `openClawRed`. Locks the regression that white bubble text stays legible.
        #expect(contrastRatio(DS.Colors.overlayCursorBlue, DS.Colors.openClawRedButtonFill) == 1.0)
        #expect(contrastRatio(DS.Colors.overlayCursorBlue, Color.white) >= 4.5)
    }

    @Test func accentButtonFillIsDeeperThanBrandRedButStaysRedFamily() {
        // Sanity: the button fill is a DIFFERENT (deeper) shade than the brand red,
        // yet clearly red (red is the dominant channel).
        let fill = sRGBComponents(DS.Colors.accentButtonFill)
        let brand = sRGBComponents(DS.Colors.openClawRed)
        #expect(fill.red > fill.green && fill.red > fill.blue)    // still unmistakably red
        #expect(relativeLuminance(fill) < relativeLuminance(brand)) // deeper (darker) than brand
    }

    @Test func accentHoverFillMeetsAAAgainstWhiteText() {
        // The primary button's hover/pressed fill also carries white labels, so it too
        // must clear AA (it's derived to be a touch darker than the resting fill — never a
        // white wash, which would lighten it below AA).
        let ratio = contrastRatio(DS.Colors.accentHover, DS.Colors.textOnAccent)
        #expect(ratio >= 4.5)
    }

    @Test func nonButtonAccentTokensAllResolveToTheOneBrandRed() {
        // Every non-filled accent surface (accent, accentText, and the subtle/selected
        // tints, whose RGB is the brand red with only alpha changed) routes through the
        // single `openClawRed` source of truth — so the whole product reads as one system.
        #expect(contrastRatio(DS.Colors.accent, DS.Colors.openClawRed) == 1.0)
        #expect(contrastRatio(DS.Colors.accentText, DS.Colors.openClawRed) == 1.0)
        #expect(contrastRatio(DS.Colors.accentSubtle, DS.Colors.openClawRed) == 1.0)
        #expect(contrastRatio(DS.Colors.accentSelectedFill, DS.Colors.openClawRed) == 1.0)
    }

    @Test func appKitNSColorBridgesMatchTheirSwiftUITokens() {
        // The AppKit chrome (e.g. the results-window "Updated" pill + glow) must use the
        // SAME reds as the SwiftUI surfaces, so the bridges are pinned to their tokens.
        let fillBridge = Color(nsColor: DS.Colors.accentButtonFillNSColor)
        let redFillBridge = Color(nsColor: DS.Colors.openClawRedButtonFillNSColor)
        #expect(contrastRatio(fillBridge, DS.Colors.accentButtonFill) == 1.0)
        #expect(contrastRatio(redFillBridge, DS.Colors.openClawRedButtonFill) == 1.0)
    }

    @Test func updatedPillNSColorFillMeetsAAAgainstWhiteText() {
        // The results-window "Updated" pill draws WHITE text on the AppKit fill bridge,
        // so that fill must clear AA — this is why the pill uses accentButtonFill (the
        // deeper red), NOT the lighter brand red used for the non-text glow border.
        let pillFill = Color(nsColor: DS.Colors.accentButtonFillNSColor)
        let ratio = contrastRatio(pillFill, DS.Colors.textOnAccent)
        #expect(ratio >= 4.5)
    }
}
