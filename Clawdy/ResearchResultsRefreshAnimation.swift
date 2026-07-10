//
//  ResearchResultsRefreshAnimation.swift
//  Clawdy
//
//  Pure, testable decision logic for the results-window HOT-RELOAD affordance. When a
//  research FOLLOW-UP iterates on (rewrites) the generated report.html the embedded
//  WKWebView is reloaded — and we want the user to SEE that the page just updated with
//  a subtle "this just changed" tween (a soft cross-fade of the new content plus a
//  brief brand-red "Updated" pulse), instead of the page silently swapping.
//
//  This file contains NO AppKit: it only decides WHETHER to animate (rewrite → yes,
//  pure question → no), and, honoring macOS Reduce Motion, WHICH animation style +
//  durations to use. `ResearchResultsWindowController` consumes the resulting plan and
//  performs the actual Core Animation work behind that thin seam. Keeping the decision
//  pure lets the rewrite-vs-question gate, the Reduce-Motion fallback, and the duration
//  selection all be unit-tested with no window on screen.
//

import Foundation

/// What kind of voice follow-up just completed on a research session, from the
/// deliverable's point of view. A REWRITE replaced report.html (the page changed and
/// should visibly hot-reload); a QUESTION only answered aloud and wrote nothing (the
/// open page is unchanged, so it must NOT animate).
enum ResearchResultsFollowUpKind: Equatable {
    case rewrite
    case question
}

/// The visual style chosen for a results-window refresh.
enum ResearchResultsRefreshAnimationStyle: Equatable {
    /// No affordance at all — a pure question follow-up changed nothing on the page.
    case none
    /// Reduce Motion is on: swap the reloaded content near-instantly and show only a
    /// minimal opacity settle on the "Updated" affordance, with NO cross-fade and NO
    /// glow pulse (nothing that reads as motion).
    case reducedMotion
    /// The full subtle affordance: a soft cross-fade of the reloaded page plus a brief
    /// brand-red glow pulse and a fading "Updated" pill.
    case full
}

/// A resolved, self-contained description of how to play (or skip) a results-window
/// refresh affordance. The controller reads these fields directly — it makes no further
/// decisions of its own — so every branch of the behavior is decided (and tested) here.
struct ResearchResultsRefreshAnimationPlan: Equatable {
    let style: ResearchResultsRefreshAnimationStyle
    /// How long the reloaded WKWebView content cross-fades in. Zero when not animating.
    let contentCrossFadeDuration: TimeInterval
    /// How long the "Updated" affordance takes to fade in.
    let affordanceFadeInDuration: TimeInterval
    /// How long the "Updated" affordance stays fully visible before fading out.
    let affordanceHoldDuration: TimeInterval
    /// How long the "Updated" affordance takes to fade back out.
    let affordanceFadeOutDuration: TimeInterval

    /// True only for the full-motion style — the controller uses this to decide whether
    /// to run the cross-fade + glow pulse (vs. a near-instant swap under Reduce Motion).
    var animates: Bool { style == .full }

    /// True when there is any "Updated" affordance to show at all (everything but a
    /// pure-question refresh, which shows nothing).
    var showsUpdatedAffordance: Bool { style != .none }

    /// The total on-screen lifetime of the affordance, used by the controller to
    /// schedule its removal (and to cancel/replace it on a rapid re-iteration).
    var totalAffordanceDuration: TimeInterval {
        affordanceFadeInDuration + affordanceHoldDuration + affordanceFadeOutDuration
    }

    /// The do-nothing plan for a refresh that must not animate (a pure question).
    static let none = ResearchResultsRefreshAnimationPlan(
        style: .none,
        contentCrossFadeDuration: 0,
        affordanceFadeInDuration: 0,
        affordanceHoldDuration: 0,
        affordanceFadeOutDuration: 0
    )
}

/// Pure factory + gate for the results-window refresh affordance.
enum ResearchResultsRefreshAnimation {

    // The motion parts are deliberately quick (~350ms cross-fade / ~220ms pill fade-in)
    // so the refresh reads as a settle, not a page flash; the pill's HOLD is the brief
    // lingering "Updated" affordance, not motion.
    static let contentCrossFadeDuration: TimeInterval = 0.35
    static let affordanceFadeInDuration: TimeInterval = 0.22
    static let affordanceHoldDuration: TimeInterval = 0.85
    static let affordanceFadeOutDuration: TimeInterval = 0.4
    /// Under Reduce Motion every fade collapses to this near-instant opacity settle.
    static let reducedMotionFadeDuration: TimeInterval = 0.12

    /// The CAAnimation key under which the WKWebView content cross-fade is added on a
    /// full-motion refresh. Named here (pure) so the controller adds it and clears it
    /// under the SAME key on every teardown path.
    static let contentCrossFadeAnimationKey = "researchUpdateCrossFade"

    /// The WKWebView layer animation keys the controller must remove whenever an
    /// in-flight affordance is cancelled — on a rapid replace AND on window hide/close —
    /// so a mid-flight cross-fade can never survive past the affordance's life. Kept as a
    /// pure list so the cancel set is unit-testable even though the CAAnimation removal
    /// itself is AppKit.
    static let webViewAnimationKeysToClearOnCancel: [String] = [contentCrossFadeAnimationKey]

    /// The core gate: only a REWRITE follow-up (report.html actually replaced) drives a
    /// refresh affordance; a pure QUESTION follow-up changed nothing and must not animate.
    static func shouldAnimateRefresh(followUpKind: ResearchResultsFollowUpKind) -> Bool {
        followUpKind == .rewrite
    }

    /// Resolves the full plan for a refresh, honoring Reduce Motion. A pure question is
    /// always `.none`; a rewrite is `.full` normally and `.reducedMotion` when the user
    /// has macOS "Reduce motion" enabled.
    static func plan(
        followUpKind: ResearchResultsFollowUpKind,
        reduceMotionEnabled: Bool
    ) -> ResearchResultsRefreshAnimationPlan {
        guard shouldAnimateRefresh(followUpKind: followUpKind) else {
            return .none
        }

        if reduceMotionEnabled {
            // Swap content instantly (no cross-fade) and show the pill with only a
            // minimal opacity change — no glow pulse, nothing that reads as motion.
            return ResearchResultsRefreshAnimationPlan(
                style: .reducedMotion,
                contentCrossFadeDuration: 0,
                affordanceFadeInDuration: reducedMotionFadeDuration,
                affordanceHoldDuration: affordanceHoldDuration,
                affordanceFadeOutDuration: reducedMotionFadeDuration
            )
        }

        return ResearchResultsRefreshAnimationPlan(
            style: .full,
            contentCrossFadeDuration: contentCrossFadeDuration,
            affordanceFadeInDuration: affordanceFadeInDuration,
            affordanceHoldDuration: affordanceHoldDuration,
            affordanceFadeOutDuration: affordanceFadeOutDuration
        )
    }
}
