//
//  ResearchRecentsBadge.swift
//  Clawdy
//
//  The ALWAYS-PRESENT minimal "recents" presence — the idle-state Clawdy badge that
//  occupies the upper-left ONLY when NO research toast is active. Exactly one of
//  {recents badge | active toast stack} sits in the top-left at any moment:
//  `ResearchSessionManager.refreshOverlay()` shows the badge when there are zero
//  visible toasts and hides it the instant a run's toast takes over that spot.
//
//  The badge is its OWN independent, transparent `NSPanel` built the SAME way as a
//  per-toast window (`sharingType = .none`, `.statusBar` level, all-Spaces,
//  non-activating). It has TWO visual states, and — mirroring the reconciled per-toast
//  window fix (`ResearchToastPanel`) — the window frame, hover tracking region, and
//  Clawdy-cursor region are all sized to the CURRENT state, never to the largest
//  footprint at rest:
//
//   • RESTING: the window (and its hover hit region) is EXACTLY the badge's OWN small
//     SQUARE footprint (`ResearchRecentsLayout.restingWindowContentSize` / the square
//     pill rect). This is DISJOINT from the shared toast `restingPillSize` (168x36) on
//     purpose: the idle badge is a compact square, so reshaping it never resizes the
//     LIVE active toast stack, which keeps the shared elongated resting footprint. There
//     is NO phantom hit region over the empty space the expansion would grow into —
//     hovering that empty space does nothing (the item-2 resting-hitbox fix, applied to
//     the idle badge too, not just the active toasts).
//   • LIST-OPEN: because the badge only ever appears when there are ZERO active toasts,
//     interacting with the resting square opens the recents list DIRECTLY — it never
//     first morphs into an intermediate elongated horizontal "View recent runs ›" pill.
//     Hovering the square (or tapping it) grows the window VERTICALLY (anchored top-left,
//     so it extends DOWN) into the SAME surface, rendering the top-N recents list INLINE
//     — no separate list window. Tapping again (or moving away) collapses it back.
//
//  The square→list growth (and the reverse collapse) ANIMATES open — the window frame and
//  the SwiftUI content morph are INTERPOLATED (respecting Reduce Motion, which falls back
//  to the synchronous jump). CRITICAL no-dead-zone invariant: the hover + Clawdy-cursor
//  `NSTrackingArea` regions are set to the FINAL (grown) rect IMMEDIATELY when the open
//  begins — never animated — so the grown hit region is live from the first instant even
//  while the window frame is still animating to full size.
//
//  CLAWDY CURSOR: hovering the mini badge shows the app's blue Clawdy "shadow cursor"
//  (`ResearchToastCursor.clawdy`) instead of the system arrow. This is installed via a
//  `.cursorUpdate` `NSTrackingArea` (with `cursorUpdate(with:)` calling `cursor.set()`),
//  NOT the old `addCursorRect`/`resetCursorRects` path: AppKit only manages cursor RECTS
//  for the KEY window, and these overlay panels are `nonactivatingPanel`s that never
//  become key, so the rasterized cursor rect never took effect on-device. An
//  `.activeAlways` `.cursorUpdate` tracking area is delivered regardless of key status —
//  the item-4 fix.
//
//  The list MIRRORS the History window: it is built from the SAME source of truth
//  (`HistoryRowBuilder` over the manifest) so it is reverse-chronological by last
//  activity with every quick-answer turn grouped into the single "Quick answers" row.
//  Each row's default (whole-row) click opens its conversation transcript in History; a
//  results-page action (a compact, icon-less "Results" label on hover for mouse, a named
//  accessibility action otherwise) is
//  additionally offered when a fenced, on-disk deliverable exists. A "Show all history"
//  affordance opens the full History window for the rest.
//
//  Everything visible here (`isDismissed`) is DISPLAY-only: a dismissed session is
//  dimmed and tagged, but dismiss never stopped its run. The pure builders / mappers
//  at the top are AppKit-free so the content/order, visibility rule, row-action
//  mapping, and dismissed-affordance selection are all unit-testable with no windows.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Overlay hitbox / cursor runtime instrumentation

/// Opt-in runtime logging for the overlay hover-hitbox + cursor diagnosis (items 2 & 4).
/// Enabled only when the app is launched with `CLAWDY_OVERLAY_DEBUG=1`, so it is inert in
/// normal runs and tests. Used to prove, against the RUNNING app, that the resting hover
/// region equals the mini badge rect and that the Clawdy cursor is actually applied.
enum OverlayHitboxDebug {
    static let isEnabled = ProcessInfo.processInfo.environment["CLAWDY_OVERLAY_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("🐾[overlay] %@", message())
    }
}

// MARK: - Pure layout / policy

/// Pure layout + policy constants for the recents badge and its inline list. AppKit-free.
enum ResearchRecentsLayout {
    /// N — how many most-recent sessions the badge's list shows. Single tunable knob;
    /// the rest (order, grouping) is inherited from the History source of truth.
    static let topRecentsCount = 5

    /// The recents badge's OWN small SQUARE resting footprint. Defined LOCALLY here and
    /// kept DISJOINT from the shared toast `ResearchStackFrameLayout.restingPillSize`
    /// (168x36) — that shared elongated footprint is still worn by the LIVE active toast
    /// stack, so it must NOT be reshaped. 44pt comfortably fits the cursor glyph and reads
    /// as a compact idle presence. The badge's resting window size, hover hit region, and
    /// Clawdy-cursor region all derive from THIS square.
    static let restingBadgeSize = CGSize(width: 44, height: 44)

    /// The RESTING badge window's content size — the square plus the shared shadow margin
    /// (so the pill's top-left inset matches the list surface and the badge doesn't jump as
    /// the window grows). Non-zero by construction. Derived from the LOCAL square, never
    /// from the shared `ResearchToastLayout.miniWindowContentSize`.
    static var restingWindowContentSize: CGSize {
        CGSize(
            width: restingBadgeSize.width + ResearchToastLayout.shadowMargin * 2,
            height: restingBadgeSize.height + ResearchToastLayout.shadowMargin * 2
        )
    }

    /// Duration of the resting-square ⇄ recents-window grow / collapse animation (the
    /// window frame interpolation; the SwiftUI content morph runs alongside it). Skipped
    /// entirely under Reduce Motion, which restores the synchronous jump.
    static let growthAnimationDuration: TimeInterval = 0.28

    /// The INLINE recents list's content size (the pill-width column, matching the
    /// expanded pill so it lines up, with a fixed height for the header + rows + footer).
    /// Non-zero by construction.
    static let inlineListSize = CGSize(
        width: ResearchStackFrameLayout.expandedPillSize.width,
        height: 300
    )

    /// Inset from the anchor screen corner's visible frame (matches the toast column).
    static let screenEdgeInset: CGFloat = 16
}

/// Pure builder for the recents list — the SAME source of truth as the History
/// window, sliced to the top-N. Reusing `HistoryRowBuilder` guarantees the recents
/// list can never drift from History's content or order.
enum ResearchRecentsListBuilder {
    /// The top-N most-recent History rows: `HistoryRowBuilder.makeRows` (reverse-chron
    /// by last activity, quick-answers grouped into one row) sliced to `limit`.
    static func recentRows(
        from entries: [ResearchManifestEntry],
        now: Date,
        limit: Int = ResearchRecentsLayout.topRecentsCount
    ) -> [HistoryRow] {
        let allRows = HistoryRowBuilder.makeRows(from: entries, now: now)
        return Array(allRows.prefix(max(0, limit)))
    }
}

