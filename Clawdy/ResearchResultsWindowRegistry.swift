//
//  ResearchResultsWindowRegistry.swift
//  Clawdy
//
//  A tiny global registry that binds each on-screen research RESULTS window to the
//  research session that produced it, so a spoken follow-up can be routed to THAT
//  session's own claude thread purely from what the user is actually looking at —
//  the frontmost results window — rather than from the ephemeral click-focus state
//  (`ResearchSessionManager.focusedSessionID`).
//
//  Why this exists: a results window can be opened from a LIVE session pill OR from
//  the History window (a manifest-loaded page whose session isn't live anymore). The
//  History path never set focus, and even the live path's focus is cleared by
//  ordinary interactions (closing the detail panel, auto-hide). Keying the follow-up
//  on the frontmost results window's BOUND session id is robust to all of that: while
//  the user is viewing a page, that page's lineage is unambiguous no matter what took
//  transient key focus.
//
//  The binding is registered while a results window is visible and dropped when it
//  hides/closes. `frontmostSessionID()` returns the session id of the results window
//  the user is GENUINELY looking at — the KEY/MAIN, on-screen window while Clawdy is
//  the active app — not merely the first registered window in the app-local z-order.
//
//  Why the extra gating: `NSApp.orderedWindows` is an APP-LOCAL front-to-back order that
//  ignores whether Clawdy is even the active application and whether a given window is
//  key/main/visible. Keying purely on it could surface a BACKGROUND results window (the
//  wrong session), or a results window while the user is actually in another app. So a
//  spoken follow-up would land on a page the user isn't viewing — or fall through. The
//  routing must land on the page in front of the user, so `frontmostSessionID()` requires
//  Clawdy to be active AND the results window to be the key/main one, and resolves nil
//  cleanly otherwise (the caller then falls back).
//

import AppKit

@MainActor
final class ResearchResultsWindowRegistry {

    /// The single app-wide registry. Both `ResearchSession`'s own results window and
    /// the History window's separate results window register here, so a follow-up can
    /// resolve the frontmost page regardless of which path opened it.
    static let shared = ResearchResultsWindowRegistry()

    /// On-screen results windows: their AppKit window number → the research session id
    /// they render. Only populated while a window is visible.
    private var sessionIDByWindowNumber: [Int: ResearchSessionID] = [:]

    /// The source of the app's on-screen windows in front-to-back order, as window
    /// numbers. Production reads the real AppKit order; tests inject a fixed list so the
    /// frontmost-wins decision is exercised deterministically without real windows.
    var orderedWindowNumbersProvider: @MainActor () -> [Int] = { NSApp.orderedWindows.map(\.windowNumber) }

    /// Whether Clawdy is the FRONTMOST (active) application. Production reads
    /// `NSApp.isActive`; tests inject a fixed value so the app-active gate is exercised
    /// deterministically without a real activation. When Clawdy isn't active the user is
    /// looking at another app, so no results window is a follow-up target.
    var applicationIsActiveProvider: @MainActor () -> Bool = { NSApp.isActive }

    /// The window numbers of Clawdy's KEY and MAIN windows (the window the user is
    /// actually interacting with, plus its main-window fallback) — the genuinely-focused,
    /// on-screen windows. Production reads `NSApp.keyWindow`/`NSApp.mainWindow`; tests
    /// inject a fixed set. Only a results window that IS the key/main window resolves as a
    /// follow-up target, so a background results window can never be surfaced.
    var keyOrMainWindowNumbersProvider: @MainActor () -> Set<Int> = {
        var windowNumbers: Set<Int> = []
        if let keyWindowNumber = NSApp.keyWindow?.windowNumber { windowNumbers.insert(keyWindowNumber) }
        if let mainWindowNumber = NSApp.mainWindow?.windowNumber { windowNumbers.insert(mainWindowNumber) }
        return windowNumbers
    }

