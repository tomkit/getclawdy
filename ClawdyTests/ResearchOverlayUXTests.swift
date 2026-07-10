//
//  ResearchOverlayUXTests.swift
//  ClawdyTests
//
//  The research-overlay UX pass. Covers the PURE logic behind the overlay, plus real-path
//  AppKit checks of the per-toast-window overlay:
//   - `ResearchMiniProgressState`: the phase → progress-ring state mapping (folded into the
//     full toast's leading progress ring; the mini badge that once carried it is retired).
//   - `ResearchStepIndicator`: the event/phase → (icon, word) STEP mapping the full toast's
//     status row shows.
//   - `ResearchToastClickAction`: the state → single-click-action mapping.
//   - `ResearchOverlayAnchor`: the top-left (banner-avoiding) vs top-right anchor origin.
//   - `ResearchFullToastLayout`: every active toast window is the ONE full footprint
//     (non-zero); the fanned list stride spaces them without overlap; a slot's origin
//     depends only on its index (independence).
//   - `ResearchStackFanLayout`: the >= 3 native-stacking threshold, the stacked ⇄ fanned
//     presentation, the collapse-control visibility, and the stacked card recede.
//   - `ResearchToastWindowHoverTests`: real per-toast window — one fixed full footprint,
//     hovering a 3+ cluster fans it out and leaving re-stacks (the collapse control too),
//     a < 3 cluster never stacks, and teardown / removal close windows cleanly (no leaks).
//

import Testing
import AppKit
@testable import Clawdy

// MARK: - Progress-ring state mapping (folded into the full toast)

/// The PURE phase → progress-ring state mapping. The actual ring appearance/animation
/// needs a live eyeball (SwiftUI rendering); these only pin the state machine: which phase
/// yields which indicator, and that Reduce Motion swaps the working state for a
/// non-animated variant.
struct ResearchMiniProgressStateTests {

    /// While RUNNING with motion allowed, the ring shows the animated (spinning) arc.
    @Test func runningWithMotionIsAnimatedWorking() {
        let state = ResearchMiniProgressState.forPhase(.running, reduceMotion: false)
        #expect(state == .workingAnimated)
        #expect(state.isAnimated)
    }

    /// Reduce Motion swaps the SAME working phase to the static (non-spinning) variant.
    @Test func runningWithReduceMotionIsStaticWorking() {
        let state = ResearchMiniProgressState.forPhase(.running, reduceMotion: true)
        #expect(state == .workingStatic)
        #expect(!state.isAnimated)
    }

    /// NEEDS-INPUT is a distinct, steady (never animated) "your turn" state — regardless
    /// of the Reduce Motion setting, since it never spins.
    @Test func needsInputIsSteadyAndNeverAnimated() {
        #expect(ResearchMiniProgressState.forPhase(.needsInput, reduceMotion: false) == .needsInput)
        #expect(ResearchMiniProgressState.forPhase(.needsInput, reduceMotion: true) == .needsInput)
        #expect(!ResearchMiniProgressState.forPhase(.needsInput, reduceMotion: false).isAnimated)
    }

    /// DONE shows the calm complete indicator; it never animates.
    @Test func doneIsCalmCompleteNeverAnimated() {
        let state = ResearchMiniProgressState.forPhase(.done, reduceMotion: false)
        #expect(state == .done)
        #expect(!state.isAnimated)
    }

    /// Terminal error/stopped and idle show NO progress indicator.
    @Test func terminalAndIdlePhasesShowNoIndicator() {
        #expect(ResearchMiniProgressState.forPhase(.error, reduceMotion: false) == .none)
        #expect(ResearchMiniProgressState.forPhase(.stopped, reduceMotion: false) == .none)
        #expect(ResearchMiniProgressState.forPhase(.idle, reduceMotion: false) == .none)
    }

    /// The KEY contract the view's spin binding must honor: motion is active for a
    /// phase+ReduceMotion combination IFF `forPhase(...).isAnimated` is true — i.e. ONLY
    /// `running` with motion allowed.
    @Test func forPhaseDrivesWhetherMotionIsActive() {
        #expect(ResearchMiniProgressState.forPhase(.running, reduceMotion: false).isAnimated)
        #expect(!ResearchMiniProgressState.forPhase(.running, reduceMotion: true).isAnimated)
        #expect(!ResearchMiniProgressState.forPhase(.needsInput, reduceMotion: false).isAnimated)
        #expect(!ResearchMiniProgressState.forPhase(.done, reduceMotion: false).isAnimated)
        #expect(!ResearchMiniProgressState.forPhase(.error, reduceMotion: false).isAnimated)
        #expect(!ResearchMiniProgressState.forPhase(.idle, reduceMotion: false).isAnimated)
    }