/// Pure visibility rule for the always-present recents badge: it is shown IFF there
/// are ZERO active research toasts (so the badge and the live toast stack never both
/// occupy the top-left). Factored out so the swap is unit-testable with no windows.
enum ResearchRecentsBadgeVisibility {
    static func shouldShowBadge(activeToastCount: Int) -> Bool {
        activeToastCount == 0
    }
}

/// One destination a recents row can open — the SAME two destinations a History-window
/// row can reach. Decided purely so the fence + mapping are unit-testable.
enum ResearchRecentsRowAction: Equatable {
    /// Open the finished deliverable page (bound to `sessionID` for follow-up lineage).
    case openResults(sessionID: String, deliverablePath: String, title: String)
    /// Open this session's transcript in the History window.
    case openHistory(sessionID: String)
}

/// The BOTH-outputs mapping for one recents row (item 3): each row offers a "View page"
/// action WHEN a fenced, on-disk deliverable exists, AND always a "View conversation"
/// action for its transcript. The page fence is the SAME read-side fence History uses
/// (`isPathWithinAllowedRoots` over `historyDeliverableAllowedRoots`), so a tampered
/// manifest path can never be opened as a page. Existence is checked via the injected
/// `deliverableExists` closure (real `FileManager` in production; a stub in tests) so
/// this stays pure and headlessly testable.
struct ResearchRecentsRowActions: Equatable {
    /// The "View page" destination — present ONLY when the row has a fenced, on-disk
    /// deliverable. Always an `.openResults` when non-nil.
    let page: ResearchRecentsRowAction?
    /// The "View conversation" destination — ALWAYS available (every row has a
    /// transcript in History). Always an `.openHistory`.
    let conversation: ResearchRecentsRowAction

    static func resolve(
        for row: HistoryRow,
        deliverableExists: (String) -> Bool
    ) -> ResearchRecentsRowActions {
        let conversation = ResearchRecentsRowAction.openHistory(sessionID: row.sessionId)
        if let deliverablePath = row.deliverablePath,
           TranscriptParser.isPathWithinAllowedRoots(
               deliverablePath,
               roots: TranscriptParser.historyDeliverableAllowedRoots()
           ),
           deliverableExists(deliverablePath) {
            return ResearchRecentsRowActions(
                page: .openResults(
                    sessionID: row.sessionId,
                    deliverablePath: deliverablePath,
                    title: row.displayTitle
                ),
                conversation: conversation
            )
        }
        return ResearchRecentsRowActions(page: nil, conversation: conversation)
    }
}

/// Pure selection of the dismissed-vs-not affordance for a recents/History row. A row
/// is treated as DISMISSED (dimmed + "dismissed" tag) when EITHER the durable manifest
/// flag says so (`row.isDismissed`, survives relaunch) OR it is in the live in-memory
/// dismissed set (a session dismissed this run, before the manifest is re-read). The
/// union keeps the display correct both for a just-dismissed live session and for a
/// dismissed session seen after a relaunch.
enum ResearchRecentsDismissedDisplay {
    static func isDismissed(
        row: HistoryRow,
        liveDismissedSessionIDs: Set<String>
    ) -> Bool {
        row.isDismissed || liveDismissedSessionIDs.contains(row.sessionId)
    }
}

/// The SINGLE quiet trailing signal a trimmed recents row carries — the whole IA of the
/// old three-part metadata row (kind pill + status dot + status word + relative time)
/// collapsed to ONE token. Sparse by construction: a row shows the run's title plus this
/// one signal, never a stack of descriptors. Pure so the mapping is unit-tested with no UI.
struct ResearchRecentsRowSecondarySignal: Equatable {
    /// The colour role for the token, mapped to a DS colour by the view (kept AppKit-free
    /// here). `neutral` is the quiet tertiary text used for timestamps and ended runs;
    /// `active` is the quiet accent for a live run; `failure` flags a failed run in RED
    /// (matching the live progress overlay's error color) rather than the amber `warning`.
    enum Tone: Equatable {
        case neutral
        case active
        case failure
        case warning
    }

    let text: String
    let tone: Tone

    /// Resolves the one signal for a row. A DISMISSED row collapses to a quiet "dismissed"
    /// tag (the row is ALSO dimmed by the view, so the two together are the preserved
    /// dismissed affordance). Otherwise the signal is the STATUS when the run is live or
    /// ended abnormally (running / failed / stopped) and the relative TIME when it simply
    /// completed or is the always-on grouped quick-answers row — never both, never stacked.
    static func forRow(_ row: HistoryRow, isDismissed: Bool) -> ResearchRecentsRowSecondarySignal {
        if isDismissed {
            return ResearchRecentsRowSecondarySignal(text: "dismissed", tone: .neutral)
        }
        switch row.status {
        case .running:
            return ResearchRecentsRowSecondarySignal(text: "running", tone: .active)
        case .failed:
            return ResearchRecentsRowSecondarySignal(text: "failed", tone: .failure)
        case .stopped:
            return ResearchRecentsRowSecondarySignal(text: "stopped", tone: .neutral)
        case .completed, .active:
            return ResearchRecentsRowSecondarySignal(text: row.relativeTimestamp, tone: .neutral)
        }
    }
}

// MARK: - Badge visual state

/// The badge window's two visual states. Drives BOTH the window/tracking/cursor sizing
/// (in the controller) and the SwiftUI content morph, so they can never disagree. The
/// intermediate elongated "View recent runs ›" pill is intentionally GONE — because the
/// badge only ever shows when there are zero active toasts, opening goes straight from the
/// resting square to the inline list.
enum ResearchRecentsBadgeVisualState: Equatable {
    /// The small resting SQUARE badge (tight window + hit region — no phantom hitbox).
    case resting
    /// The inline recents list, the window grown vertically into the same surface.
    case listOpen
}

// MARK: - Surface morph geometry (pure)

/// Pure, AppKit-free geometry for the ONE persistent recents surface as it morphs between
/// the resting square and the open inline list. The idle badge's visible surface is a
/// SINGLE layer — one dark rounded-rect fill + one Clawdy red-aura glow — whose width,
/// height AND corner radius are driven from `model.state` so SwiftUI INTERPOLATES them (the
/// surface GROWS from the square's footprint to the full list footprint, and shrinks back —
/// it never cross-fades two separate shapes that each pop in at final size). These endpoints
/// plus the lerp make that interpolation testable with no window: a mid-progress size/radius
/// is strictly between the two endpoints, which the old cross-fade could never produce.
enum ResearchRecentsSurfaceMorph {
    /// RESTING endpoint: the badge's own 44×44 square at a snug corner radius (r=12 read
    /// right on the small square; the elongated pill's tighter radius looked pinched).
    static let restingSize = ResearchRecentsLayout.restingBadgeSize
    static let restingCornerRadius: CGFloat = DS.CornerRadius.extraLarge

    /// LIST-OPEN endpoint: the full inline-list footprint at the softer list corner radius.
    static let listOpenSize = ResearchRecentsLayout.inlineListSize
    static let listOpenCornerRadius: CGFloat = DS.CornerRadius.detailPanel

    /// The (size, cornerRadius) the single surface holds at each discrete state — the two
    /// endpoints SwiftUI's animation interpolates BETWEEN. The controller's window frame
    /// animates to the matching window size in lockstep (`ResearchRecentsLayout` +
    /// `growthAnimationDuration`), so surface and window grow together.
    static func metrics(for state: ResearchRecentsBadgeVisualState) -> (size: CGSize, cornerRadius: CGFloat) {
        switch state {
        case .resting: return (restingSize, restingCornerRadius)
        case .listOpen: return (listOpenSize, listOpenCornerRadius)
        }
    }

