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
//  hides/closes. `frontmostSessionID()` walks the app's real front-to-back window
//  order (`NSApp.orderedWindows`, which lists only on-screen windows) and returns the
//  session id of the first window that is a registered results window — i.e. the
//  frontmost one the user is looking at.
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

    /// The session id bound to the FRONTMOST on-screen research results window, or nil
    /// when no results window is currently frontmost among the app's on-screen windows.
    /// Independent of key/click focus: it reads the real window stacking order.
    func frontmostSessionID() -> ResearchSessionID? {
        return Self.frontmostSessionID(
            inFrontToBackWindowNumbers: orderedWindowNumbersProvider(),
            bindings: sessionIDByWindowNumber
        )
    }

    /// Pure selection (no AppKit): given window numbers in front-to-back order and the
    /// current bindings, returns the session id of the frontmost window that is a
    /// registered results window. Extracted so the frontmost-wins rule is unit-testable
    /// without a live app.
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

    // MARK: - Test hooks

    var bindingsForTesting: [Int: ResearchSessionID] { sessionIDByWindowNumber }
    func resetForTesting() {
        sessionIDByWindowNumber.removeAll()
        orderedWindowNumbersProvider = { NSApp.orderedWindows.map(\.windowNumber) }
    }
}