    /// A direct enum sanity check that `isAnimated` is true for exactly one case.
    @Test func onlyAnimatedWorkingStateIsAnimated() {
        #expect(ResearchMiniProgressState.workingAnimated.isAnimated)
        #expect(!ResearchMiniProgressState.workingStatic.isAnimated)
        #expect(!ResearchMiniProgressState.needsInput.isAnimated)
        #expect(!ResearchMiniProgressState.done.isAnimated)
        #expect(!ResearchMiniProgressState.none.isAnimated)
    }
}

// MARK: - Step vocabulary (shown in the full toast's status row)

/// The PURE event/phase → (icon, word) STEP mapping the full toast's status row shows so a
/// run can be followed at a glance.
struct ResearchStepIndicatorSignalTests {

    @Test func stepForEventMapsEachEventToItsIconAndWord() {
        #expect(ResearchStepIndicator.forEvent(.searchingWeb(query: "aomori")) ==
                ResearchStepIndicator(icon: "magnifyingglass", word: "Search"))
        #expect(ResearchStepIndicator.forEvent(.readingPage(url: "https://example.com")) ==
                ResearchStepIndicator(icon: "doc.text", word: "Read"))
        #expect(ResearchStepIndicator.forEvent(.writingPage) ==
                ResearchStepIndicator(icon: "pencil", word: "Write"))
        #expect(ResearchStepIndicator.forEvent(.runningTool(name: "Bash")) ==
                ResearchStepIndicator(icon: "gearshape", word: "Working"))
    }

    @Test func stepForPhaseCoversDoneAndNeedsInputOnly() {
        #expect(ResearchStepIndicator.forPhase(.done) ==
                ResearchStepIndicator(icon: "checkmark", word: "Done"))
        #expect(ResearchStepIndicator.forPhase(.needsInput) ==
                ResearchStepIndicator(icon: "questionmark", word: "Ask"))
        #expect(ResearchStepIndicator.forPhase(.running) == nil)
        #expect(ResearchStepIndicator.forPhase(.error) == nil)
        #expect(ResearchStepIndicator.forPhase(.stopped) == nil)
        #expect(ResearchStepIndicator.forPhase(.idle) == nil)
    }

    @Test func currentStepPrefersPhaseThenInfersRunningToolFromStatusLine() {
        #expect(ResearchStepIndicator.current(phase: .done, statusLine: "View results ›") ==
                ResearchStepIndicator(icon: "checkmark", word: "Done"))
        #expect(ResearchStepIndicator.current(phase: .needsInput, statusLine: "I need a quick answer — click to reply") ==
                ResearchStepIndicator(icon: "questionmark", word: "Ask"))
        #expect(ResearchStepIndicator.current(phase: .running, statusLine: "Searching the web for aomori…") ==
                ResearchStepIndicator(icon: "magnifyingglass", word: "Search"))
        #expect(ResearchStepIndicator.current(phase: .running, statusLine: "Reading example.com…") ==
                ResearchStepIndicator(icon: "doc.text", word: "Read"))
        #expect(ResearchStepIndicator.current(phase: .running, statusLine: "Writing the page…") ==
                ResearchStepIndicator(icon: "pencil", word: "Write"))
        #expect(ResearchStepIndicator.current(phase: .running, statusLine: "Planning the research…") ==
                ResearchStepIndicator(icon: "gearshape", word: "Working"))
        #expect(ResearchStepIndicator.current(phase: .error, statusLine: "Research failed") == nil)
        #expect(ResearchStepIndicator.current(phase: .idle, statusLine: "") == nil)
    }
}

// MARK: - Click-action mapping (double-open fix)

struct ResearchToastClickActionTests {

    @Test func doneClickOpensHistoryOnly() {
        // DONE default click now opens History (the live results page is reached via the
        // dedicated "view results" button), and never the detail panel.
        #expect(ResearchToastClickAction.action(forPhase: .done, isFocused: false) == .openHistory)
        #expect(ResearchToastClickAction.action(forPhase: .done, isFocused: true) == .openHistory)
    }