    /// The interpolated surface SIZE at `progress` (0 = resting square, 1 = open list) — the
    /// linear path SwiftUI's frame animation traverses as the surface grows. Clamped to [0,1].
    static func size(atListOpenProgress progress: CGFloat) -> CGSize {
        let clampedProgress = min(max(progress, 0), 1)
        return CGSize(
            width: restingSize.width + (listOpenSize.width - restingSize.width) * clampedProgress,
            height: restingSize.height + (listOpenSize.height - restingSize.height) * clampedProgress
        )
    }

    /// The interpolated surface CORNER RADIUS at `progress` (0 = r=12 square, 1 = r=16 list) —
    /// the path the rounded silhouette (background rect, clip, and glow) traverses together.
    static func cornerRadius(atListOpenProgress progress: CGFloat) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        return restingCornerRadius + (listOpenCornerRadius - restingCornerRadius) * clampedProgress
    }

    /// The INVERSE of `size(atListOpenProgress:)`: how far a LIVE surface size sits between the
    /// resting square (0) and the open list (1). This is what lets the ONE window-frame
    /// animation be the single source of truth — the SwiftUI surface reads the window's CURRENT
    /// animated content size (via a `GeometryReader`), maps it back to a progress with this, and
    /// drives its corner radius from it, so fill + aura track the window in lockstep with nothing
    /// to desync (the root cause of the old hover jitter was a SECOND, independently-clocked
    /// SwiftUI size animation on `model.state`). Uses the HEIGHT axis (its travel is the largest,
    /// so it is the least numerically fragile); clamped to [0, 1].
    static func listOpenProgress(forCurrentSize currentSize: CGSize) -> CGFloat {
        let heightTravel = listOpenSize.height - restingSize.height
        guard heightTravel != 0 else { return 0 }
        let rawProgress = (currentSize.height - restingSize.height) / heightTravel
        return min(max(rawProgress, 0), 1)
    }
}

// MARK: - Observable bridges (SwiftUI)

/// One recents-list row, resolved with its dismissed treatment and its BOTH-outputs
/// actions (page when available + conversation always).
struct ResearchRecentsRowModel: Identifiable, Equatable {
    var id: String { row.sessionId }
    let row: HistoryRow
    let isDismissed: Bool
    let actions: ResearchRecentsRowActions
}

/// The badge window's observable state. `state` is flipped by the window's AppKit hover
/// tracking and by taps (resting ⇄ listOpen, opening straight into the list); the content
/// morphs in response while the controller resizes the window around it.
@MainActor
final class ResearchRecentsBadgeModel: ObservableObject {
    @Published var state: ResearchRecentsBadgeVisualState = .resting
    @Published var reduceMotionEnabled: Bool = false
    @Published var rows: [ResearchRecentsRowModel] = []

    /// Tapping the resting/hover badge — wired to open the inline list.
    var onTapBadge: (() -> Void)?
    /// A row's "View page" / "View conversation" affordance — wired to perform the action.
    var onPerformRowAction: ((ResearchRecentsRowAction) -> Void)?
    /// "Show all history" — opens the full History window.
    var onShowAllHistory: (() -> Void)?
    /// The inline list's close (×) affordance — collapses back to the resting badge.
    var onCloseList: (() -> Void)?
}

// MARK: - AppKit hover + cursor tracking (shared reconciled approach)

/// The `NSView` that hosts the badge's SwiftUI content and owns the badge window's hover
/// + Clawdy-cursor regions. It carries TWO `NSTrackingArea`s, both rebuilt whenever the
/// state changes:
///   • a `.mouseEnteredAndExited` area over the HOVER rect (the current pill/list rect),
///     so hover is detected over exactly the visible surface — no phantom hitbox at rest;
///   • a `.cursorUpdate` area over the CURSOR rect (the whole visible surface — resting
///     badge, expanded pill, or open inline list), whose
///     `cursorUpdate(with:)` sets the Clawdy cursor. `.cursorUpdate` (with `.activeAlways`)
///     is delivered even though this non-activating panel is never key — the reason the
///     old `addCursorRect` cursor rect never applied on-device.
private final class ResearchRecentsBadgeTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    /// The current hover region (the whole visible surface for the state).
    private var hoverRect: CGRect = .zero
    /// The current Clawdy-cursor region — the whole visible surface for the state (resting
    /// badge, expanded pill, or open inline list), so the entire recents surface reads as
    /// Clawdy's own cursor.
    private var cursorRect: CGRect = .zero

    /// The ACTUALLY-installed hover `NSTrackingArea` rect (what the OS hit-tests hover
    /// against), so a test proves the real resting hit region is the mini pill — not just
    /// the value we intended to store.
    var installedHoverTrackingRectForTesting: CGRect {
        trackingAreas.first { ($0.userInfo?["kind"] as? String) == "hover" }?.rect ?? .zero
    }
    /// The ACTUALLY-installed Clawdy-cursor `NSTrackingArea` (present in every visible
    /// state, including the open list), so a test proves it really carries `[.cursorUpdate,
    /// .activeAlways]` — the mechanism that works on a non-key panel — not just that a rect
    /// was stored.
    var installedCursorTrackingAreaForTesting: NSTrackingArea? {
        trackingAreas.first { ($0.userInfo?["kind"] as? String) == "cursor" }
    }
    var hoverRectForTesting: CGRect { hoverRect }
    var cursorRectForTesting: CGRect { cursorRect }
    /// Runs the REAL cursor-application path (the body of `cursorUpdate(with:)`), so a test
    /// can prove it makes the Clawdy cursor the current cursor.
    func applyClawdyCursorForTesting() { applyClawdyCursor() }

    /// Sets the tight hover + cursor regions and rebuilds the tracking areas.
    func setRegions(hoverRect: CGRect, cursorRect: CGRect) {
        self.hoverRect = hoverRect
        self.cursorRect = cursorRect
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        if hoverRect.width > 0, hoverRect.height > 0 {
            addTrackingArea(NSTrackingArea(
                rect: hoverRect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: ["kind": "hover"]
            ))
        }
        if cursorRect.width > 0, cursorRect.height > 0 {
            addTrackingArea(NSTrackingArea(
                rect: cursorRect,
                options: [.cursorUpdate, .activeAlways],
                owner: self,
                userInfo: ["kind": "cursor"]
            ))
        }
        OverlayHitboxDebug.log(
            "badge updateTrackingAreas hover=\(NSStringFromRect(hoverRect)) "
            + "cursor=\(NSStringFromRect(cursorRect)) "
            + "windowFrame=\(window.map { NSStringFromRect($0.frame) } ?? "nil")"
        )
    }

    override func mouseEntered(with event: NSEvent) {
        OverlayHitboxDebug.log("badge mouseEntered locInWindow=\(NSStringFromPoint(event.locationInWindow))")
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        OverlayHitboxDebug.log("badge mouseExited locInWindow=\(NSStringFromPoint(event.locationInWindow))")
        onHoverChanged?(false)
    }

    /// The item-4 cursor fix: called for the `.cursorUpdate` tracking area even on this
    /// never-key overlay panel, this explicitly sets the Clawdy cursor (a raster cursor
    /// rect via `addCursorRect` would only apply for the key window and so never fired).
    override func cursorUpdate(with event: NSEvent) {
        OverlayHitboxDebug.log("badge cursorUpdate → Clawdy cursor.set()")
        applyClawdyCursor()
    }

    /// The single cursor-application step shared by `cursorUpdate(with:)` and the test hook,
    /// so the test exercises exactly the code the live `.cursorUpdate` event runs.
    private func applyClawdyCursor() {
        ResearchToastCursor.clawdy.set()
    }

    /// Makes the transparent aura/shadow margin around the badge CLICK-THROUGH: a mouse-down in
    /// the halo returns `nil` so it falls to whatever window sits behind the overlay, while a
    /// mouse-down on the VISIBLE surface (resting badge tap, list-row click, "Show all history"
    /// link) still resolves to the real SwiftUI content. Because this view is the panel's
    /// `contentView`, `point` arrives in window-content coordinates — the SAME space `cursorRect`
    /// (the full visible surface set by `setRegions`) lives in, so no conversion is needed.
    /// Hover-to-expand and the Clawdy cursor are unaffected: `NSTrackingArea` enter/exit and
    /// `.cursorUpdate` are geometry-based and never route through `hitTest`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard cursorRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    /// Instrumentation only: proves the LEGACY cursor-rect path does NOT fire for this
    /// non-key panel (it stays silent on-device), which is why the prior overlay fix
    /// showed the system arrow. No cursor rect is added here — the `.cursorUpdate` area is
    /// the working mechanism.
    override func resetCursorRects() {
        super.resetCursorRects()
        OverlayHitboxDebug.log("badge resetCursorRects fired (legacy cursor-rect path)")
    }
}

