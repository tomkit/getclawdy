//
//  ResearchRecentsTests.swift
//  ClawdyTests
//
//  Covers the always-present recents badge + top-N recents list:
//   (a) the recents list CONTENT/ORDER equals the History source (reuse
//       `HistoryRowBuilder`; top-N slice, quick-answers grouping, reverse-chron),
//   (b) the VISIBILITY rule: the badge shows IFF there are zero active toasts — pure,
//       plus a real-path drive through the manager (start hides it, dismiss restores it),
//   (c) the row BOTH-outputs ACTION mapping (item 3): every row offers "View
//       conversation"; a fenced, on-disk deliverable ALSO offers "View page",
//   (d) the DISMISSED-vs-not affordance selection (persisted flag OR live set → dimmed),
//   (e) the badge WINDOW is non-zero and torn down cleanly; interacting grows the SAME
//       window vertically into the inline list (no separate window) DIRECTLY from the
//       resting square — never through an intermediate elongated pill; the resting hover
//       hit region == the badge's OWN square (item 2, disjoint from the shared toast
//       footprint); and the Clawdy-cursor region hugs the square badge (item 4),
//   plus the manifest persistence of the display-only dismissed flag.
//

import Testing
import Foundation
import AppKit
@testable import Clawdy

// MARK: - Shared fixtures

private func makeEntry(
    sessionId: String,
    kind: ResearchSessionKind,
    title: String = "",
    task: String = "",
    status: ResearchSessionStatus,
    createdAt: Date,
    updatedAt: Date,
    deliverablePath: String? = nil,
    dismissed: Bool? = nil
) -> ResearchManifestEntry {
    ResearchManifestEntry(
        sessionId: sessionId,
        kind: kind,
        title: title,
        task: task,
        status: status,
        createdAt: createdAt,
        updatedAt: updatedAt,
        workingDir: "/tmp/work/\(sessionId)",
        transcriptPath: "/tmp/work/\(sessionId)/\(sessionId).jsonl",
        deliverablePath: deliverablePath,
        dismissed: dismissed
    )
}

// MARK: - (a) Recents list mirrors the History source

struct ResearchRecentsListBuilderTests {

    /// The recents list is EXACTLY the History rows, sliced to the top-N — so it can
    /// never drift from History's content or order.
    @Test func recentsEqualsHistorySourceSlicedToTopN() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Seven research runs + two root entries (which collapse to ONE "Quick answers"
        // row), so the un-sliced History list has eight rows and top-5 must slice it.
        var entries: [ResearchManifestEntry] = []
        for index in 0..<7 {
            entries.append(makeEntry(
                sessionId: "research-\(index)", kind: .research, title: "Run \(index)",
                status: .completed,
                createdAt: base.addingTimeInterval(Double(index) * 100),
                updatedAt: base.addingTimeInterval(Double(index) * 100)
            ))
        }
        entries.append(makeEntry(sessionId: "root-a", kind: .root, status: .active,
                                 createdAt: base, updatedAt: base.addingTimeInterval(50)))
        entries.append(makeEntry(sessionId: "root-b", kind: .root, status: .active,
                                 createdAt: base.addingTimeInterval(60), updatedAt: base.addingTimeInterval(650)))

        let now = base.addingTimeInterval(2000)
        let expected = Array(HistoryRowBuilder.makeRows(from: entries, now: now).prefix(5))
        let actual = ResearchRecentsListBuilder.recentRows(from: entries, now: now)

        // Identical content AND order to the History source, sliced to N = 5.
        #expect(actual == expected)
        #expect(actual.count == 5)
        // The two root entries collapsed into a SINGLE grouped "Quick answers" row.
        let quickAnswerRows = HistoryRowBuilder.makeRows(from: entries, now: now)
            .filter { $0.displayTitle == HistoryRowBuilder.quickAnswersGroupTitle }
        #expect(quickAnswerRows.count == 1)
        // Reverse-chronological by last activity (each row's updatedAt is non-increasing).
        let updatedAts = actual.map(\.updatedAt)
        #expect(updatedAts == updatedAts.sorted(by: >))
    }