    @Test func workingClickTogglesTheDetailViewNeverHistory() {
        #expect(ResearchToastClickAction.action(forPhase: .running, isFocused: false) == .showDetail)
        #expect(ResearchToastClickAction.action(forPhase: .running, isFocused: true) == .hideDetail)
        #expect(ResearchToastClickAction.action(forPhase: .idle, isFocused: false) == .showDetail)
        #expect(ResearchToastClickAction.action(forPhase: .running, isFocused: false) != .openHistory)
        #expect(ResearchToastClickAction.action(forPhase: .running, isFocused: true) != .openHistory)
    }

    @Test func needsInputOpensClarifyErrorTogglesDetailStoppedClearsFocus() {
        #expect(ResearchToastClickAction.action(forPhase: .needsInput, isFocused: false) == .openClarify)
        // A FAILED (.error) run is persistent + actionable: a tap toggles its detail panel
        // so the failure is readable in place — NOT a bare clear-focus.
        #expect(ResearchToastClickAction.action(forPhase: .error, isFocused: false) == .showDetail)
        #expect(ResearchToastClickAction.action(forPhase: .error, isFocused: true) == .hideDetail)
        // A stopped pill (about to auto-hide) just clears focus.
        #expect(ResearchToastClickAction.action(forPhase: .stopped, isFocused: false) == .clearFocus)
    }

    @Test func onlyDoneMapsToOpenHistory() {
        // ONLY the done phase maps to open-History (its default card click). The results
        // page is no longer a toast-click destination at all — it is reached via a
        // dedicated button, so the toast-click enum has no `openResults` case.
        let phases: [ResearchOverlayPhase] = [.idle, .running, .needsInput, .done, .error, .stopped]
        for phase in phases {
            for focused in [true, false] {
                let action = ResearchToastClickAction.action(forPhase: phase, isFocused: focused)
                if phase == .done {
                    #expect(action == .openHistory)
                } else {
                    #expect(action != .openHistory)
                }
            }
        }
    }
}

// MARK: - On-screen anchor (banner-avoiding placement)

struct ResearchOverlayAnchorTests {

    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 340, height: 200)
    private let inset: CGFloat = 16

    @Test func topLeftAnchorSitsAtTheLeftEdge() {
        let origin = ResearchOverlayAnchor.stackOrigin(
            corner: .topLeft, visibleFrame: visibleFrame, size: size, inset: inset
        )
        #expect(origin.x == visibleFrame.minX + inset)
        #expect(origin.y == visibleFrame.maxY - size.height - inset)
    }

    @Test func topRightAnchorSitsAtTheRightEdge() {
        let origin = ResearchOverlayAnchor.stackOrigin(
            corner: .topRight, visibleFrame: visibleFrame, size: size, inset: inset
        )
        #expect(origin.x == visibleFrame.maxX - size.width - inset)
        #expect(origin.y == visibleFrame.maxY - size.height - inset)
    }

    @Test func topLeftIsToTheLeftOfTopRightAtTheSameHeight() {
        let left = ResearchOverlayAnchor.stackOrigin(corner: .topLeft, visibleFrame: visibleFrame, size: size, inset: inset)
        let right = ResearchOverlayAnchor.stackOrigin(corner: .topRight, visibleFrame: visibleFrame, size: size, inset: inset)
        #expect(left.x < right.x)
        #expect(left.y == right.y)
    }
}

// MARK: - Full-toast window layout (one fixed footprint, fanned-list stride)

struct ResearchFullToastLayoutTests {

    /// Every active toast window is the ONE full footprint (+ margin) — non-zero, and the
    /// full pill footprint (the retired mini badge's smaller resting size is gone).
    @Test func fullToastWindowIsTheFullFootprintAndNonZero() {
        let window = ResearchToastLayout.expandedWindowContentSize
        #expect(window.width > 0 && window.height > 0)
        #expect(window.width >= ResearchStackFrameLayout.expandedPillSize.width)
        #expect(window.height >= ResearchStackFrameLayout.expandedPillSize.height)
    }

