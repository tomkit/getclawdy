//
//  ResearchResultsRefreshAnimationTests.swift
//  ClawdyTests
//
//  Pure-logic tests for the results-window HOT-RELOAD affordance decision
//  (`ResearchResultsRefreshAnimation`). No window on screen — these assert the
//  rewrite-vs-question gate, the Reduce-Motion fallback, and the duration/style
//  selection that `ResearchResultsWindowController` consumes behind its thin AppKit
//  seam. The AppKit playback itself (glow pulse + "Updated" pill) is intentionally NOT
//  unit-tested; all branching lives in this pure factory so it can be.
//

import Testing
import Foundation
@testable import Clawdy

struct ResearchResultsRefreshAnimationTests {

    // MARK: - The core gate: only a rewrite animates

    @Test("A rewrite follow-up animates; a pure question does not")
    func shouldAnimateOnlyOnRewrite() {
        #expect(ResearchResultsRefreshAnimation.shouldAnimateRefresh(followUpKind: .rewrite) == true)
        #expect(ResearchResultsRefreshAnimation.shouldAnimateRefresh(followUpKind: .question) == false)
    }

    @Test("A pure question resolves to the do-nothing plan regardless of Reduce Motion")
    func questionAlwaysResolvesToNone() {
        for reduceMotionEnabled in [false, true] {
            let plan = ResearchResultsRefreshAnimation.plan(
                followUpKind: .question,
                reduceMotionEnabled: reduceMotionEnabled
            )
            #expect(plan.style == .none)
            #expect(plan.animates == false)
            #expect(plan.showsUpdatedAffordance == false)
            #expect(plan == .none)
            #expect(plan.totalAffordanceDuration == 0)
        }
    }

    // MARK: - Full-motion plan (rewrite, Reduce Motion OFF)

    @Test("A rewrite with Reduce Motion off gets the full cross-fade + glow pulse plan")
    func rewriteFullMotionPlan() {
        let plan = ResearchResultsRefreshAnimation.plan(
            followUpKind: .rewrite,
            reduceMotionEnabled: false
        )
        #expect(plan.style == .full)
        #expect(plan.animates == true)
        #expect(plan.showsUpdatedAffordance == true)
        // Full motion uses the real cross-fade + pill durations (the tween is present).
        #expect(plan.contentCrossFadeDuration == ResearchResultsRefreshAnimation.contentCrossFadeDuration)
        #expect(plan.affordanceFadeInDuration == ResearchResultsRefreshAnimation.affordanceFadeInDuration)
        #expect(plan.affordanceHoldDuration == ResearchResultsRefreshAnimation.affordanceHoldDuration)
        #expect(plan.affordanceFadeOutDuration == ResearchResultsRefreshAnimation.affordanceFadeOutDuration)
        // The visible motion (cross-fade + each pill fade) stays within a subtle,
        // non-jarring budget (~600ms) — only the deliberate HOLD lingers longer.
        #expect(plan.contentCrossFadeDuration <= 0.6)
        #expect(plan.affordanceFadeInDuration <= 0.6)
        #expect(plan.affordanceFadeOutDuration <= 0.6)
    }

    // MARK: - Reduce-Motion plan (rewrite, Reduce Motion ON)

    @Test("A rewrite with Reduce Motion on drops all motion but still shows the pill")
    func rewriteReducedMotionPlan() {
        let plan = ResearchResultsRefreshAnimation.plan(
            followUpKind: .rewrite,
            reduceMotionEnabled: true
        )
        #expect(plan.style == .reducedMotion)
        // Crucially NOT "animates": the controller must do a near-instant swap + no glow.
        #expect(plan.animates == false)
        // The "Updated" pill still appears so the user knows the page changed.
        #expect(plan.showsUpdatedAffordance == true)
        // No content cross-fade under Reduce Motion — the swap is instant.
        #expect(plan.contentCrossFadeDuration == 0)
        // The pill uses only a minimal opacity settle (not the full fade durations).
        #expect(plan.affordanceFadeInDuration == ResearchResultsRefreshAnimation.reducedMotionFadeDuration)
        #expect(plan.affordanceFadeOutDuration == ResearchResultsRefreshAnimation.reducedMotionFadeDuration)
        #expect(plan.affordanceFadeInDuration < ResearchResultsRefreshAnimation.affordanceFadeInDuration)
    }

    // MARK: - Derived helpers

    @Test("Total affordance duration is the sum of fade-in, hold, and fade-out")
    func totalAffordanceDurationSums() {
        let plan = ResearchResultsRefreshAnimation.plan(
            followUpKind: .rewrite,
            reduceMotionEnabled: false
        )
        let expectedTotal = plan.affordanceFadeInDuration
            + plan.affordanceHoldDuration
            + plan.affordanceFadeOutDuration
        #expect(plan.totalAffordanceDuration == expectedTotal)
        #expect(plan.totalAffordanceDuration > 0)
    }

    @Test("Full and reduced-motion plans are distinct styles")
    func fullAndReducedMotionDiffer() {
        let fullPlan = ResearchResultsRefreshAnimation.plan(followUpKind: .rewrite, reduceMotionEnabled: false)
        let reducedPlan = ResearchResultsRefreshAnimation.plan(followUpKind: .rewrite, reduceMotionEnabled: true)
        #expect(fullPlan != reducedPlan)
        #expect(fullPlan.style != reducedPlan.style)
    }

    // MARK: - Cancel/teardown set (the cross-fade must be cleared on hide/close)

    @Test("The content cross-fade key is in the set cleared on cancel/teardown")
    func crossFadeKeyIsClearedOnCancel() {
        // The controller adds the WKWebView cross-fade under this key AND must remove it
        // on every teardown path (rapid replace, window hide, window close). Asserting the
        // key is in the cancel set guards against the leak where a mid-flight cross-fade
        // was only cleared by the NEXT refresh, never on hide/close.
        #expect(
            ResearchResultsRefreshAnimation.webViewAnimationKeysToClearOnCancel
                .contains(ResearchResultsRefreshAnimation.contentCrossFadeAnimationKey)
        )
    }
}