    /// A short history (< N) returns everything, still in History order.
    @Test func recentsReturnsAllWhenFewerThanTopN() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(sessionId: "a", kind: .research, title: "A", status: .completed,
                      createdAt: base, updatedAt: base.addingTimeInterval(10)),
            makeEntry(sessionId: "b", kind: .research, title: "B", status: .running,
                      createdAt: base.addingTimeInterval(20), updatedAt: base.addingTimeInterval(30)),
        ]
        let now = base.addingTimeInterval(100)
        let actual = ResearchRecentsListBuilder.recentRows(from: entries, now: now)
        #expect(actual.map(\.sessionId) == ["b", "a"])
    }
}

// MARK: - (b) Visibility rule (pure + real-path)

struct ResearchRecentsBadgeVisibilityTests {

    @Test func badgeShownIffZeroActiveToasts() {
        #expect(ResearchRecentsBadgeVisibility.shouldShowBadge(activeToastCount: 0) == true)
        #expect(ResearchRecentsBadgeVisibility.shouldShowBadge(activeToastCount: 1) == false)
        #expect(ResearchRecentsBadgeVisibility.shouldShowBadge(activeToastCount: 3) == false)
    }
}

/// A fake `claude` that emits an init line then hangs (execs sleep) so a started
/// research session stays `.running` — one active toast — until SIGTERM.
private func makeHangingResearchBinary() throws -> String {
    let scriptContents = """
    #!/bin/sh
    /bin/echo '{"type":"system","subtype":"init","session_id":"recents-sess"}'
    exec sleep 600
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

@MainActor
struct ResearchRecentsBadgeRealPathTests {

    /// REAL-PATH: the badge is visible while idle, HIDDEN the instant a research toast
    /// becomes active, and RETURNS when the toast is dismissed (zero active toasts).
    @Test func badgeSwapsWithActiveToastStack() async throws {
        let binaryPath = try makeHangingResearchBinary()
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-manifest-\(UUID().uuidString).json")
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-appsupport-\(UUID().uuidString)", isDirectory: true)

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { binaryPath },
            makeEngine: { _, path in
                ClaudeResearchEngine(
                    binaryPath: path,
                    homeDirectoryPath: NSTemporaryDirectory(),
                    planPhaseTimeoutSeconds: 60,
                    executePhaseTimeoutSeconds: 60
                )
            },
            generateSessionID: { UUID().uuidString.lowercased() },
            applicationSupportDirectory: appSupport,
            homeDirectoryPath: NSTemporaryDirectory(),
            manifestStore: ResearchManifestStore(fileURL: manifestURL),
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        // Idle at construction: zero toasts → badge shown.
        #expect(manager.renderedPillCountForTesting == 0)
        #expect(manager.recentsBadgeVisibleForTesting == true)

        // A live research toast takes over the top-left → badge hidden.
        let sessionID = manager.startSession(taskDescription: "research the web")
        #expect(manager.renderedPillCountForTesting == 1)
        #expect(manager.recentsBadgeVisibleForTesting == false)

        // Dismiss hides the toast chrome (run keeps going) → zero visible toasts → badge
        // returns.
        manager.dismissSession(id: sessionID)
        #expect(manager.renderedPillCountForTesting == 0)
        #expect(manager.recentsBadgeVisibleForTesting == true)
    }
}

// MARK: - (c) Row BOTH-outputs action mapping (item 3)

struct ResearchRecentsRowActionTests {

    private func row(deliverablePath: String?) -> HistoryRow {
        let entry = makeEntry(
            sessionId: "sess-1", kind: .research, title: "Desk research",
            status: deliverablePath == nil ? .stopped : .completed,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            deliverablePath: deliverablePath
        )
        return HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 100))
    }

    /// EVERY row exposes the "View conversation" (transcript / History) action, regardless
    /// of whether it produced a deliverable — that affordance is always available.
    @Test func everyRowAlwaysOffersConversation() {
        let withDeliverable = ResearchRecentsRowActions.resolve(for: row(deliverablePath: "/etc/passwd")) { _ in true }
        let withoutDeliverable = ResearchRecentsRowActions.resolve(for: row(deliverablePath: nil)) { _ in true }
        #expect(withDeliverable.conversation == .openHistory(sessionID: "sess-1"))
        #expect(withoutDeliverable.conversation == .openHistory(sessionID: "sess-1"))
    }

    /// The row's DEFAULT (whole-row) click opens the conversation in History. The row body
    /// wires its `.onTapGesture` to `actions.conversation`, so the default action is always
    /// `.openHistory` — whether or not a results page exists.
    @Test func rowDefaultClickActionIsOpenHistory() {
        let withDeliverable = ResearchRecentsRowActions.resolve(for: row(deliverablePath: "/etc/passwd")) { _ in true }
        let withoutDeliverable = ResearchRecentsRowActions.resolve(for: row(deliverablePath: nil)) { _ in true }
        #expect(withDeliverable.conversation == .openHistory(sessionID: "sess-1"),
                "the whole-row default click opens History")
        #expect(withoutDeliverable.conversation == .openHistory(sessionID: "sess-1"),
                "the whole-row default click opens History even without a deliverable")
    }

    /// A row whose deliverable is inside the research fence AND exists on disk ALSO offers
    /// the "View page" action — so the row offers BOTH outputs.
    @Test func fencedExistingDeliverableAlsoOffersPage() {
        let fencedPath = ClaudeResearchEngine.researchSupportDirectory()
            .appendingPathComponent("sess-1/report.html").path
        let actions = ResearchRecentsRowActions.resolve(for: row(deliverablePath: fencedPath)) { _ in true }
        #expect(actions.page == .openResults(sessionID: "sess-1", deliverablePath: fencedPath, title: "Desk research"))
        #expect(actions.conversation == .openHistory(sessionID: "sess-1"))
    }

    /// A fenced deliverable that no longer exists offers NO page action (only
    /// conversation) — no broken results window.
    @Test func fencedMissingDeliverableOffersNoPage() {
        let fencedPath = ClaudeResearchEngine.researchSupportDirectory()
            .appendingPathComponent("sess-1/report.html").path
        let actions = ResearchRecentsRowActions.resolve(for: row(deliverablePath: fencedPath)) { _ in false }
        #expect(actions.page == nil)
        #expect(actions.conversation == .openHistory(sessionID: "sess-1"))
    }

    /// No deliverable at all → no page action (only conversation).
    @Test func noDeliverableOffersNoPage() {
        let actions = ResearchRecentsRowActions.resolve(for: row(deliverablePath: nil)) { _ in true }
        #expect(actions.page == nil)
    }

    /// An OUT-OF-FENCE deliverable path (tampered manifest) is never offered as a page,
    /// even if it "exists" — the fence holds on the page action.
    @Test func outOfFenceDeliverableOffersNoPage() {
        let actions = ResearchRecentsRowActions.resolve(for: row(deliverablePath: "/etc/passwd")) { _ in true }
        #expect(actions.page == nil)
        #expect(actions.conversation == .openHistory(sessionID: "sess-1"))
    }
}

// MARK: - (c2) Trimmed single trailing signal (sparser IA)

struct ResearchRecentsRowSecondarySignalTests {

    private func row(
        sessionId: String,
        status: ResearchSessionStatus,
        updatedAtOffset: TimeInterval
    ) -> HistoryRow {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = makeEntry(
            sessionId: sessionId, kind: .research, title: "R", status: status,
            createdAt: base, updatedAt: base.addingTimeInterval(updatedAtOffset)
        )
        // `now` is 1 hour after base, so a 0-offset updatedAt reads as "1 hr ago".
        return HistoryRowBuilder.makeRow(from: entry, now: base.addingTimeInterval(3600))
    }

    /// A COMPLETED run surfaces the relative TIME as its one neutral signal — not a status
    /// word, not a kind pill, not a dot. This is the common, calm case.
    @Test func completedShowsRelativeTimeAsNeutralSignal() {
        let completed = row(sessionId: "a", status: .completed, updatedAtOffset: 0)
        let signal = ResearchRecentsRowSecondarySignal.forRow(completed, isDismissed: false)
        #expect(signal.text == completed.relativeTimestamp)
        #expect(signal.text == "1 hr ago")
        #expect(signal.tone == .neutral)
    }

    /// A LIVE run surfaces "running" in the quiet accent tone instead of a timestamp — the
    /// one state where the status matters more than the age.
    @Test func runningShowsStatusWordInActiveTone() {
        let running = row(sessionId: "b", status: .running, updatedAtOffset: 0)
        let signal = ResearchRecentsRowSecondarySignal.forRow(running, isDismissed: false)
        #expect(signal.text == "running")
        #expect(signal.tone == .active)
    }

    /// A FAILED run flags itself in the RED `.failure` tone (matching the live progress
    /// overlay's error color); a STOPPED run is a quiet neutral word.
    @Test func failedAndStoppedMapToTheirWords() {
        let failed = ResearchRecentsRowSecondarySignal.forRow(
            row(sessionId: "c", status: .failed, updatedAtOffset: 0), isDismissed: false)
        #expect(failed.text == "failed")
        #expect(failed.tone == .failure)

        let stopped = ResearchRecentsRowSecondarySignal.forRow(
            row(sessionId: "d", status: .stopped, updatedAtOffset: 0), isDismissed: false)
        #expect(stopped.text == "stopped")
        #expect(stopped.tone == .neutral)
    }

    /// A DISMISSED row collapses its one signal to the quiet "dismissed" tag regardless of
    /// its status — the preserved dismissed affordance (the view also dims the row).
    @Test func dismissedCollapsesToDismissedTag() {
        let completedButDismissed = row(sessionId: "e", status: .completed, updatedAtOffset: 0)
        let signal = ResearchRecentsRowSecondarySignal.forRow(completedButDismissed, isDismissed: true)
        #expect(signal.text == "dismissed")
        #expect(signal.tone == .neutral)
        // Dismissed wins even over a live run.
        let runningDismissed = row(sessionId: "f", status: .running, updatedAtOffset: 0)
        #expect(ResearchRecentsRowSecondarySignal.forRow(runningDismissed, isDismissed: true).text == "dismissed")
    }
}

// MARK: - (d) Dismissed-vs-not affordance selection

struct ResearchRecentsDismissedDisplayTests {

    private func row(sessionId: String, dismissed: Bool?) -> HistoryRow {
        let entry = makeEntry(
            sessionId: sessionId, kind: .research, title: "R", status: .completed,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            dismissed: dismissed
        )
        return HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 100))
    }

    @Test func persistedDismissedFlagReadsAsDismissed() {
        let dismissedRow = row(sessionId: "a", dismissed: true)
        #expect(dismissedRow.isDismissed == true)
        #expect(ResearchRecentsDismissedDisplay.isDismissed(row: dismissedRow, liveDismissedSessionIDs: []) == true)
    }

    @Test func liveDismissedSetReadsAsDismissedEvenWithoutPersistedFlag() {
        let normalRow = row(sessionId: "b", dismissed: nil)
        #expect(normalRow.isDismissed == false)
        #expect(ResearchRecentsDismissedDisplay.isDismissed(row: normalRow, liveDismissedSessionIDs: ["b"]) == true)
    }

    @Test func nonDismissedReadsAsNormal() {
        let normalRow = row(sessionId: "c", dismissed: nil)
        #expect(ResearchRecentsDismissedDisplay.isDismissed(row: normalRow, liveDismissedSessionIDs: ["other"]) == false)
    }
}

// MARK: - (e) Badge window contract (real-path)

@MainActor
struct ResearchRecentsBadgeWindowTests {

    @Test func badgeWindowIsNonZeroAndTornDownCleanly() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.show()

        let panel = controller.badgePanelForTesting
        #expect(panel != nil)
        #expect((panel?.frame.width ?? 0) > 0)
        #expect((panel?.frame.height ?? 0) > 0)
        // sharingType = .none so the badge never leaks into a captured screenshot.
        #expect(panel?.sharingType == NSWindow.SharingType.none)

        controller.hide()
        #expect(controller.badgePanelForTesting == nil)
        #expect(controller.isBadgeVisibleForTesting == false)
    }

    /// Tapping the badge grows the SAME window vertically to render the inline recents
    /// list (no separate window), populated from the fresh rows (newest first), each
    /// carrying BOTH its actions; the persisted-dismissed row is marked dismissed. A
    /// second tap collapses it back to the resting badge. The window frame is now
    /// INTERPOLATED (animated) so the target geometry is asserted synchronously via
    /// `targetWindowContentSizeForTesting` rather than the mid-animation frame.
    @Test func clickingBadgeOpensInlineListWithFreshRowsAndToggleCloses() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(sessionId: "r1", kind: .research, title: "One", status: .completed,
                      createdAt: base, updatedAt: base.addingTimeInterval(10), dismissed: true),
            makeEntry(sessionId: "r2", kind: .research, title: "Two", status: .running,
                      createdAt: base.addingTimeInterval(20), updatedAt: base.addingTimeInterval(30)),
        ]

        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.recentRowsProvider = {
            ResearchRecentsListBuilder.recentRows(from: entries, now: base.addingTimeInterval(100))
        }
        controller.liveDismissedSessionIDsProvider = { [] }
        controller.show()

        #expect(controller.visualStateForTesting == .resting)
        let restingTargetSize = controller.targetWindowContentSizeForTesting

        // First tap opens the inline list IN THE SAME WINDOW (same panel identity), the
        // window growing taller than the resting badge — there is no separate list panel.
        let restingPanel = controller.badgePanelForTesting
        controller.toggleListForTesting()
        #expect(controller.isListOpenForTesting == true)
        #expect(controller.badgePanelForTesting === restingPanel)
        #expect(controller.targetWindowContentSizeForTesting.height > restingTargetSize.height)

        let rowModels = controller.listRowModelsForTesting
        #expect(rowModels.map(\.row.sessionId) == ["r2", "r1"])
        #expect(rowModels.first(where: { $0.row.sessionId == "r1" })?.isDismissed == true)
        #expect(rowModels.first(where: { $0.row.sessionId == "r2" })?.isDismissed == false)
        // Every row always offers the conversation output.
        #expect(rowModels.allSatisfy { $0.actions.conversation == .openHistory(sessionID: $0.row.sessionId) })

        // Second tap collapses back to the resting badge (same window, shrunk to the square).
        controller.toggleListForTesting()
        #expect(controller.isListOpenForTesting == false)
        #expect(controller.visualStateForTesting == .resting)
        #expect(controller.targetWindowContentSizeForTesting == restingTargetSize)

        controller.hide()
    }

    /// The exact SQUARE pill rect (origin + size) the resting badge occupies — its OWN
    /// footprint, DISJOINT from the shared toast `restingPillSize`.
    private var restingSquarePillRect: CGRect {
        ResearchToastLayout.pillRect(
            inWindowOfSize: ResearchRecentsLayout.restingWindowContentSize,
            pillSize: ResearchRecentsLayout.restingBadgeSize
        )
    }

    /// The exact inline-list pill rect (origin + size) the open list occupies.
    private var inlineListPillRect: CGRect {
        let listWindowSize = CGSize(
            width: ResearchRecentsLayout.inlineListSize.width + ResearchToastLayout.shadowMargin * 2,
            height: ResearchRecentsLayout.inlineListSize.height + ResearchToastLayout.shadowMargin * 2
        )
        return ResearchToastLayout.pillRect(
            inWindowOfSize: listWindowSize,
            pillSize: ResearchRecentsLayout.inlineListSize
        )
    }

    /// ITEM 2 INVARIANT (SQUARE): at REST the target window AND the actually-installed hover
    /// tracking area are EXACTLY the badge's OWN square — there is no phantom hover region
    /// over the empty space the expansion would grow into, and the square is DISJOINT from
    /// the shared toast footprint (proving `restingPillSize` was not repurposed).
    /// ITEM 1 (DIRECT-TO-LIST): hovering the resting square opens the recents list DIRECTLY
    /// — there is no intermediate elongated pill state, and the grown hit region is live
    /// IMMEDIATELY (synchronously) even though the window frame animates open.
    @Test func restingHoverRegionEqualsSquareAndHoverOpensListDirectly() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.recentRowsProvider = { [] }
        controller.liveDismissedSessionIDsProvider = { [] }
        controller.show()

        // Resting: target window == the badge's own SQUARE window; installed hover tracking
        // area == the square pill rect (full rect, so a mis-positioned region can't pass).
        #expect(controller.visualStateForTesting == .resting)
        #expect(controller.targetWindowContentSizeForTesting == ResearchRecentsLayout.restingWindowContentSize)
        #expect(controller.installedHoverTrackingRectForTesting == restingSquarePillRect,
                "At rest the OS hover hit region must be the badge's own square, not the shared toast footprint")
        // DISJOINT from the shared toast resting footprint — the square is a different shape.
        #expect(ResearchRecentsLayout.restingBadgeSize != ResearchStackFrameLayout.restingPillSize)
        #expect(ResearchRecentsLayout.restingBadgeSize.width == ResearchRecentsLayout.restingBadgeSize.height,
                "the resting footprint is a square")

        // Hover: opens the LIST directly (no intermediate elongated pill), and the hover hit
        // region is set to the FINAL grown list rect IMMEDIATELY (no dead zone), even though
        // the window frame animates to full size.
        controller.setBadgeHoverForTesting(true)
        #expect(controller.isListOpenForTesting == true)
        #expect(controller.installedHoverTrackingRectForTesting == inlineListPillRect,
                "the grown hover hit region is live immediately, before the frame animation settles")

        controller.hide()
    }

    /// ITEM 1 INVARIANT (DIRECT OPEN): opening always goes resting → listOpen with NO
    /// intermediate elongated pill — the `.hoverExpanded` state was retired from the enum
    /// entirely, so both the hover path AND the tap path land straight in `.listOpen`. (The
    /// removed case can't be referenced here; its structural absence is the strongest proof.)
    @Test func openingTransitionsRestingToListOpenDirectly() {
        // Hover path.
        let hoverController = ResearchRecentsBadgeController.offscreenForTesting()
        hoverController.recentRowsProvider = { [] }
        hoverController.liveDismissedSessionIDsProvider = { [] }
        hoverController.show()
        #expect(hoverController.visualStateForTesting == .resting)
        hoverController.setBadgeHoverForTesting(true)
        #expect(hoverController.visualStateForTesting == .listOpen)
        hoverController.hide()

        // Tap path.
        let tapController = ResearchRecentsBadgeController.offscreenForTesting()
        tapController.recentRowsProvider = { [] }
        tapController.liveDismissedSessionIDsProvider = { [] }
        tapController.show()
        #expect(tapController.visualStateForTesting == .resting)
        tapController.toggleListForTesting()
        #expect(tapController.visualStateForTesting == .listOpen)
        tapController.hide()
    }

    /// ITEM 4 INVARIANT: the Clawdy-cursor region covers the whole visible recents surface
    /// in EVERY state — the mini badge at rest AND the open inline list — so the surface
    /// reads as Clawdy's own cursor consistently. In each state the installed cursor tracking
    /// area exists, carries `[.cursorUpdate, .activeAlways]` (the mechanism that works on a
    /// non-key panel — not a dead `addCursorRect`), covers the full state rect (origin +
    /// size), and invoking the path sets the Clawdy cursor as current.
    @Test func clawdyCursorRegionCoversSurfaceIncludingOpenList() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.recentRowsProvider = { [] }
        controller.liveDismissedSessionIDsProvider = { [] }
        controller.show()

        // RESTING: FULL rect (origin + size) — the badge's OWN square pill rect, not merely
        // its size, and not the shared toast footprint.
        let restingPillRect = ResearchToastLayout.pillRect(
            inWindowOfSize: ResearchRecentsLayout.restingWindowContentSize,
            pillSize: ResearchRecentsLayout.restingBadgeSize
        )
        #expect(controller.cursorRectForTesting == restingPillRect)
        let restingCursorArea = controller.installedCursorTrackingAreaForTesting
        #expect(restingCursorArea != nil)
        #expect(restingCursorArea?.options.contains(.cursorUpdate) == true)
        #expect(restingCursorArea?.options.contains(.activeAlways) == true)
        #expect(restingCursorArea?.rect == restingPillRect)

        // The REAL cursor path (what the live `.cursorUpdate` event runs) sets the Clawdy
        // cursor as the current cursor.
        controller.applyClawdyCursorForTesting()
        #expect(NSCursor.current == ResearchToastCursor.clawdy)

        // LIST OPEN: the cursor region now covers the INLINE LIST rect (full rect) — the
        // open list reads as the Clawdy cursor too, NOT the system arrow. The area still
        // carries the same reliable options and the path still sets the Clawdy cursor.
        controller.toggleListForTesting()
        #expect(controller.isListOpenForTesting == true)
        let listWindowSize = CGSize(
            width: ResearchRecentsLayout.inlineListSize.width + ResearchToastLayout.shadowMargin * 2,
            height: ResearchRecentsLayout.inlineListSize.height + ResearchToastLayout.shadowMargin * 2
        )
        let listRect = ResearchToastLayout.pillRect(
            inWindowOfSize: listWindowSize,
            pillSize: ResearchRecentsLayout.inlineListSize
        )
        #expect(controller.cursorRectForTesting == listRect)
        let listCursorArea = controller.installedCursorTrackingAreaForTesting
        #expect(listCursorArea != nil)
        #expect(listCursorArea?.options.contains(.cursorUpdate) == true)
        #expect(listCursorArea?.options.contains(.activeAlways) == true)
        #expect(listCursorArea?.rect == listRect)
        controller.applyClawdyCursorForTesting()
        #expect(NSCursor.current == ResearchToastCursor.clawdy)

        controller.hide()
    }

    /// CLICK-THROUGH HALO: the transparent Clawdy-aura margin around the badge must NOT swallow
    /// clicks — `hitTest` returns nil there so a mouse-down falls to whatever window sits behind
    /// the overlay, while a mouse-down on the VISIBLE surface (badge tap, list rows, the "Show
    /// all history" link) still resolves to a real view. Hover-to-expand and the Clawdy cursor
    /// are unaffected because `NSTrackingArea` enter/exit + `.cursorUpdate` are geometry-based
    /// and never route through `hitTest` (asserted separately above).
    @Test func badgeHaloMarginIsClickThroughWhileSurfaceStaysHittable() {
        let controller = ResearchRecentsBadgeController.offscreenForTesting()
        controller.recentRowsProvider = { [] }
        controller.liveDismissedSessionIDsProvider = { [] }
        controller.show()

        // RESTING: the visible square surface stays hittable; the surrounding aura is not.
        let restingSurface = controller.cursorRectForTesting
        #expect(restingSurface.width > 0 && restingSurface.height > 0)
        let restingHalo = CGPoint(x: restingSurface.minX - 5, y: restingSurface.minY - 5)
        #expect(restingSurface.contains(restingHalo) == false)
        #expect(controller.hitTestForTesting(restingHalo) == nil,
                "a click in the badge's transparent aura margin must fall through")
        let restingCenter = CGPoint(x: restingSurface.midX, y: restingSurface.midY)
        #expect(controller.hitTestForTesting(restingCenter) != nil,
                "a click on the visible badge must still hit the badge content")

        // LIST OPEN: the grown list surface is hittable (rows / links), its margin is not.
        controller.toggleListForTesting()
        #expect(controller.isListOpenForTesting == true)
        // The list-open window frame is normally interpolated (animated), which never settles
        // inside a synchronous offscreen test — so the content view would still carry the
        // resting size and a click at the grown list center would fall outside its bounds. The
        // tracking regions are already the FINAL grown rect immediately; settle the frame to the
        // matching final content size here so `hitTest` runs against the real grown surface.
        if let badgePanel = controller.badgePanelForTesting {
            badgePanel.setFrame(
                CGRect(origin: badgePanel.frame.origin, size: controller.targetWindowContentSizeForTesting),
                display: false
            )
        }
        let listSurface = controller.cursorRectForTesting
        let listHalo = CGPoint(x: listSurface.minX - 5, y: listSurface.minY - 5)
        #expect(listSurface.contains(listHalo) == false)
        #expect(controller.hitTestForTesting(listHalo) == nil,
                "a click in the open-list transparent margin must fall through")
        let listCenter = CGPoint(x: listSurface.midX, y: listSurface.midY)
        #expect(controller.hitTestForTesting(listCenter) != nil,
                "a click on the open list must still hit the list content")

        controller.hide()
    }
}

// MARK: - Manifest persistence of the dismissed flag

struct ResearchRecentsDismissPersistenceTests {

    @Test func recordSessionDismissedPersistsFlagAndReflectsInRows() {
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-dismiss-\(UUID().uuidString).json")
        let store = ResearchManifestStore(fileURL: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        store.recordResearchSessionStarted(
            sessionId: "sess-x", title: "X", task: "research x",
            workingDir: "/tmp/x", transcriptPath: "/tmp/x/sess-x.jsonl"
        )
        // Not dismissed yet.
        #expect(store.loadSessions().first?.dismissed != true)

        store.recordSessionDismissed(sessionId: "sess-x", dismissed: true)
        let entry = store.loadSessions().first
        #expect(entry?.dismissed == true)
        // Durable across a fresh store pointing at the same file (relaunch).
        let reopened = ResearchManifestStore(fileURL: manifestURL)
        #expect(reopened.loadSessions().first?.dismissed == true)

        // And the History row reflects it.
        let row = HistoryRowBuilder.makeRow(from: entry!, now: Date())
        #expect(row.isDismissed == true)
    }

    /// A missing session id is a safe no-op (never crashes, never creates an entry).
    @Test func recordSessionDismissedIsNoOpForUnknownSession() {
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-dismiss-noop-\(UUID().uuidString).json")
        let store = ResearchManifestStore(fileURL: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        store.recordSessionDismissed(sessionId: "nope", dismissed: true)
        #expect(store.loadSessions().isEmpty)
    }

    /// BACK-COMPAT: a manifest written BEFORE the `dismissed` field existed (its JSON
    /// has NO `dismissed` key at all) must still decode, reading as not-dismissed. The
    /// fixture is a hand-written literal that OMITS the key — proving the field is truly
    /// optional, not just a value the current encoder always writes.
    @Test func legacyManifestWithoutDismissedKeyDecodesAsNotDismissed() throws {
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        // NB: NO "dismissed" key anywhere — exactly what a pre-field manifest looks like.
        let legacyJSON = """
        {
          "version": 1,
          "sessions": [
            {
              "sessionId": "legacy-1",
              "kind": "research",
              "title": "Legacy run",
              "task": "research legacy",
              "status": "completed",
              "createdAt": "2023-11-14T22:13:20Z",
              "updatedAt": "2023-11-14T22:13:20Z",
              "workingDir": "/tmp/work/legacy-1",
              "transcriptPath": "/tmp/work/legacy-1/legacy-1.jsonl",
              "deliverablePath": "/tmp/work/legacy-1/report.html"
            }
          ]
        }
        """
        try legacyJSON.write(to: manifestURL, atomically: true, encoding: .utf8)

        // The real store decode path must accept the key-less entry.
        let store = ResearchManifestStore(fileURL: manifestURL)
        let sessions = store.loadSessions()
        #expect(sessions.count == 1)
        let entry = sessions.first
        #expect(entry?.sessionId == "legacy-1")
        // Absent key → nil → reads as not-dismissed.
        #expect(entry?.dismissed == nil)

        let row = HistoryRowBuilder.makeRow(from: entry!, now: Date())
        #expect(row.isDismissed == false)
    }

    /// Dismissing must NOT disturb ordering or timestamps: only the `dismissed` flag
    /// flips. Capture status + updatedAt + the recents/History row ORDER of several
    /// sessions BEFORE, then assert they are byte-for-byte identical AFTER (except the
    /// one flipped flag).
    @Test func dismissDoesNotReorderOrMutateStatusOrTimestamps() {
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recents-noreorder-\(UUID().uuidString).json")
        let store = ResearchManifestStore(fileURL: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Three sessions with distinct (whole-second) timestamps so ordering is stable
        // and iso8601 round-trips exactly.
        store.upsert(makeEntry(sessionId: "s1", kind: .research, title: "One", status: .completed,
                               createdAt: base, updatedAt: base.addingTimeInterval(10)))
        store.upsert(makeEntry(sessionId: "s2", kind: .research, title: "Two", status: .running,
                               createdAt: base.addingTimeInterval(20), updatedAt: base.addingTimeInterval(30)))
        store.upsert(makeEntry(sessionId: "s3", kind: .research, title: "Three", status: .completed,
                               createdAt: base.addingTimeInterval(40), updatedAt: base.addingTimeInterval(50)))

        let now = base.addingTimeInterval(1000)
        let orderBefore = HistoryRowBuilder.makeRows(from: store.loadSessions(), now: now).map(\.sessionId)
        let s2Before = store.loadSessions().first { $0.sessionId == "s2" }!
        #expect(s2Before.dismissed != true)

        // Dismiss the MIDDLE session.
        store.recordSessionDismissed(sessionId: "s2", dismissed: true)

        let s2After = store.loadSessions().first { $0.sessionId == "s2" }!
        // Status and BOTH timestamps unchanged — only `dismissed` flipped.
        #expect(s2After.status == s2Before.status)
        #expect(s2After.updatedAt == s2Before.updatedAt)
        #expect(s2After.createdAt == s2Before.createdAt)
        #expect(s2After.dismissed == true)

        // Row order is identical (dismiss never reorders the lists).
        let orderAfter = HistoryRowBuilder.makeRows(from: store.loadSessions(), now: now).map(\.sessionId)
        #expect(orderAfter == orderBefore)
        // The only visible row change is the dismissed treatment on s2.
        let rowsAfter = HistoryRowBuilder.makeRows(from: store.loadSessions(), now: now)
        #expect(rowsAfter.first { $0.sessionId == "s2" }?.isDismissed == true)
        #expect(rowsAfter.first { $0.sessionId == "s1" }?.isDismissed == false)
        #expect(rowsAfter.first { $0.sessionId == "s3" }?.isDismissed == false)
    }
}