    /// The FANNED-list stride is based on the FULL toast footprint (not the retired mini
    /// badge) so full pills sit clear of each other by exactly the inter-toast gap.
    @Test func fannedListStrideIsFullToastBasedWithAGap() {
        let expected = ResearchStackFrameLayout.expandedPillSize.height + ResearchStackFrameLayout.pillSpacing
        #expect(ResearchToastLayout.fullToastSlotStride == expected)
        // Genuinely leaves an inter-toast gap: stride exceeds the pill height.
        #expect(ResearchToastLayout.fullToastSlotStride > ResearchStackFrameLayout.expandedPillSize.height)
    }

    /// A fanned slot's on-screen origin depends ONLY on its index (and the screen) —
    /// independence. Consecutive slots step down by exactly the full-toast stride; the
    /// horizontal position is identical across slots.
    @Test func fannedSlotOriginDependsOnlyOnIndex() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let stride = ResearchToastLayout.fullToastSlotStride
        let slot0 = ResearchToastLayout.slotTopLeftOrigin(index: 0, corner: .topLeft, visibleFrame: visibleFrame, edgeInset: 16, stride: stride)
        let slot1 = ResearchToastLayout.slotTopLeftOrigin(index: 1, corner: .topLeft, visibleFrame: visibleFrame, edgeInset: 16, stride: stride)
        let slot2 = ResearchToastLayout.slotTopLeftOrigin(index: 2, corner: .topLeft, visibleFrame: visibleFrame, edgeInset: 16, stride: stride)
        #expect(slot0.x == slot1.x)
        #expect(slot1.x == slot2.x)
        #expect(slot0.y - slot1.y == stride)
        #expect(slot1.y - slot2.y == stride)
    }
}

// MARK: - Native stacking / fan-out (pure)

struct ResearchStackFanLayoutTests {

    /// The stacking threshold is exactly 3: fewer than 3 active toasts render as a plain
    /// list (no stacking); 3 or more are stackable.
    @Test func stackingThresholdIsThree() {
        #expect(ResearchStackFanLayout.stackingThreshold == 3)
        #expect(ResearchStackFanLayout.isStackable(toastCount: 0) == false)
        #expect(ResearchStackFanLayout.isStackable(toastCount: 1) == false)
        #expect(ResearchStackFanLayout.isStackable(toastCount: 2) == false)
        #expect(ResearchStackFanLayout.isStackable(toastCount: 3) == true)
        #expect(ResearchStackFanLayout.isStackable(toastCount: 5) == true)
    }

    /// Presentation: under the threshold it's always `.list` (fan state is irrelevant); at
    /// or above it, `.fanned` while fanned out else `.stacked`.
    @Test func presentationMapsCountAndFanStateToTheThreeForms() {
        // Below threshold → always a plain list.
        #expect(ResearchStackFanLayout.presentation(toastCount: 1, isFannedOut: false) == .list)
        #expect(ResearchStackFanLayout.presentation(toastCount: 2, isFannedOut: true) == .list)
        // At/above threshold, at rest → stacked; hovered → fanned.
        #expect(ResearchStackFanLayout.presentation(toastCount: 3, isFannedOut: false) == .stacked)
        #expect(ResearchStackFanLayout.presentation(toastCount: 3, isFannedOut: true) == .fanned)
        #expect(ResearchStackFanLayout.presentation(toastCount: 6, isFannedOut: false) == .stacked)
        #expect(ResearchStackFanLayout.presentation(toastCount: 6, isFannedOut: true) == .fanned)
    }

    /// The stacked ⇄ fanned transition: a stackable cluster fans out while hovered and
    /// collapses back when the hover ends; a non-stackable cluster is never fanned.
    @Test func nextFannedStateFollowsHoverOnlyWhenStackable() {
        // Stackable: fans out on hover, collapses off hover.
        #expect(ResearchStackFanLayout.nextFannedState(toastCount: 3, isHovered: true, currentlyFanned: false) == true)
        #expect(ResearchStackFanLayout.nextFannedState(toastCount: 3, isHovered: false, currentlyFanned: true) == false)
        // Not stackable: always collapsed (a plain list), regardless of hover.
        #expect(ResearchStackFanLayout.nextFannedState(toastCount: 2, isHovered: true, currentlyFanned: true) == false)
        #expect(ResearchStackFanLayout.nextFannedState(toastCount: 1, isHovered: true, currentlyFanned: false) == false)
    }

