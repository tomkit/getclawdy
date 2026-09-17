//
//  FirstClassWindowPolicy.swift
//  Clawdy
//
//  Clawdy is a menu-bar (accessory, `LSUIElement`) app, and macOS never lists accessory
//  apps in Cmd-Tab or the Dock — so its document-style windows (a research results page,
//  the History window) were easy to lose behind other apps and impossible to Cmd-Tab
//  back to. This tracks those windows and, while at least one is on screen, promotes the
//  app to a REGULAR activation policy (Dock icon, Cmd-Tab entry, Window menu); when the
//  last one closes it drops back to accessory so the app disappears from the Dock again.
//
//  Pure counting on the main actor: windows register on show and unregister on hide/close.
//

import AppKit

@MainActor
enum FirstClassWindowPolicy {
    private static var openWindowNumbers: Set<Int> = []

    /// Call after a first-class window is ordered front.
    static func windowDidShow(_ window: NSWindow) {
        openWindowNumbers.insert(window.windowNumber)
        apply()
    }

    /// Call when a first-class window is hidden or closed.
    static func windowDidHide(_ window: NSWindow) {
        openWindowNumbers.remove(window.windowNumber)
        apply()
    }

    /// The policy the app should currently have. Pure, for tests.
    static func desiredPolicy(openFirstClassWindowCount: Int) -> NSApplication.ActivationPolicy {
        openFirstClassWindowCount > 0 ? .regular : .accessory
    }

    static var openWindowCountForTesting: Int { openWindowNumbers.count }

    private static func apply() {
        let desired = desiredPolicy(openFirstClassWindowCount: openWindowNumbers.count)
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            // Promoting while a window is up: make sure the app (and its window) actually
            // come forward, so the Dock icon and Cmd-Tab entry point at something visible.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
