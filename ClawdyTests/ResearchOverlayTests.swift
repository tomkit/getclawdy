//
//  ResearchOverlayTests.swift
//  ClawdyTests
//
//  Tests for the GLOBAL research overlay introduced to fix the "research runs but
//  no visual overlay ever appears" bug. Two layers:
//
//   1. The PURE state machine (`ResearchOverlayState`): the idle → running →
//      needs-input → executing → done / error / stopped lifecycle, the detail
//      step-log accumulation, and the cancel (stop) transition. Value-in /
//      value-out, no UI.
//
//   2. A REAL-PATH presentation test (`ResearchProgressOverlayController`): drives
//      the actual AppKit controller and asserts the compact window is genuinely
//      presented with a NON-ZERO explicit frame (the exact failure of the old
//      cursor-following overlay, which collapsed to a 0×0 fitting-size frame and
//      was ordered on screen invisibly), at the right window level / collection
//      behavior, and — critically — with `sharingType = .readOnly` (visible to
//      external recorders; kept out of Clawdy's own model screenshots by app-level
//      exclusion, not sharingType). Also drives the click-to-detail, the stop
//      wiring, and the done → view-results affordance.
//

import Testing
import AppKit
@testable import Clawdy

// MARK: - Pure state machine

struct ResearchOverlayStateTests {

    @Test func startsIdleThenTransitionsToRunningOnStart() {
        var state = ResearchOverlayState()
        #expect(state.phase == .idle)
        #expect(state.isVisible == false)
        #expect(state.isCancellable == false)

        state.startRun(taskDescription: "compare standing desks under $1000")
        #expect(state.phase == .running)
        #expect(state.isVisible == true)
        #expect(state.taskDescription == "compare standing desks under $1000")
        #expect(state.statusLine == ResearchStatusLine.planning)
        #expect(state.isCancellable == true)
        // The log is seeded with the planning entry so the detail panel isn't empty.
        #expect(state.stepLog.count == 1)
        #expect(state.stepLog.first?.text == ResearchStatusLine.planning)
    }

    @Test func recordsProgressIntoStatusLineAndDetailLog() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "research desks")

        state.recordProgress(.searchingWeb(query: "best standing desks"))
        #expect(state.statusLine == "Searching the web for best standing desks…")

        state.recordProgress(.readingPage(url: "https://www.example.com/desks"))
        #expect(state.statusLine == "Reading example.com…")

        state.recordProgress(.writingPage)
        #expect(state.statusLine == "Writing the page…")

        // planning + 3 distinct steps, in order.
        #expect(state.stepLog.map(\.text) == [
            ResearchStatusLine.planning,
            "Searching the web for best standing desks…",
            "Reading example.com…",
            "Writing the page…",
        ])
        // Each entry has a unique, stable id.
        #expect(Set(state.stepLog.map(\.id)).count == state.stepLog.count)
    }

    @Test func collapsesConsecutiveIdenticalStepsInTheLog() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.recordProgress(.writingPage)
        state.recordProgress(.writingPage)
        state.recordProgress(.writingPage)
        // planning + a single "Writing the page…" (the repeats collapse).
        #expect(state.stepLog.map(\.text) == [ResearchStatusLine.planning, "Writing the page…"])
    }

    @Test func needsInputIsActionableAndStillCancellable() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.markNeedsInput()
        #expect(state.phase == .needsInput)
        #expect(state.statusLine == ResearchStatusLine.needsYourInput)
        #expect(state.isCancellable == true)
        #expect(state.compactTapOpensPrimaryAction == true)
    }

    @Test func resumeExecutingReturnsToRunningFromNeedsInput() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.markNeedsInput()
        state.resumeExecuting()
        #expect(state.phase == .running)
        #expect(state.isCancellable == true)
        #expect(state.compactTapOpensPrimaryAction == false)
        // The resume note is appended so the log tells the continuation story.
        #expect(state.stepLog.last?.text == "Continuing the research…")
    }

    @Test func completedIsActionableNotCancellableAndPersists() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.markCompleted()
        #expect(state.phase == .done)
        #expect(state.statusLine == ResearchStatusLine.viewResults)
        #expect(state.isCancellable == false)
        #expect(state.compactTapOpensPrimaryAction == true)
        // Done is NOT auto-hidden — the user must be able to open the results later.
        #expect(state.isAutoHidingTerminalState == false)
    }

    @Test func failedIsTerminalAndPersists() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.markFailed()
        #expect(state.phase == .error)
        #expect(state.statusLine == ResearchStatusLine.failed)
        #expect(state.isCancellable == false)
        // A FAILED run PERSISTS (it does NOT auto-hide) — it stays readable + dismissible.
        #expect(state.isAutoHidingTerminalState == false)
    }

    /// The cancel/stop transition: a running run moves to `.stopped`, stops being
    /// cancellable, and becomes an auto-hiding terminal state.
    @Test func stopTransitionsRunningToStopped() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        #expect(state.isCancellable == true)
        state.markStopped()
        #expect(state.phase == .stopped)
        #expect(state.statusLine == ResearchStatusLine.stopped)
        #expect(state.isCancellable == false)
        #expect(state.isAutoHidingTerminalState == true)
    }

    /// Late progress events that land after a terminal transition must NOT reopen
    /// the run or mutate the status line (mirrors the coordinator's late-event guard).
    @Test func progressAfterTerminalStateIsIgnored() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.markStopped()
        let logCountAtStop = state.stepLog.count
        state.recordProgress(.searchingWeb(query: "too late"))
        #expect(state.phase == .stopped)
        #expect(state.statusLine == ResearchStatusLine.stopped)
        #expect(state.stepLog.count == logCountAtStop)
    }

    @Test func resetReturnsToIdleBaseline() {
        var state = ResearchOverlayState()
        state.startRun(taskDescription: "x")
        state.recordProgress(.writingPage)
        state.reset()
        #expect(state == ResearchOverlayState())
        #expect(state.phase == .idle)
        #expect(state.stepLog.isEmpty)
    }
}