// MARK: - Controller

/// Owns the always-present recents badge window and its inline recents list (same
/// window, grown vertically — NOT a separate panel). The `ResearchSessionManager` drives
/// visibility (`show()`/`hide()`) from its overlay refresh, and supplies the fresh rows +
/// row-action / show-all callbacks via the injectable closures below.
@MainActor
final class ResearchRecentsBadgeController {
    /// Supplies the fresh top-N recents rows when the list opens (pulled per open so it
    /// always reflects the latest manifest — the same source History reads).
    var recentRowsProvider: (() -> [HistoryRow])?
    /// The live in-memory dismissed set, unioned with the durable manifest flag so a
    /// just-dismissed live session is dimmed immediately.
    var liveDismissedSessionIDsProvider: (() -> Set<ResearchSessionID>)?
    /// Performs a recents row's chosen action (open results page or open its transcript).
    var onPerformRowAction: ((ResearchRecentsRowAction) -> Void)?
    /// Opens the full History window ("Show all history").
    var onShowAllHistory: (() -> Void)?

    private var badgePanel: NSPanel?
    private let badgeModel = ResearchRecentsBadgeModel()
    private var trackingView: ResearchRecentsBadgeTrackingView?

    /// The badge's current visual state — the single source of truth for the window frame,
    /// tracking/cursor regions, and the content morph.
    private var visualState: ResearchRecentsBadgeVisualState = .resting
    /// The badge's slot top-left (screen coords). The window hangs DOWN from it; growing
    /// on hover / list-open keeps this anchor fixed so the badge doesn't move.
    private var currentSlotTopLeft: CGPoint = .zero

    /// Auto-hide bookkeeping so an OPEN inline list collapses menu-style once the pointer
    /// leaves it (with a short grace so a small gap doesn't slam it shut).
    private var listAutoHideWorkItem: DispatchWorkItem?
    private let listAutoHideGraceSeconds: TimeInterval = 0.35

    /// Test seam. An additive offset applied to the anchor screen's visible frame when the
    /// badge computes its slot, so a test can anchor the REAL badge window far off-screen —
    /// it never flashes in the top-left during `xcodebuild test` — while the window size, the
    /// resting⇄list morph, the hover/cursor tracking regions, and the list rows stay
    /// byte-for-byte identical (only the shared slot origin shifts). Production default is
    /// `.zero`, so on-screen positioning is completely unchanged.
    var testAnchorOriginOffset: CGVector = .zero

    /// The SINGLE shared user drag offset (the SAME value the toast stack uses) applied to
    /// the badge's slot so dragging the badge moves the whole cluster and it survives every
    /// re-show. The manager owns the canonical value and pushes it here; a live drag reports
    /// a new value back via `onUserColumnDragged`.
    private(set) var userColumnDragOffset: CGVector = .zero

    /// Reports a NEW clamped drag offset (after the user dragged the badge window) up to the
    /// manager, which persists it and syncs it back to both the badge and the toast stack.
    var onUserColumnDragged: ((CGVector) -> Void)?

    /// Non-zero while WE move the badge window programmatically (show / grow-open / applying
    /// a synced offset). The `didMoveNotification` handler ignores moves while this is > 0 so
    /// our own `setFrame`s — including an animated grow's intermediate frames — are never
    /// read back as a user drag.
    private var programmaticFrameChangeDepth = 0

    /// A move smaller than this (points) is treated as noise / a settle, not a real drag.
    private let dragMovementEpsilon: CGFloat = 0.5