    /// The collapse-to-stack control shows ONLY while a stackable cluster is fanned out.
    @Test func collapseControlShowsOnlyWhenStackableAndFanned() {
        #expect(ResearchStackFanLayout.showsCollapseControl(toastCount: 3, isFannedOut: true) == true)
        #expect(ResearchStackFanLayout.showsCollapseControl(toastCount: 3, isFannedOut: false) == false)
        #expect(ResearchStackFanLayout.showsCollapseControl(toastCount: 2, isFannedOut: true) == false)
    }

    /// The stacked card transform recedes monotonically with depth: the front card (depth
    /// 0) is fully opaque / frontmost, and each card behind is offset further down and
    /// dimmer, up to the clamp. NATIVE-NOTIFICATION STACKING: every card — front and back —
    /// is the SAME WIDTH (`scale == 1.0`); back cards are never scaled down, only offset
    /// and dimmed (like macOS Notification Center's stacked notifications).
    @Test func stackedCardTransformRecedesWithDepthButKeepsFullWidth() {
        let front = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 0)
        #expect(front.peekOffset == 0)
        #expect(front.scale == 1.0)
        #expect(front.opacity == 1.0)

        let second = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 1)
        let third = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 2)
        // Strictly further down, dimmer, and further back with depth …
        #expect(second.peekOffset > front.peekOffset)
        #expect(third.peekOffset > second.peekOffset)
        #expect(second.opacity < front.opacity)
        #expect(third.opacity < second.opacity)
        #expect(front.zPosition > second.zPosition)
        #expect(second.zPosition > third.zPosition)
        // … but ALL cards keep the front card's FULL WIDTH — never scaled down.
        #expect(second.scale == 1.0, "back cards match the front card's width (native stacking)")
        #expect(third.scale == 1.0, "back cards match the front card's width (native stacking)")

        // Depth clamps so a deep stack doesn't fade to nothing.
        let clamped = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 9)
        let atClamp = ResearchStackFanLayout.stackedCardTransform(depthFromFront: ResearchStackFanLayout.maximumStackedCards - 1)
        #expect(clamped.scale == atClamp.scale)
        #expect(clamped.opacity == atClamp.opacity)
    }
}

// MARK: - Clawdy blue toast-hover cursor

struct ResearchToastCursorTests {

    @Test func clawdyToastCursorIsANonZeroImageCursor() {
        let cursor = ResearchToastCursor.clawdy
        #expect(cursor.image.size.width > 0)
        #expect(cursor.image.size.height > 0)
    }
}

// MARK: - Real-path per-toast window + native stacking fan-out

@MainActor
struct ResearchToastWindowHoverTests {

    private func makePill(id: ResearchSessionID) -> ResearchStackPillModel {
        let viewModel = ResearchProgressOverlayViewModel()
        viewModel.phase = .running
        viewModel.taskDescription = "research \(id)"
        viewModel.statusLine = "Planning the research…"
        viewModel.isCancellable = true
        return ResearchStackPillModel(id: id, viewModel: viewModel, isFocused: false)
    }

    private func makePills(_ ids: [ResearchSessionID]) -> [ResearchStackPillModel] {
        ids.map(makePill)
    }