// MARK: - Pure stacked-overlay layout (collapse beyond 3)

struct ResearchOverlayStackLayoutTests {

    /// Up to `maximumVisiblePills` (3) sessions: everything is visible, NO control row.
    @Test func showsEveryPillWhenAtOrBelowTheVisibleCap() {
        let one = ResearchOverlayStackLayout.plan(orderedSessionIDs: ["a"], isExpanded: false)
        #expect(one == ResearchOverlayStackLayout.Plan(visibleSessionIDs: ["a"], controlRow: nil))

        let three = ResearchOverlayStackLayout.plan(orderedSessionIDs: ["a", "b", "c"], isExpanded: false)
        #expect(three == ResearchOverlayStackLayout.Plan(visibleSessionIDs: ["a", "b", "c"], controlRow: nil))
    }

    /// More than 3 sessions, collapsed: only the first 3 show and the rest fold into a
    /// "+N more" control row.
    @Test func collapsesBeyondThreeIntoAShowMoreRow() {
        let plan = ResearchOverlayStackLayout.plan(
            orderedSessionIDs: ["a", "b", "c", "d", "e"],
            isExpanded: false
        )
        #expect(plan.visibleSessionIDs == ["a", "b", "c"])
        #expect(plan.controlRow == .showMore(hiddenCount: 2))
        #expect(plan.hiddenCount == 2)
    }

    /// BLOCKING 1 regression: more than 3 sessions, EXPANDED — every pill shows AND a
    /// reachable "show less" control row is emitted (previously the expanded state had
    /// `hiddenCount: 0` and no row, so the collapse control was unreachable).
    @Test func expandedShowsEveryPillWithAReachableShowLessControl() {
        let plan = ResearchOverlayStackLayout.plan(
            orderedSessionIDs: ["a", "b", "c", "d", "e"],
            isExpanded: true
        )
        #expect(plan.visibleSessionIDs == ["a", "b", "c", "d", "e"])
        #expect(plan.controlRow == .showLess, "expanded state must still emit a reachable collapse control")
        // hiddenCount stays 0 in the expanded state — the row exists via the descriptor,
        // NOT via a positive overflow count.
        #expect(plan.hiddenCount == 0)
    }

    /// BLOCKING 1 boundary, BOTH directions across the 3↔4 edge: collapsing an expanded
    /// 4-session stack returns to the first-3 + "+1 more" view; a 3-session stack has no
    /// control row regardless of the expand flag (nothing to collapse).
    @Test func toggleAcrossTheThreeToFourBoundaryInBothDirections() {
        // 4 sessions, expanded → reachable "show less".
        let fourExpanded = ResearchOverlayStackLayout.plan(
            orderedSessionIDs: ["a", "b", "c", "d"], isExpanded: true
        )
        #expect(fourExpanded.visibleSessionIDs == ["a", "b", "c", "d"])
        #expect(fourExpanded.controlRow == .showLess)

        // Toggling back (collapsed) → first 3 + "+1 more".
        let fourCollapsed = ResearchOverlayStackLayout.plan(
            orderedSessionIDs: ["a", "b", "c", "d"], isExpanded: false
        )
        #expect(fourCollapsed.visibleSessionIDs == ["a", "b", "c"])
        #expect(fourCollapsed.controlRow == .showMore(hiddenCount: 1))

        // Exactly 3 sessions: no control row in EITHER state (nothing overflows).
        let threeCollapsed = ResearchOverlayStackLayout.plan(orderedSessionIDs: ["a", "b", "c"], isExpanded: false)
        let threeExpanded = ResearchOverlayStackLayout.plan(orderedSessionIDs: ["a", "b", "c"], isExpanded: true)
        #expect(threeCollapsed.controlRow == nil)
        #expect(threeExpanded.controlRow == nil)
    }