    init() {
        // Capture a user drag of the badge window (via `isMovableByWindowBackground`) into
        // the shared column offset. `object: nil` catches every window; the handler filters
        // to just this badge's window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBadgeWindowMoved(_:)),
            name: NSWindow.didMoveNotification,
            object: nil
        )
        badgeModel.onTapBadge = { [weak self] in self?.openList() }
        badgeModel.onCloseList = { [weak self] in self?.collapseToResting() }
        badgeModel.onShowAllHistory = { [weak self] in
            self?.collapseToResting()
            self?.onShowAllHistory?()
        }
        badgeModel.onPerformRowAction = { [weak self] action in
            // A row action opens its window; collapse the inline list behind it.
            self?.collapseToResting()
            self?.onPerformRowAction?(action)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Show / hide

    /// Shows the resting badge (creating its window once) in the upper-left slot.
    /// Idempotent: re-showing while already visible only refreshes placement/motion and
    /// never disturbs an open list.
    func show() {
        badgeModel.reduceMotionEnabled = reduceMotionEnabled
        let panel = badgePanel ?? makeBadgePanel()
        badgePanel = panel
        updateSlotTopLeft()
        applyFrame(animated: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Hides and tears down the badge window (and any open list) so nothing leaks (the
    /// toast stack is taking over the top-left, or the whole subsystem is being disposed).
    func hide() {
        listAutoHideWorkItem?.cancel()
        listAutoHideWorkItem = nil
        badgePanel?.orderOut(nil)
        badgePanel?.contentView = nil
        badgePanel = nil
        trackingView = nil
        visualState = .resting
        badgeModel.state = .resting
    }

    // MARK: - Badge window

    private func makeBadgePanel() -> NSPanel {
        // Created at the tight resting SQUARE footprint (the resting hit region — no
        // phantom hitbox); it grows into the inline list on hover / tap. This is the
        // badge's OWN square window size, DISJOINT from the shared toast mini footprint.
        let size = ResearchRecentsLayout.restingWindowContentSize
        // Draggable by its background so the user can move the idle cluster out of the way.
        let panel = ResearchToastPanel.makeOverlayPanel(size: size, isMovableByWindowBackground: true)

        let trackingView = ResearchRecentsBadgeTrackingView(frame: CGRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: ResearchRecentsBadgeRootView(model: badgeModel))
        hostingView.frame = trackingView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        trackingView.addSubview(hostingView)
        panel.contentView = trackingView

        trackingView.onHoverChanged = { [weak self] hovering in
            self?.handleBadgeHover(hovering)
        }
        self.trackingView = trackingView
        return panel
    }

    private func updateSlotTopLeft() {
        guard let rawVisibleFrame = NSScreen.main?.visibleFrame else { return }
        // Shift the anchor by the test-only offset (production default `.zero`) AND the
        // user's shared drag offset, so the badge (and its inline list, which hangs off the
        // same slot) honors a drag and positions off-screen under tests.
        let visibleFrame = rawVisibleFrame.offsetBy(
            dx: testAnchorOriginOffset.dx + userColumnDragOffset.dx,
            dy: testAnchorOriginOffset.dy + userColumnDragOffset.dy
        )
        currentSlotTopLeft = ResearchToastLayout.slotTopLeftOrigin(
            index: 0,
            corner: .topLeft,
            visibleFrame: visibleFrame,
            edgeInset: ResearchRecentsLayout.screenEdgeInset
        )
    }

    /// The window content size + the pill/list rect within it for the current state. The
    /// resting size is the badge's OWN square footprint (DISJOINT from the shared toast
    /// windows); list-open is the vertical inline-list footprint.
    private func windowContentSize(for state: ResearchRecentsBadgeVisualState) -> CGSize {
        switch state {
        case .resting:
            return ResearchRecentsLayout.restingWindowContentSize
        case .listOpen:
            return CGSize(
                width: ResearchRecentsLayout.inlineListSize.width + ResearchToastLayout.shadowMargin * 2,
                height: ResearchRecentsLayout.inlineListSize.height + ResearchToastLayout.shadowMargin * 2
            )
        }
    }

    /// The visible content's rect inside the window (top-leading, inset by the shadow
    /// margin) — the resting square badge or the inline list.
    private func contentPillSize(for state: ResearchRecentsBadgeVisualState) -> CGSize {
        switch state {
        case .resting: return ResearchRecentsLayout.restingBadgeSize
        case .listOpen: return ResearchRecentsLayout.inlineListSize
        }
    }

    /// Applies the window frame + tight hover/cursor regions for the CURRENT visual state
    /// at the current slot. On list-open the window grows (anchored top-left) so the badge
    /// stays put; the hover region hugs the whole visible surface, and the Clawdy cursor
    /// region covers the whole visible surface in every state (including the list).
    ///
    /// When `animated`, the window FRAME interpolates to its new size, but the hover +
    /// cursor tracking regions are set to the FINAL (grown) rect IMMEDIATELY — never
    /// animated — so the grown hit region is live the instant the open begins, even while
    /// the frame is still animating (the no-dead-zone invariant).
    private func applyFrame(animated: Bool) {
        guard let panel = badgePanel else { return }
        let size = windowContentSize(for: visualState)
        let pillSize = contentPillSize(for: visualState)
        let origin = ResearchToastLayout.windowOrigin(slotTopLeft: currentSlotTopLeft, contentSize: size)
        let frame = CGRect(origin: origin, size: size)

        let pillRect = ResearchToastLayout.pillRect(inWindowOfSize: size, pillSize: pillSize)
        // Set the tracking regions to the FINAL rect BEFORE (and independent of) the frame
        // animation, so the grown hit region is live immediately — never lagging behind the
        // animated window. Hover region = the whole visible surface (so list-open hover-out
        // is detected). Cursor region = the SAME whole visible surface in EVERY state
        // (resting square badge AND the open inline list), so the entire recents surface
        // reads as Clawdy's own cursor. With `.pointerCursor()` removed from every control
        // here, the list rows have no cursor of their own — this `.cursorUpdate` region is
        // what keeps the Clawdy cursor showing while hovering the open list.
        trackingView?.setRegions(hoverRect: pillRect, cursorRect: pillRect)

        // Raise the programmatic-move guard so the `didMoveNotification` handler ignores every
        // frame WE set here (including an animated grow's intermediate frames) — only a real
        // user drag should feed the shared column offset.
        programmaticFrameChangeDepth += 1
        if animated {
            // Interpolate the window frame growth/collapse so it reads as growing open.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = ResearchRecentsLayout.growthAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.programmaticFrameChangeDepth = max(0, self.programmaticFrameChangeDepth - 1)
            })
        } else {
            panel.setFrame(frame, display: true)
            programmaticFrameChangeDepth = max(0, programmaticFrameChangeDepth - 1)
        }
        // Instrumentation (opt-in, item 2/4 runtime diagnosis): the resting state's window
        // size + pill rect + the on-screen pill rect are the authoritative determinants of
        // the OS hover hitbox and cursor region — logged so the resting hitbox == mini pill
        // invariant can be verified against the RUNNING app, not just a unit test.
        if OverlayHitboxDebug.isEnabled {
            OverlayHitboxDebug.log(
                "badge applyFrame state=\(visualState) windowSize=\(NSStringFromSize(size)) "
                + "pillRect=\(NSStringFromRect(pillRect)) "
                + "pillScreenRect=\(NSStringFromRect(panel.convertToScreen(pillRect)))"
            )
        }
    }

    // MARK: - User drag capture

    /// The badge window moved. When it's OUR window and the move wasn't ours
    /// (`programmaticFrameChangeDepth == 0`), measure how far the user dragged it past its
    /// laid-out origin, accumulate that into the shared column offset (clamped so the badge
    /// stays on screen), and report the new offset up to the manager.
    @objc private func handleBadgeWindowMoved(_ notification: Notification) {
        // BY DESIGN: a drag STARTED during a badge grow/collapse animation (while our own
        // frames are in flight) is dropped here rather than recorded, so an animation's
        // intermediate frames can never be mistaken for a user drag. The cost is only that a
        // drag begun in that brief window may snap back; the user simply drags again.
        guard programmaticFrameChangeDepth == 0 else { return }
        guard let movedWindow = notification.object as? NSWindow, movedWindow === badgePanel else { return }
        guard let rawVisibleFrame = NSScreen.main?.visibleFrame else { return }

        // Where layout last placed the window (the window hangs down from `currentSlotTopLeft`,
        // which already folds in the current drag offset).
        let size = windowContentSize(for: visualState)
        let expectedOrigin = ResearchToastLayout.windowOrigin(slotTopLeft: currentSlotTopLeft, contentSize: size)
        let actualOrigin = movedWindow.frame.origin
        let dragDelta = CGVector(dx: actualOrigin.x - expectedOrigin.x, dy: actualOrigin.y - expectedOrigin.y)
        guard abs(dragDelta.dx) > dragMovementEpsilon || abs(dragDelta.dy) > dragMovementEpsilon else { return }

        // The badge's visible pill rect at drag offset ZERO (only the test offset applied) —
        // the reference the clamp keeps on screen.
        let baseFrame = rawVisibleFrame.offsetBy(dx: testAnchorOriginOffset.dx, dy: testAnchorOriginOffset.dy)
        let baseSlot = ResearchToastLayout.slotTopLeftOrigin(
            index: 0,
            corner: .topLeft,
            visibleFrame: baseFrame,
            edgeInset: ResearchRecentsLayout.screenEdgeInset
        )
        let baseWindowOrigin = ResearchToastLayout.windowOrigin(slotTopLeft: baseSlot, contentSize: size)
        let pillRectInWindow = ResearchToastLayout.pillRect(inWindowOfSize: size, pillSize: contentPillSize(for: visualState))
        let basePillScreenRect = CGRect(
            x: baseWindowOrigin.x + pillRectInWindow.minX,
            y: baseWindowOrigin.y + pillRectInWindow.minY,
            width: pillRectInWindow.width,
            height: pillRectInWindow.height
        )
        let newOffset = ResearchOverlayDragOffset.clamp(
            ResearchOverlayDragOffset.accumulate(current: userColumnDragOffset, delta: dragDelta),
            basePillScreenRect: basePillScreenRect,
            visibleFrame: baseFrame
        )
        onUserColumnDragged?(newOffset)
    }

    /// Adopts a new shared drag offset (from the manager syncing a drag, or restoring the
    /// persisted value) and re-places the badge window instantly so it shifts to it.
    func applyUserColumnDragOffset(_ offset: CGVector) {
        userColumnDragOffset = offset
        guard badgePanel != nil else { return }
        updateSlotTopLeft()
        applyFrame(animated: false)
    }

    /// Transitions to a new visual state: the window frame + CONTENT morph are INTERPOLATED
    /// (animated) so the square reads as growing open into the list (and collapsing back),
    /// unless Reduce Motion is on (then a synchronous jump). CRITICALLY, the hover + cursor
    /// tracking regions are set to the FINAL rect IMMEDIATELY inside `applyFrame` (never
    /// animated), so the grown hit region is live at the instant the open begins — no dead
    /// zone even while the frame animates.
    private func setVisualState(_ newState: ResearchRecentsBadgeVisualState) {
        guard visualState != newState else { return }
        visualState = newState
        badgeModel.reduceMotionEnabled = reduceMotionEnabled
        applyFrame(animated: !reduceMotionEnabled)
        badgeModel.state = newState
        if newState != .resting {
            badgePanel?.orderFrontRegardless()
        }
    }

    // MARK: - Hover / list interaction

    /// Hover changed on the badge. While RESTING, hovering the square opens the recents
    /// list DIRECTLY (no intermediate elongated pill) — the badge only ever shows with
    /// zero active toasts, so there is nothing to disambiguate. While the LIST is open,
    /// hover only drives the menu-style auto-hide (entering cancels it, leaving schedules
    /// it) — hover never collapses an intentionally-opened list synchronously.
    private func handleBadgeHover(_ hovering: Bool) {
        switch visualState {
        case .listOpen:
            if hovering {
                listAutoHideWorkItem?.cancel()
                listAutoHideWorkItem = nil
            } else {
                scheduleListAutoHide()
            }
        case .resting:
            // Hovering the resting square opens the list directly; hover-out while resting
            // is a no-op (the list's own auto-hide handles closing once it is open).
            if hovering {
                openList()
            }
        }
    }

    /// Opens the inline recents list (loads fresh rows first) by growing the window
    /// vertically into the same surface, straight from the resting square (no intermediate
    /// elongated pill). Toggling: tapping while already open collapses it.
    private func openList() {
        if visualState == .listOpen {
            collapseToResting()
            return
        }
        rebuildListRows()
        setVisualState(.listOpen)
    }

    /// Collapses the inline list back to the resting badge.
    private func collapseToResting() {
        listAutoHideWorkItem?.cancel()
        listAutoHideWorkItem = nil
        setVisualState(.resting)
    }

    private func rebuildListRows() {
        let rows = recentRowsProvider?() ?? []
        let liveDismissed = liveDismissedSessionIDsProvider?() ?? []
        badgeModel.rows = rows.map { row in
            ResearchRecentsRowModel(
                row: row,
                isDismissed: ResearchRecentsDismissedDisplay.isDismissed(
                    row: row,
                    liveDismissedSessionIDs: liveDismissed
                ),
                actions: resolveActions(for: row)
            )
        }
    }

    /// Resolves the BOTH-outputs actions for a row (fenced on-disk deliverable → page
    /// action; transcript → conversation action) using the real `FileManager` existence
    /// check, keeping the same read-side fence History uses.
    private func resolveActions(for row: HistoryRow) -> ResearchRecentsRowActions {
        ResearchRecentsRowActions.resolve(for: row) { deliverablePath in
            FileManager.default.fileExists(atPath: (deliverablePath as NSString).expandingTildeInPath)
        }
    }

    /// If the list is open and the pointer has left it, schedule a short-grace auto-hide
    /// (menu-style). Any re-entry cancels it.
    private func scheduleListAutoHide() {
        listAutoHideWorkItem?.cancel()
        listAutoHideWorkItem = nil
        guard visualState == .listOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.listAutoHideWorkItem = nil
            if self.visualState == .listOpen {
                self.collapseToResting()
            }
        }
        listAutoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + listAutoHideGraceSeconds, execute: work)
    }