    /// Every active toast window is the SINGLE full footprint (the retired mini/expand grow
    /// is gone), its hover hit region is the full pill rect, and the window is fully
    /// transparent + screenshot-excluded (no opaque rectangle / alpha halo, `.none`).
    @Test func toastWindowIsTheFullFootprintTransparentAndScreenshotExcluded() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: [makePill(id: "a")], controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        let expectedWindow = ResearchToastLayout.expandedWindowContentSize
        let panel = controller.toastPanelForTesting(id: "a")
        #expect(panel?.frame.size == expectedWindow, "the toast window is the one full footprint")
        #expect(controller.installedToastTrackingRectForTesting(id: "a")?.size == ResearchStackFrameLayout.expandedPillSize,
                "the OS-installed hover hit region is the full pill rect")

        #expect(panel?.isOpaque == false, "the toast window is non-opaque")
        #expect(panel?.backgroundColor == NSColor.clear, "the toast window background is fully clear")
        #expect(panel?.hasShadow == false, "the toast window draws no shadow (the aura is the SwiftUI glow, not a window shadow)")
        #expect(panel?.sharingType == NSWindow.SharingType.none, "the toast window stays excluded from screenshots")
    }

    /// FEWER than 3 active toasts never stack — the cluster is a plain list, and hovering a
    /// toast does not fan anything out (there's nothing stacked to fan).
    @Test func fewerThanThreeToastsNeverStack() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        #expect(controller.presentationForTesting == .list)
        #expect(controller.isFannedOutForTesting == false)
        #expect(controller.collapseControlPanelForTesting?.isVisible != true, "no collapse control in list mode")

        // Hovering a toast in list mode doesn't fan (stays a list, no fan state).
        controller.setToastHoverForTesting(id: "a", hovering: true)
        #expect(controller.presentationForTesting == .list)
        #expect(controller.isFannedOutForTesting == false)
    }

    /// 3+ toasts collapse into the native STACK at rest: the front card is full size, the
    /// cards behind recede (smaller + dimmer). Hovering the stack FANS it out — all cards
    /// return to full size and a collapse control appears. Leaving the cluster re-stacks.
    @Test func threePlusToastsStackAtRestFanOutOnHoverAndRestackOnLeave() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b", "c"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        // AT REST: stacked. Front (a) is full; the deepest (c) is dimmed but the SAME WIDTH.
        #expect(controller.presentationForTesting == .stacked)
        #expect(controller.isFannedOutForTesting == false)
        #expect(controller.toastStackScaleForTesting(id: "a") == 1.0, "front card is full size")
        #expect(controller.toastStackScaleForTesting(id: "c") == 1.0, "the back card matches the front's width (native stacking)")
        #expect((controller.toastStackOpacityForTesting(id: "c") ?? 1) < 1.0, "the back card is dimmed")
        // No collapse control while stacked.
        #expect(controller.collapseControlPanelForTesting?.isVisible != true)

        // HOVER any toast → FAN OUT: all cards return to full size + the collapse control shows.
        controller.setToastHoverForTesting(id: "a", hovering: true)
        #expect(controller.presentationForTesting == .fanned)
        #expect(controller.isFannedOutForTesting == true)
        #expect(controller.toastStackScaleForTesting(id: "c") == 1.0, "fanned cards are full size")
        #expect(controller.toastStackOpacityForTesting(id: "c") == 1.0, "fanned cards are fully opaque")
        #expect(controller.collapseControlPanelForTesting?.isVisible == true, "the collapse-to-stack control is offered while fanned")

        // LEAVE the cluster → after the debounce it re-stacks.
        controller.setToastHoverForTesting(id: "a", hovering: false)
        controller.flushPendingFanCollapseForTesting()
        #expect(controller.presentationForTesting == .stacked)
        #expect(controller.isFannedOutForTesting == false)
        #expect((controller.toastStackOpacityForTesting(id: "c") ?? 1) < 1.0, "re-stacked: the back card recedes (dims) again")
        #expect(controller.toastStackScaleForTesting(id: "c") == 1.0, "re-stacked: the back card is still full width")
        #expect(controller.collapseControlPanelForTesting?.isVisible != true, "collapse control hidden again once stacked")
    }

    /// The collapse-to-stack CONTROL re-stacks a fanned cluster immediately (the "return to
    /// stacked" affordance requirement).
    @Test func collapseControlReStacksAFannedCluster() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b", "c"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        controller.setToastHoverForTesting(id: "b", hovering: true)
        #expect(controller.presentationForTesting == .fanned)

        controller.collapseToStackForTesting()
        #expect(controller.presentationForTesting == .stacked)
        #expect(controller.isFannedOutForTesting == false)
    }

    /// Dropping back below the threshold (a toast removed) clears the fan state — the
    /// cluster becomes a plain list again.
    @Test func droppingBelowThresholdResetsToList() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b", "c"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }
        controller.setToastHoverForTesting(id: "a", hovering: true)
        #expect(controller.presentationForTesting == .fanned)

        // "c" leaves → 2 toasts → plain list, fan state cleared.
        controller.render(pills: makePills(["a", "b"]), controlRow: nil, detailViewModel: nil)
        #expect(controller.presentationForTesting == .list)
        #expect(controller.isFannedOutForTesting == false)
        #expect(controller.toastStackScaleForTesting(id: "a") == 1.0)
    }

    /// Teardown (`hide()`) closes every toast window AND both control windows cleanly.
    @Test func hideClosesEveryWindow() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(
            pills: makePills(["a", "b", "c", "d"]),
            controlRow: .showMore(hiddenCount: 1),
            detailViewModel: nil
        )
        #expect(controller.toastPanelCountForTesting == 4)
        #expect(controller.controlPanelForTesting != nil)

        controller.hide()
        #expect(controller.toastPanelCountForTesting == 0, "all toast windows are torn down")
        #expect(controller.toastPanelForTesting(id: "a") == nil)
        #expect(controller.controlPanelForTesting == nil, "the +N-more control window is torn down")
    }

    /// A dismissed/removed session's toast window is torn down on the next render (it left
    /// the visible set), while the remaining toasts survive — no leaked window.
    @Test func aRemovedToastWindowIsClosedButSiblingsSurvive() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }
        #expect(controller.toastPanelCountForTesting == 2)

        controller.render(pills: [makePill(id: "b")], controlRow: nil, detailViewModel: nil)
        #expect(controller.toastPanelForTesting(id: "a") == nil, "the removed toast window is closed")
        #expect(controller.toastPanelForTesting(id: "b")?.isVisible == true, "the sibling survives")
        #expect(controller.toastPanelCountForTesting == 1)
    }

    /// BLOCKING-1 regression: clicking the collapse control must NOT wedge the cluster hovered
    /// forever. The collapse control is HIDDEN the instant its click re-stacks the cluster, so
    /// no `mouseExited` ever fires for it — if its hover contribution isn't dropped explicitly,
    /// `isClusterHovered` stays pinned true and every later collapse/leave is blocked. This
    /// exercises the REAL path: fan out → move onto the collapse control → click it → then a
    /// later toast hover+leave must still fan out AND re-stack.
    @Test func collapseControlClickDoesNotWedgeClusterHoverForever() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b", "c"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }

        // Fan out, then move the pointer from the toast onto the collapse control (as a user
        // would just before clicking it) — the cluster stays fanned while the control is hovered.
        controller.setToastHoverForTesting(id: "a", hovering: true)
        #expect(controller.presentationForTesting == .fanned)
        controller.setCollapseControlHoverForTesting(true)
        controller.setToastHoverForTesting(id: "a", hovering: false)
        #expect(controller.presentationForTesting == .fanned,
                "still fanned while the pointer is over the collapse control")

        // CLICK the collapse control → re-stacks. The control is hidden with NO mouse-exit event,
        // leaving a stale collapse-control hover that must be cleared by the fix.
        controller.collapseToStackForTesting()
        #expect(controller.presentationForTesting == .stacked)

        // The stale collapse-control hover must NOT wedge the cluster hovered: a later toast
        // hover must still fan out, and leaving must still re-stack.
        controller.setToastHoverForTesting(id: "b", hovering: true)
        #expect(controller.presentationForTesting == .fanned,
                "the cluster still responds to hover after the collapse click")
        controller.setToastHoverForTesting(id: "b", hovering: false)
        controller.flushPendingFanCollapseForTesting()
        #expect(controller.presentationForTesting == .stacked,
                "the cluster can still re-stack — the collapse click didn't wedge hover on")
        #expect(controller.isFannedOutForTesting == false)
    }

    /// HITBOX INVARIANT under native (full-width) stacking: a back card is now the SAME
    /// WIDTH as the front card (only offset down + dimmed), so its hover/hit tracking rect
    /// must equal the FULL-WIDTH pill rect at its offset position — exactly the front card's
    /// rect. The invariant "each card's tracking rect == its VISIBLE rect" still holds: the
    /// visible rect is the full-width pill for every card, front and back.
    @Test func stackedBackCardTrackingRectIsTheFullWidthPill() {
        let controller = ResearchStackedOverlayController.offscreenForTesting()
        controller.render(pills: makePills(["a", "b", "c"]), controlRow: nil, detailViewModel: nil)
        defer { controller.hide() }
        #expect(controller.presentationForTesting == .stacked)

        // The front card (index 0) keeps the full pill rect.
        #expect(controller.installedToastTrackingRectForTesting(id: "a")?.size == ResearchStackFrameLayout.expandedPillSize,
                "the front stacked card keeps the full pill hit region")

        // A back card (index 2) is full width now — its installed hit region equals the pure
        // full-width pill rect (scale 1.0), NOT a shrunken footprint.
        let backScale = ResearchStackFanLayout.stackedCardTransform(depthFromFront: 2).scale
        #expect(backScale == 1.0, "sanity: the back card is full width (native stacking)")
        let expectedBackRect = ResearchToastLayout.scaledPillRect(
            inWindowOfSize: ResearchToastLayout.expandedWindowContentSize,
            pillSize: ResearchStackFrameLayout.expandedPillSize,
            scale: backScale
        )
        let installedBackRect = controller.installedToastTrackingRectForTesting(id: "c")
        #expect(installedBackRect == expectedBackRect,
                "the back card's OS hit region equals the full-width pill rect (== its visible rect)")
        #expect(installedBackRect?.size == ResearchStackFrameLayout.expandedPillSize,
                "the back card's hit region IS the full-width pill (matches the front card's width)")

        // Fanning out keeps every card at the full pill hit region.
        controller.setToastHoverForTesting(id: "a", hovering: true)
        #expect(controller.presentationForTesting == .fanned)
        #expect(controller.installedToastTrackingRectForTesting(id: "c")?.size == ResearchStackFrameLayout.expandedPillSize,
                "fanned-out cards keep the full pill hit region")
    }
}

