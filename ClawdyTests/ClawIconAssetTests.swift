//
//  ClawIconAssetTests.swift
//  ClawdyTests
//
//  Guards the OpenClaw lobster-claw art that replaced the old triangle for BOTH the
//  menu bar status item and the floating "shadow cursor". These assert the two image
//  sets ship and load, that the menu-bar claw actually renders in brand RED (not a
//  monochrome/black template), and that the `openClawRed` token the cursor tint is
//  driven from is the provisional OpenClaw hex. Runtime visual correctness (does the
//  bar icon look right, does the cursor fly to targets) is verified separately by hand.
//

import Testing
import SwiftUI
import AppKit
@testable import Clawdy

@MainActor
struct ClawIconAssetTests {

    /// The app bundle that hosts the asset catalog. In a hosted unit test `Bundle.main`
    /// is the Clawdy app, but resolve through a Clawdy type as a robust fallback.
    private var appBundle: Bundle {
        Bundle(for: MenuBarPanelManager.self)
    }

    /// Loads a named image from the asset catalog, trying the module bundle first and
    /// falling back to the main bundle (both point at the app when tests are hosted).
    private func loadAssetImage(_ name: String) -> NSImage? {
        NSImage(named: name) ?? appBundle.image(forResource: name)
    }

    @Test func menuBarClawAssetLoadsWithPositiveSize() {
        let menuBarClaw = loadAssetImage("MenuBarClaw")
        #expect(menuBarClaw != nil, "MenuBarClaw image set must ship in the asset catalog")
        #expect((menuBarClaw?.size.width ?? 0) > 0)
        #expect((menuBarClaw?.size.height ?? 0) > 0)
    }

    @Test func cursorClawAssetLoadsWithPositiveSize() {
        let cursorClaw = loadAssetImage("CursorClaw")
        #expect(cursorClaw != nil, "CursorClaw image set must ship in the asset catalog")
        #expect((cursorClaw?.size.width ?? 0) > 0)
        #expect((cursorClaw?.size.height ?? 0) > 0)
    }

    /// The menu bar icon must show the brand RED — NOT a black monochrome template that
    /// macOS would recolor to the menu bar text colour. Rasterize the art and assert at
    /// least one opaque pixel is distinctly reddish (red channel well above green/blue).
    @Test func menuBarClawRendersInBrandRed() throws {
        let menuBarClaw = try #require(loadAssetImage("MenuBarClaw"))
        let tiffData = try #require(menuBarClaw.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))

        var foundDistinctlyRedPixel = false
        let pixelWidth = bitmap.pixelsWide
        let pixelHeight = bitmap.pixelsHigh
        for x in stride(from: 0, to: pixelWidth, by: 1) {
            for y in stride(from: 0, to: pixelHeight, by: 1) {
                guard let pixelColor = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Ignore transparent background pixels.
                guard pixelColor.alphaComponent > 0.5 else { continue }
                let red = pixelColor.redComponent
                let green = pixelColor.greenComponent
                let blue = pixelColor.blueComponent
                if red > 0.6 && red - green > 0.3 && red - blue > 0.3 {
                    foundDistinctlyRedPixel = true
                    break
                }
            }
            if foundDistinctlyRedPixel { break }
        }
        #expect(foundDistinctlyRedPixel, "Menu bar claw must render in OpenClaw red, not a black template")
    }

    /// The floating cursor is tinted from `DS.Colors.openClawRed`, so pin the provisional
    /// OpenClaw hex. A later brand-hex change is then a one-line token edit that retints
    /// the cursor automatically.
    @Test func openClawRedTokenIsProvisionalBrandHex() {
        let openClawRed = NSColor(DS.Colors.openClawRed).usingColorSpace(.sRGB)
        let expected = NSColor(Color(hex: "#E5342B")).usingColorSpace(.sRGB)
        #expect(openClawRed != nil)
        #expect(abs((openClawRed?.redComponent ?? 0) - (expected?.redComponent ?? 0)) < 0.001)
        #expect(abs((openClawRed?.greenComponent ?? 0) - (expected?.greenComponent ?? 0)) < 0.001)
        #expect(abs((openClawRed?.blueComponent ?? 0) - (expected?.blueComponent ?? 0)) < 0.001)
    }
}