    // MARK: - Test hooks

    var badgePanelForTesting: NSPanel? { badgePanel }
    /// The badge's current slot top-left (screen coords), so a test can prove a synced drag
    /// offset shifts the badge's placement.
    var slotTopLeftForTesting: CGPoint { currentSlotTopLeft }
    /// The current shared drag offset, so a test can assert the manager synced it in.
    var userColumnDragOffsetForTesting: CGVector { userColumnDragOffset }
    var isBadgeVisibleForTesting: Bool { badgePanel?.isVisible == true }
    var visualStateForTesting: ResearchRecentsBadgeVisualState { visualState }
    var isListOpenForTesting: Bool { visualState == .listOpen }
    /// The rows the inline list is currently showing (drives content/order assertions).
    var listRowModelsForTesting: [ResearchRecentsRowModel] { badgeModel.rows }
    /// The ACTUALLY-installed hover `NSTrackingArea` rect (the real resting hit region the
    /// OS uses) — so a test can pin it to the mini pill at rest (item 2 invariant).
    var installedHoverTrackingRectForTesting: CGRect {
        trackingView?.installedHoverTrackingRectForTesting ?? .zero
    }
    /// The current Clawdy-cursor region — the whole visible surface in every state (mini
    /// badge, expanded pill, and open inline list) — so a test can prove the cursor region
    /// covers the recents surface consistently (item 4).
    var cursorRectForTesting: CGRect { trackingView?.cursorRectForTesting ?? .zero }
    /// The ACTUALLY-installed Clawdy-cursor `NSTrackingArea` (present in every visible
    /// state) — so a test proves it carries `[.cursorUpdate, .activeAlways]`, the mechanism
    /// that works on a non-key panel (item 4), rather than a dead `addCursorRect`.
    var installedCursorTrackingAreaForTesting: NSTrackingArea? {
        trackingView?.installedCursorTrackingAreaForTesting
    }
    /// Runs the REAL cursor-application path used by the live `.cursorUpdate` event, so a
    /// test can prove it makes the Clawdy cursor the current cursor.
    func applyClawdyCursorForTesting() { trackingView?.applyClawdyCursorForTesting() }
    /// Runs the REAL `hitTest` the OS uses for mouse-CLICK delivery, so a test can prove a
    /// point in the transparent aura margin is click-through (nil) while a point on the
    /// visible badge/list surface resolves to a real view.
    func hitTestForTesting(_ point: NSPoint) -> NSView? { trackingView?.hitTest(point) }
    /// Drives the REAL badge-tap path (open/close the list), so a test can prove the click
    /// opens the inline list with the freshly-built rows.
    func toggleListForTesting() { openList() }
    /// Drives the REAL badge hover path, so a test can prove hovering the resting square
    /// opens the list DIRECTLY and the resting hit region equals the square.
    func setBadgeHoverForTesting(_ hovering: Bool) { handleBadgeHover(hovering) }
    /// The TARGET window content size for the current visual state — the size the window
    /// animates TO. Lets a test assert the grown/collapsed geometry synchronously without
    /// waiting on the (now interpolated) frame animation to settle.
    var targetWindowContentSizeForTesting: CGSize { windowContentSize(for: visualState) }
}

// MARK: - Badge SwiftUI content