// MARK: - Composer single trailing-button intent (unified send/stop)

/// The PURE logic behind the detail composer's ONE morphing trailing button, which unifies
/// the old standalone Stop capsule and the send button into a single control (like a standard
/// AI chat window). Two contracts are pinned here without rendering any view:
///   - `forPhase`: which phase yields STOP vs SEND.
///   - `shouldSubmit`: the SINGLE guard both the SEND button and the Return key route through,
///     so a send fires ONLY in SEND mode with a non-empty trimmed draft — Return while the
///     button is a Stop (the run is working) never sends, and an empty draft never sends.
struct ResearchComposerPrimaryActionTests {

    /// While the run is ACTIVELY WORKING, the single trailing button is STOP — so it routes
    /// to the `onStop` (cancel-run) closure, not the send closure.
    @Test func runningMapsToStop() {
        #expect(ResearchComposerPrimaryAction.forPhase(.running) == .stop)
    }

    /// When the session is AWAITING the user (the plan is asking clarifying questions), the
    /// single trailing button is SEND — so it routes to the `onSubmitFollowUp` closure.
    @Test func needsInputMapsToSend() {
        #expect(ResearchComposerPrimaryAction.forPhase(.needsInput) == .send)
    }

    /// A DONE session, if ever surfaced through the composer path, is SEND (it can take a
    /// typed follow-up); it is NOT a Stop — there is nothing left to cancel.
    @Test func doneMapsToSend() {
        #expect(ResearchComposerPrimaryAction.forPhase(.done) == .send)
    }