    /// Binds a now-on-screen results window (identified by its AppKit window number) to
    /// the research session that produced the page it shows. Ignored for an invalid
    /// (not-yet-on-screen) window number.
    func bind(windowNumber: Int, sessionID: ResearchSessionID) {
        guard windowNumber > 0 else { return }
        sessionIDByWindowNumber[windowNumber] = sessionID
    }

    /// Drops a results window's binding (it hid or closed) so a reused window number
    /// can't later resolve to a stale session.
    func unbind(windowNumber: Int) {
        guard windowNumber > 0 else { return }
        sessionIDByWindowNumber.removeValue(forKey: windowNumber)
    }

    /// The session id bound to the results window the user is GENUINELY looking at — the
    /// key/main, on-screen window while Clawdy is the active app — or nil when no such
    /// window is on screen. This is the ROBUST follow-up-routing signal: it never surfaces
    /// a background results window (wrong session) and never routes while the user is in
    /// another app, and it resolves nil cleanly so the caller can fall back.
    func frontmostSessionID() -> ResearchSessionID? {
        return Self.activeFrontmostSessionID(
            applicationIsActive: applicationIsActiveProvider(),
            inFrontToBackWindowNumbers: orderedWindowNumbersProvider(),
            keyOrMainWindowNumbers: keyOrMainWindowNumbersProvider(),
            bindings: sessionIDByWindowNumber
        )
    }

    /// Pure selection (no AppKit): given window numbers in front-to-back order and the
    /// current bindings, returns the session id of the frontmost window that is a
    /// registered results window. Extracted so the frontmost-wins rule is unit-testable
    /// without a live app. This is the raw z-order pick; `activeFrontmostSessionID`
    /// composes it with the key/main + app-active gating the router actually uses.
    static func frontmostSessionID(
        inFrontToBackWindowNumbers windowNumbers: [Int],
        bindings: [Int: ResearchSessionID]
    ) -> ResearchSessionID? {
        for windowNumber in windowNumbers {
            if let sessionID = bindings[windowNumber] {
                return sessionID
            }
        }
        return nil
    }

    /// Pure GATED selection (no AppKit): the session id of the results window the user is
    /// genuinely looking at. Returns nil unless Clawdy is the active app, then picks the
    /// FRONTMOST registered results window that is ALSO a key/main (genuinely-focused,
    /// on-screen) window — restricting the candidate windows to the key/main set before
    /// reusing the raw front-to-back pick. Extracted so the visibility/key gating is
    /// unit-testable without a live app; `frontmostSessionID()` wires the real AppKit state
    /// into it.
    static func activeFrontmostSessionID(
        applicationIsActive: Bool,
        inFrontToBackWindowNumbers windowNumbers: [Int],
        keyOrMainWindowNumbers: Set<Int>,
        bindings: [Int: ResearchSessionID]
    ) -> ResearchSessionID? {
        // The user is in another app → no results window is a follow-up target.
        guard applicationIsActive else { return nil }
        // Only the genuinely-focused (key/main) windows are candidates, preserving the
        // front-to-back order so the frontmost of them wins when more than one qualifies.
        let genuinelyFocusedWindowNumbers = windowNumbers.filter { keyOrMainWindowNumbers.contains($0) }
        return frontmostSessionID(
            inFrontToBackWindowNumbers: genuinelyFocusedWindowNumbers,
            bindings: bindings
        )
    }

    // MARK: - Test hooks

    var bindingsForTesting: [Int: ResearchSessionID] { sessionIDByWindowNumber }
    func resetForTesting() {
        sessionIDByWindowNumber.removeAll()
        orderedWindowNumbersProvider = { NSApp.orderedWindows.map(\.windowNumber) }
        applicationIsActiveProvider = { NSApp.isActive }
        keyOrMainWindowNumbersProvider = {
            var windowNumbers: Set<Int> = []
            if let keyWindowNumber = NSApp.keyWindow?.windowNumber { windowNumbers.insert(keyWindowNumber) }
            if let mainWindowNumber = NSApp.mainWindow?.windowNumber { windowNumbers.insert(mainWindowNumber) }
            return windowNumbers
        }
    }
}