/// The ONE persistent recents surface: a SINGLE dark rounded-rect fill wearing a SINGLE
/// Clawdy red-aura glow, sized to `size` with corner radius `cornerRadius`, with its inner
/// content drawn INSIDE (and clipped to) that one rounded shape. This is the shared layer
/// both visual states render into — so when the caller drives `size`/`cornerRadius` from the
/// badge state and animates the change, the background rect AND the aura GROW as one
/// continuous surface from the resting square to the full inline list (and shrink back),
/// instead of the old cross-fade that popped two separately-backed subtrees in at final size.
///
/// The surface draws EXACTLY one background fill and EXACTLY one `.clawdyGlow`; the content
/// it wraps must draw NEITHER (it may only fade/transition), so there is never a second
/// popping background or aura. The glow's bloom (default 10pt radius ⇒ ~13pt bloom) stays
/// inside the panel's `shadowMargin` clear margin at every interpolated size, so the aura is
/// always a soft contained halo, never a clipped hard rectangle.
struct ResearchRecentsMorphingSurface<SurfaceContent: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    @ViewBuilder var content: () -> SurfaceContent

    var body: some View {
        let surfaceShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content()
            // Lay the content out at the surface's current size, anchored TOP-LEADING so the
            // square's origin stays put and the surface grows DOWN/RIGHT — matching the
            // window frame's top-left anchor. Content larger than the current size (the full
            // list while the surface is still small mid-grow) simply overflows and is clipped.
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // The SINGLE dark surface fill — the only background this whole subtree draws.
            .background(surfaceShape.fill(ResearchToastSurfaceAppearance.background))
            // Clip the inner content to the rounded silhouette so nothing spills past the
            // growing/shrinking surface edge during the morph.
            .clipShape(surfaceShape)
            // The SINGLE shared Clawdy red-aura, following the SAME interpolated corner
            // radius, so the border-aura grows in lockstep with the fill as one layer.
            .clawdyGlow(cornerRadius: cornerRadius)
    }
}

/// The badge window's SwiftUI root: the ONE persistent morphing surface, sized + cornered to
/// FILL the window's CURRENT content rect (read live via `GeometryReader`) so the square GROWS
/// into the inline list — the dark fill and the blue border-aura together — as one continuous
/// surface, never a cross-fade.
///
/// SINGLE SOURCE OF TRUTH for the growth: the controller's AppKit window-frame animation
/// (`applyFrame(animated:)`, top-left anchored) is the ONLY animator. The surface here does NOT
/// run its own size/`.animation(value: model.state)` — it simply fills `proxy.size` (the window
/// content minus the shadow-margin padding) at whatever size the window frame is currently at,
/// pinned at the `GeometryReader`'s own top-leading origin. Because that origin is the window's
/// top-left inset by `shadowMargin` at EVERY frame, the surface's on-screen top-left is
/// invariant across resting ⇄ listOpen and throughout the whole animation — the square never
/// translates; only its width/height/cornerRadius change. This removes the old down+right hover
/// jitter, which was two competing size animations (AppKit window frame vs a SwiftUI
/// `.frame` + `.easeInOut` on `model.state`) drifting apart on different clocks.
///
/// Only the inner glyph⇄list CROSSFADE still animates in SwiftUI (opacity is the sole
/// state-driven property inside the surface); the surface geometry comes wholly from the live
/// window size. Under Reduce Motion the window frame jumps synchronously (no AppKit animation),
/// the geometry snaps with it, and the crossfade animation is nil — a synchronous jump, as before.
private struct ResearchRecentsBadgeRootView: View {
    @ObservedObject var model: ResearchRecentsBadgeModel

    private var isListOpen: Bool { model.state == .listOpen }

    var body: some View {
        GeometryReader { proxy in
            // The LIVE content size the window frame is currently at (its content rect minus the
            // shadow-margin padding below). During the grow this is an intermediate size; at rest
            // it is the 44×44 square; open it is the full list. The corner radius is derived from
            // the SAME live size (mapped back to a 0…1 progress) so fill, clip, and aura all track
            // the window in perfect lockstep.
            let liveSurfaceSize = proxy.size
            let liveListOpenProgress = ResearchRecentsSurfaceMorph.listOpenProgress(forCurrentSize: liveSurfaceSize)
            let liveCornerRadius = ResearchRecentsSurfaceMorph.cornerRadius(atListOpenProgress: liveListOpenProgress)
            ResearchRecentsMorphingSurface(
                size: liveSurfaceSize,
                cornerRadius: liveCornerRadius
            ) {
                // Both states' inner CONTENT overlaid top-leading inside the one surface; they
                // fade across on the morph (opacity only — neither draws its own background or
                // glow, so nothing pops). The resting glyph stays pinned at the top-left square
                // as the surface grows past it, then fades out; the list fades in filling the
                // grown surface.
                ZStack(alignment: .topLeading) {
                    ResearchRecentsInlineListContent(model: model)
                        .opacity(isListOpen ? 1 : 0)
                        .allowsHitTesting(isListOpen)
                    ResearchRecentsBadgeGlyph()
                        .opacity(isListOpen ? 0 : 1)
                        .allowsHitTesting(!isListOpen)
                        .contentShape(Rectangle())
                        .onTapGesture { model.onTapBadge?() }
                }
                // ONLY the glyph⇄list crossfade animates here — opacity is the sole state-driven
                // property in this subtree, so this cannot move the surface geometry (that is
                // driven by the window size above) and so cannot compete with the window frame
                // animation. Reduce Motion → nil animation → the opacity snaps synchronously.
                .animation(
                    model.reduceMotionEnabled
                        ? nil
                        : .easeInOut(duration: ResearchRecentsLayout.growthAnimationDuration),
                    value: isListOpen
                )
            }
        }
        // Inset the whole surface by the shared shadow margin so its top-left matches the
        // controller's `pillRect` (top-leading, inset by `shadowMargin`) and the glow bloom stays
        // inside the clear margin. `proxy.size` above is therefore the window content minus this
        // padding — i.e. the resting square / open list footprint exactly.
        .padding(ResearchToastLayout.shadowMargin)
    }
}

/// The resting badge's inner CONTENT only — the cursor-inspired glyph, drawn on the shared
/// morphing surface behind it. It carries NO background fill and NO glow of its own (the one
/// `ResearchRecentsMorphingSurface` owns the single fill + aura), so it can never pop a
/// second surface in during the morph.
private struct ResearchRecentsBadgeGlyph: View {
    var body: some View {
        let size = ResearchRecentsLayout.restingBadgeSize
        // The visible glyph keeps the same ~18pt footprint the old `cursorarrow` symbol had
        // (it rendered at 18pt inside this same 44×44 badge square), so swapping the image
        // does not change the glyph's size or the badge geometry.
        let glyphSize: CGFloat = 18
        // Centered in the square. The resting glyph is the Clawdy claw (the SAME `CursorClaw`
        // template silhouette the pointing cursor uses, tinted with the `openClawRed` brand
        // token), so the idle badge presence matches the menu-bar icon and the flying cursor.
        return Image("CursorClaw")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(DS.Colors.openClawRed)
            .frame(width: glyphSize, height: glyphSize)
            .frame(width: size.width, height: size.height)
    }
}

// MARK: - Inline recents list SwiftUI content