    /// Only the RUNNING (actively working) phase produces a Stop; every other phase the
    /// composer can be shown for is SEND. This is the crux invariant: the button is STOP iff
    /// the run is genuinely working.
    @Test func onlyRunningProducesStop() {
        let stopPhases = [ResearchOverlayPhase.idle, .running, .needsInput, .done, .error, .stopped]
            .filter { ResearchComposerPrimaryAction.forPhase($0) == .stop }
        #expect(stopPhases == [.running])
    }

    /// In SEND mode with a non-empty trimmed draft, a submit attempt fires.
    @Test func sendModeWithDraftSubmits() {
        #expect(ResearchComposerPrimaryAction.shouldSubmit(action: .send, trimmedDraft: "hello"))
    }

    /// In SEND mode an EMPTY trimmed draft is suppressed — this is the same empty-draft rule
    /// that disables + dims the SEND button.
    @Test func sendModeWithEmptyDraftDoesNotSubmit() {
        #expect(!ResearchComposerPrimaryAction.shouldSubmit(action: .send, trimmedDraft: ""))
    }

    /// In STOP mode (the run is working) a submit attempt is ALWAYS suppressed — even with a
    /// non-empty draft. This is the Return-key guard: pressing Return while the trailing button
    /// is a Stop must NOT silently send a follow-up.
    @Test func stopModeNeverSubmitsEvenWithDraft() {
        #expect(!ResearchComposerPrimaryAction.shouldSubmit(action: .stop, trimmedDraft: "hello"))
        #expect(!ResearchComposerPrimaryAction.shouldSubmit(action: .stop, trimmedDraft: ""))
    }
}