    @Test func emptyStackIsEmptyWithNoControlRow() {
        let plan = ResearchOverlayStackLayout.plan(orderedSessionIDs: [], isExpanded: false)
        #expect(plan.visibleSessionIDs.isEmpty)
        #expect(plan.controlRow == nil)
    }
}

// MARK: - Real-path presentation (AppKit)

@MainActor
struct ResearchStackedOverlayControllerTests {

    /// Builds a pill view model in a given phase for feeding the stacked controller.
    private func makePillViewModel(
        id: ResearchSessionID,
        phase: ResearchOverlayPhase,
        isFocused: Bool = false
    ) -> ResearchStackPillModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = phase
        viewModel.taskDescription = "research \(id)"
        viewModel.statusLine = "Planning the research…"
        viewModel.isCancellable = (phase == .running || phase == .needsInput)
        return ResearchStackPillModel(id: id, viewModel: viewModel, isFocused: isFocused)
    }

    /// THE core regression, preserved for each toast: rendering one pill must put a
    /// genuinely visible window on screen — a NON-ZERO explicit frame at the right
    /// level / collection behavior, excluded from screenshots. (The old overlay
    /// collapsed to 0×0 and was invisible; each toast panel is explicitly sized.)
    @Test func renderingOnePillShowsAVisibleNonZeroScreenshotExcludedWindow() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(
            pills: [makePillViewModel(id: "a", phase: .running)],
            controlRow: nil,
            detailViewModel: nil
        )
        defer { controller.hide() }

        let toast = controller.toastPanelForTesting(id: "a")
        #expect(toast != nil)
        guard let toast else { return }

        // Genuinely on screen and NOT zero-sized (the exact old-overlay failure).
        #expect(toast.isVisible == true)
        #expect(toast.frame.width > 0)
        #expect(toast.frame.height > 0)

        // Global overlay window contract.
        #expect(toast.level == .statusBar)
        #expect(toast.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(toast.collectionBehavior.contains(.fullScreenAuxiliary))
        // Must receive clicks (Stop / tap-to-focus), so NOT click-through.
        #expect(toast.ignoresMouseEvents == false)
        // Visible to external recorders (.readOnly). It is kept out of Clawdy's OWN
        // model screenshots by app-level exclusion in CompanionScreenCaptureUtility,
        // not by sharingType.
        #expect(toast.sharingType == .readOnly)

        #expect(controller.renderedPillCountForTesting == 1)
        #expect(controller.toastPanelCountForTesting == 1)
    }

    /// Multiple sessions render one INDEPENDENT window per toast plus a "+N more" control
    /// window, each visible + non-zero + screenshot-excluded.
    @Test func renderingMultiplePillsWithOverflowKeepsTheWindowContract() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(
            pills: [
                makePillViewModel(id: "a", phase: .running),
                makePillViewModel(id: "b", phase: .running),
                makePillViewModel(id: "c", phase: .running),
            ],
            controlRow: .showMore(hiddenCount: 2),
            detailViewModel: nil
        )
        defer { controller.hide() }

        #expect(controller.renderedPillCountForTesting == 3)
        #expect(controller.renderedHiddenCountForTesting == 2)
        #expect(controller.renderedControlRowForTesting == .showMore(hiddenCount: 2))
        // One window per visible toast.
        #expect(controller.toastPanelCountForTesting == 3)
        for id in ["a", "b", "c"] {
            guard let toast = controller.toastPanelForTesting(id: id) else {
                Issue.record("toast \(id) should exist"); continue
            }
            #expect(toast.isVisible == true)
            #expect(toast.frame.width > 0 && toast.frame.height > 0)
            #expect(toast.sharingType == .readOnly)
        }
        // The "+N more" control is its own visible, non-zero window, `.readOnly`
        // (visible to recorders; kept out of the model screenshot by app-exclusion).
        let control = controller.controlPanelForTesting
        #expect(control?.isVisible == true)
        #expect((control?.frame.width ?? 0) > 0 && (control?.frame.height ?? 0) > 0)
        #expect(control?.sharingType == .readOnly)
    }

    /// BLOCKING 1 presentation: an EXPANDED stack still renders a control window (the
    /// "show less" affordance), so the collapse control is reachable on screen — not
    /// silently dropped as it was when the row was keyed on `hiddenCount > 0`.
    @Test func expandedStackStillRendersAReachableShowLessControlRow() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(
            pills: (1...4).map { makePillViewModel(id: "e\($0)", phase: .running) },
            controlRow: .showLess,
            detailViewModel: nil
        )
        defer { controller.hide() }

        #expect(controller.renderedPillCountForTesting == 4)
        #expect(controller.renderedControlRowForTesting == .showLess,
                "expanded stack must render a reachable collapse control")
        #expect(controller.renderedHiddenCountForTesting == 0)
        // The show-less control is a real, visible, non-zero window (not omitted).
        let control = controller.controlPanelForTesting
        #expect(control?.isVisible == true)
        #expect((control?.frame.width ?? 0) > 0 && (control?.frame.height ?? 0) > 0)
    }

    /// Rendering with a focused session's detail view model shows a non-zero,
    /// screenshot-excluded detail panel beside the stack (the read-only transcript).
    @Test func renderingWithFocusShowsANonZeroScreenshotExcludedDetailPanel() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        let focusedPill = makePillViewModel(id: "a", phase: .running, isFocused: true)
        controller.render(
            pills: [focusedPill],
            controlRow: nil,
            detailViewModel: focusedPill.viewModel
        )
        defer { controller.hide() }

        let detail = controller.detailPanelForTesting
        #expect(detail != nil)
        guard let detail else { return }
        #expect(detail.isVisible == true)
        #expect(detail.frame.width > 0)
        #expect(detail.frame.height > 0)
        #expect(detail.sharingType == .readOnly)
    }

    /// Clearing focus (detailViewModel nil) hides the detail panel while the stack
    /// stays up.
    @Test func renderingWithoutFocusHidesTheDetailPanel() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        let pill = makePillViewModel(id: "a", phase: .running, isFocused: true)
        controller.render(pills: [pill], controlRow: nil, detailViewModel: pill.viewModel)
        #expect(controller.detailPanelForTesting?.isVisible == true)

        let unfocused = ResearchStackPillModel(id: "a", viewModel: pill.viewModel, isFocused: false)
        controller.render(pills: [unfocused], controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        #expect(controller.detailPanelForTesting?.isVisible == false)
        #expect(controller.toastPanelForTesting(id: "a")?.isVisible == true)
    }

    /// An empty render (no active sessions) tears down every toast window.
    @Test func renderingNoPillsHidesTheStack() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: [makePillViewModel(id: "a", phase: .running)], controlRow: nil, detailViewModel: nil)
        #expect(controller.toastPanelForTesting(id: "a")?.isVisible == true)
        #expect(controller.toastPanelCountForTesting == 1)

        controller.render(pills: [], controlRow: nil, detailViewModel: nil)
        #expect(controller.toastPanelCountForTesting == 0)
    }

    /// CLICK-THROUGH HALO: the transparent Clawdy-aura margin around a toast must NOT swallow
    /// clicks — `hitTest` returns nil there so a mouse-down falls to whatever window sits
    /// behind the overlay. A mouse-down anywhere on the VISIBLE pill (the tracking rect) still
    /// resolves to a real view, so tap-to-open and the Stop / × / view-results controls keep
    /// working. Hover-to-expand is unaffected because `NSTrackingArea` enter/exit is geometry-
    /// based and never routes through `hitTest` (asserted separately by the tracking-rect tests).
    @Test func toastHaloMarginIsClickThroughWhilePillStaysHittable() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(
            pills: [makePillViewModel(id: "a", phase: .running)],
            controlRow: nil,
            detailViewModel: nil
        )
        defer { controller.hide() }

        guard let toast = controller.toastPanelObjectForTesting(id: "a") else {
            Issue.record("toast should exist"); return
        }
        let pillRect = toast.trackingRectForTesting
        #expect(pillRect.width > 0 && pillRect.height > 0)

        // A point in the transparent aura margin (outside the visible pill) is click-through.
        let haloPoint = CGPoint(x: pillRect.minX - 5, y: pillRect.minY - 5)
        #expect(pillRect.contains(haloPoint) == false)
        #expect(toast.hitTestForTesting(haloPoint) == nil,
                "a click in the transparent aura margin must fall through to the window behind")

        // A point on the visible pill still resolves to a real view (controls stay clickable).
        let pillCenter = CGPoint(x: pillRect.midX, y: pillRect.midY)
        #expect(toast.hitTestForTesting(pillCenter) != nil,
                "a click on the visible pill must still hit the toast content")
    }
}