/// The recents list's inner CONTENT only (header + rows + footer), drawn on the shared
/// morphing surface behind it. Deliberately SPARSE — matching the restraint of the research
/// toast: a quiet header + close (×), one clean left-aligned column of single-line rows (each
/// carrying only the run's title and ONE quiet trailing signal, its two actions revealed on
/// hover), and a quiet "Show all history" link. No dividers, no per-row cards at rest, no
/// chip rows — whitespace and a calm type hierarchy do the separating. It draws NO background
/// fill and NO glow of its own — the one `ResearchRecentsMorphingSurface` owns the single
/// dark `surface1` fill + Clawdy aura — so the surface never pops a second layer on the morph.
struct ResearchRecentsInlineListContent: View {
    @ObservedObject var model: ResearchRecentsBadgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.control) {
            header
            if model.rows.isEmpty {
                emptyState
            } else {
                rowsScroll
            }
            footer
        }
        .padding(DS.Spacing.lg)
        .frame(width: ResearchRecentsLayout.inlineListSize.width,
               height: ResearchRecentsLayout.inlineListSize.height)
    }

    /// A quiet header: just a small secondary-tone label and the close affordance — no
    /// accent-coloured icon, no divider beneath it (the whitespace below is the separation).
    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            Text("Recent research")
                .font(DS.Font.controlLabel)
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            // The canonical circular icon control, with the pointer cursor opted OUT because
            // this overlay panel never becomes key (its `addCursorRect` cursor would be dead;
            // the badge window's `.cursorUpdate` tracking area supplies the Clawdy cursor).
            CircularIconButton(
                systemName: "xmark",
                helpText: "Close",
                showsPointerCursor: false,
                action: { model.onCloseList?() }
            )
        }
    }

    private var rowsScroll: some View {
        ScrollView {
            LazyVStack(spacing: DS.Spacing.hairline) {
                ForEach(model.rows) { rowModel in
                    ResearchRecentsRowView(
                        rowModel: rowModel,
                        onPerformAction: { action in model.onPerformRowAction?(action) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text("No research yet")
            .font(DS.Font.overlayBodyRegular)
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Spacing.xl)
    }

    private var footer: some View {
        ResearchRecentsShowAllButton(action: { model.onShowAllHistory?() })
    }
}

/// One recents row, trimmed to the minimum that IDENTIFIES a run: the task title in a
/// few words plus ONE quiet trailing signal (a relative time, or a short status word for a
/// live/failed/stopped run — never both, never a kind pill + dot + label + time stack).
/// The whole row is clickable and opens the conversation in History (the default action);
/// the results-page affordance is preserved but presented QUIETLY: at rest the row is just
/// title + signal, and on hover the trailing signal is replaced by a compact, icon-less
/// single-word "Results" label (only when a fenced, on-disk deliverable exists). The redundant "View
/// conversation" icon is dropped — the whole-row click covers it. A DISMISSED row is dimmed
/// and its signal reads "dismissed".
private struct ResearchRecentsRowView: View {
    let rowModel: ResearchRecentsRowModel
    let onPerformAction: (ResearchRecentsRowAction) -> Void

    @State private var isHovering = false

    private var row: HistoryRow { rowModel.row }

    private var secondarySignal: ResearchRecentsRowSecondarySignal {
        ResearchRecentsRowSecondarySignal.forRow(row, isDismissed: rowModel.isDismissed)
    }

    var body: some View {
        HStack(spacing: DS.Spacing.control) {
            Text(row.displayTitle)
                // 12.5pt sits between the 12pt `overlayBody` and 13pt `detailBody` tokens —
                // a deliberate one-off for the recents row title, so it is left inline.
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.sm)
            // Trailing slot: both states are always in the layout so the row width never
            // changes on hover. The ZStack is sized to whichever child is wider; opacity
            // cross-fades between them and allowsHitTesting prevents invisible buttons
            // from being clickable.
            ZStack(alignment: .trailing) {
                Text(secondarySignal.text)
                    .font(DS.Font.overlayCaptionRegular)
                    .foregroundColor(signalColor)
                    .lineLimit(1)
                    .opacity(isHovering ? 0 : 1)
                hoverActions
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.control)
        // 9pt vertical has no DS.Spacing token (between `snug` 6 and `control` 10) — a
        // deliberate one-off tuning the row's resting height, so it is left inline.
        .padding(.vertical, 9)
        // No card at rest — only a faint highlight on hover, so the list reads as one
        // calm column separated by whitespace rather than a stack of boxes.
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isHovering ? DS.Colors.surface2.opacity(0.6) : Color.clear)
        )
        // Dismissed sessions read as muted (the run was hidden by the user), while still
        // being fully clickable/reopenable.
        .opacity(rowModel.isDismissed ? 0.5 : 1.0)
        .contentShape(Rectangle())
        // Whole-row default click (mouse) → open the conversation in History (the
        // `.openHistory` action). The results page stays reachable via the hover
        // "Results" label for mouse users.
        .onTapGesture { onPerformAction(rowModel.actions.conversation) }
        // Shared hover primitive; pointer cursor opted OUT (this overlay panel never becomes
        // key, so a cursor rect would be dead — the badge window's tracking area supplies it).
        .trackingHover($isHovering, showsPointerCursor: false)
        .help(row.displayTitle)
        // Expose the whole row as a SINGLE actionable button to VoiceOver / keyboard: its
        // primary (activation) action opens the conversation in History, matching the mouse
        // click. Because the "Results" hover label has no hover state under VoiceOver (it is
        // `accessibilityHidden` at rest), the results page is offered here as a NAMED
        // secondary action when a fenced deliverable exists — so both outputs stay reachable
        // without a nested button / hit-test overlap.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Open \(row.displayTitle) in History"))
        .accessibilityAction { onPerformAction(rowModel.actions.conversation) }
        .accessibilityActions { pageAccessibilityAction }
    }

    /// The "View results" results affordance as a NAMED accessibility action, present only
    /// when a fenced deliverable exists — the VoiceOver/keyboard counterpart of the hover
    /// control. The accessibility label stays the descriptive "View results" even though the
    /// on-screen control now reads just "Results", so VoiceOver still announces what it does.
    @ViewBuilder
    private var pageAccessibilityAction: some View {
        if let pageAction = rowModel.actions.page {
            Button("View results") { onPerformAction(pageAction) }
        }
    }

    /// The results-page affordance, shown only on hover: a compact, icon-less single-word
    /// "Results" label, only when a fenced deliverable exists. The conversation is reached via
    /// the whole-row click, so its own hover control is no longer offered.
    private var hoverActions: some View {
        HStack(spacing: DS.Spacing.md) {
            if let pageAction = rowModel.actions.page {
                ResearchRecentsRowResultsAction(action: { onPerformAction(pageAction) })
            }
        }
    }

    private var signalColor: Color {
        switch secondarySignal.tone {
        case .neutral: return DS.Colors.textTertiary
        case .active: return DS.Colors.accent
        case .failure: return DS.Colors.destructiveText
        case .warning: return DS.Colors.warning
        }
    }
}

/// The per-row "Results" affordance, revealed on row hover — a compact, icon-less single-word
/// "Results" label (no leading glyph, no chevron) so it stays on ONE line at the narrow recents
/// panel width instead of wrapping. Uses `DS.Font.linkLabel`, brightens from `accent` to
/// `textPrimary` on hover, and an accent-tinted rounded background fades in on hover. Padding is
/// CONSTANT so the control's frame never changes on hover; only the background highlight fades.
/// The label is pinned to a single line (`.lineLimit(1)` + `.fixedSize`) so it can never wrap or
/// truncate. The pointer cursor is opted OUT (`showsPointerCursor: false`) because this overlay
/// panel never becomes key, so a cursor rect would be dead — the badge window's tracking area
/// supplies the cursor instead.
private struct ResearchRecentsRowResultsAction: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Results")
                .font(DS.Font.linkLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.accent)
            // Padding is always present so the control frame never changes on hover;
            // only the background highlight fades in/out.
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.accent.opacity(isHovering ? 0.22 : 0))
            )
        }
        .buttonStyle(.plain)
        .trackingHover($isHovering, showsPointerCursor: false)
        .help("View results page")
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The "Show all history" footer link — opens the full History window for the rest
/// beyond the top-N. Quiet by default (tertiary text, no accent fill, no chevron);
/// brightens and underlines on hover.
private struct ResearchRecentsShowAllButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Show all history")
                .font(DS.Font.overlayCaption)
                .foregroundColor(isHovering ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        // Shared hover primitive with the pointer cursor opted OUT: `.pointerCursor()` installs
        // an `addCursorRect`, which AppKit only honors for the KEY window — this non-activating
        // overlay panel never becomes key, so it is dead. The whole surface inherits the Clawdy
        // cursor from the badge window's `.cursorUpdate` tracking area instead. The visual hover
        // affordance (highlight / underline) above is retained.
        .trackingHover($isHovering, showsPointerCursor: false)
        .help("Open the full History window")
    }
}
