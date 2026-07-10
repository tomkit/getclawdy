//
//  ResearchToastRefinementsTests.swift
//  ClawdyTests
//
//  The research-toast interaction/visual refinement pass. Covers the PURE logic
//  factored out of the redesign:
//   - `ResearchToastControlSet`: the phase → secondary-control set — WORKING shows ONLY
//     Stop (no × dismiss), DONE shows the "view results" affordance plus the × dismiss
//     (history opens via the default card click, not a separate icon), and terminal
//     error/stopped shows just the × dismiss.
//   - `CompanionQuickAnswerControl`: the menu-bar quick-answer working/speaking → Stop
//     mapping.
//  (The hover hit-region / per-toast-window independence real-path tests live in
//   `ResearchToastWindowHoverTests` in ResearchOverlayUXTests.swift.)
//

import Testing
import AppKit
@testable import Clawdy

// MARK: - Toast control set (working → Stop only; done → results + dismiss)

struct ResearchToastControlSetTests {

    /// WHILE WORKING (running / needs-input) the ONLY end-run control is Stop — the ×
    /// dismiss must NOT be offered so "hide the pill" can't be mistaken for "cancel the
    /// run". (Item 2.)
    @Test func workingShowsOnlyStopAndNoDismiss() {
        for phase in [ResearchOverlayPhase.running, .needsInput] {
            let controls = ResearchToastControlSet.controls(forPhase: phase)
            #expect(controls.showsStop == true)
            #expect(controls.showsDismiss == false, "no × dismiss while a run is working")
            #expect(controls.showsViewResults == false)
            #expect(controls.showsViewHistory == false)
        }
    }

    /// DONE offers the "view results" affordance plus the × dismiss — and NOT Stop (there's
    /// nothing left to cancel). The conversation history is reached via the default card
    /// click, so the redundant "view history" icon is NO LONGER offered here.
    @Test func doneShowsResultsAndDismissButNotHistoryOrStop() {
        let controls = ResearchToastControlSet.controls(forPhase: .done)
        #expect(controls.showsViewResults == true)
        #expect(controls.showsViewHistory == false, "history opens via the default card click, not a separate icon")
        #expect(controls.showsDismiss == true, "× dismiss appears once terminal")
        #expect(controls.showsStop == false)
    }

    /// Terminal failure/stop is dismissible (× shown) with nothing to view and no Stop.
    @Test func terminalErrorAndStoppedShowOnlyDismiss() {
        for phase in [ResearchOverlayPhase.error, .stopped] {
            let controls = ResearchToastControlSet.controls(forPhase: phase)
            #expect(controls.showsDismiss == true)
            #expect(controls.showsStop == false)
            #expect(controls.showsViewResults == false)
            #expect(controls.showsViewHistory == false)
        }
    }

    /// Stop and dismiss are NEVER offered together — the two intents are mutually
    /// exclusive across every phase (Stop while working, dismiss once terminal).
    @Test func stopAndDismissAreNeverOfferedTogether() {
        let phases: [ResearchOverlayPhase] = [.idle, .running, .needsInput, .done, .error, .stopped]
        for phase in phases {
            let controls = ResearchToastControlSet.controls(forPhase: phase)
            #expect(!(controls.showsStop && controls.showsDismiss))
        }
    }

    /// The idle (hidden) phase offers no controls at all.
    @Test func idleShowsNoControls() {
        let controls = ResearchToastControlSet.controls(forPhase: .idle)
        #expect(controls.showsStop == false)
        #expect(controls.showsDismiss == false)
        #expect(controls.showsViewResults == false)
        #expect(controls.showsViewHistory == false)
    }

    /// The DETAIL panel header is driven off the SAME control set as the compact pill, so
    /// it can't diverge: WHILE WORKING it shows STOP and NEVER the close/dismiss-x — the
    /// fix for a running run still exposing an x-shaped affordance in the expanded detail
    /// view. (Item 2, detail-view header.)
    @Test func detailHeaderWhileWorkingShowsStopAndNotDismissX() {
        for phase in [ResearchOverlayPhase.running, .needsInput] {
            let control = ResearchToastControlSet.controls(forPhase: phase).detailHeaderControl
            #expect(control == .stop)
            #expect(control != .close, "no close/dismiss-x in the detail header while working")
        }
    }

    /// In a TERMINAL state the detail header may show the close (x); done/error/stopped
    /// all resolve to `.close` (never Stop). Idle shows no header control.
    @Test func detailHeaderInTerminalStatesShowsCloseNotStop() {
        for phase in [ResearchOverlayPhase.done, .error, .stopped] {
            let control = ResearchToastControlSet.controls(forPhase: phase).detailHeaderControl
            #expect(control == .close)
        }
        #expect(ResearchToastControlSet.controls(forPhase: .idle).detailHeaderControl == nil)
    }
}

// NOTE: the hover hit-region behavior moved to per-toast windows — its real-path tests
// now live in `ResearchToastWindowHoverTests` (ResearchOverlayUXTests.swift), which
// asserts each toast's own window frame equals the fixed expanded footprint across hover
// and that hovering one toast doesn't affect its siblings.

// MARK: - Research-overlay surface color routing (dark, matching the other windows)

/// The mini toast, full/expanded toast, and Recent Research badge + inline list all fill
/// with ONE shared dark surface so the research overlay reads as one system with the
/// app's other windows — NOT the brand blue (which is reserved for the Clawdy cursor).
struct ResearchToastSurfaceAppearanceTests {

    /// The shared overlay surface routes through the SAME dark `surface1` the app's other
    /// windows use (the menu-bar popover panel / the toast detail panel / the History
    /// window), so all these surfaces read as one dark system.
    @Test func sharedSurfaceIsTheStandardDarkWindowSurface() {
        #expect(ResearchToastSurfaceAppearance.background == DS.Colors.surface1)
    }

    /// The overlay surface is NEVER the brand accent — the OpenClaw red is reserved for the
    /// Clawdy cursor and accent surfaces, never a toast/badge surface fill.
    @Test func sharedSurfaceIsNotTheBrandAccent() {
        #expect(ResearchToastSurfaceAppearance.background != DS.Colors.accent)
    }
}

// MARK: - Menu-bar quick-answer Stop mapping

struct CompanionQuickAnswerControlTests {

    /// The panel shows Stop while the warm quick-answer is WORKING (processing) or
    /// SPEAKING (responding) so the user can cancel the in-flight turn + its TTS.
    @Test func stopIsShownWhileProcessingOrResponding() {
        #expect(CompanionQuickAnswerControl.shouldShowStop(forVoiceState: .processing) == true)
        #expect(CompanionQuickAnswerControl.shouldShowStop(forVoiceState: .responding) == true)
    }

    /// Idle and listening show no Stop — there's nothing to cancel; the panel reverts to
    /// its normal dismiss (×) chrome.
    @Test func stopIsHiddenWhenIdleOrListening() {
        #expect(CompanionQuickAnswerControl.shouldShowStop(forVoiceState: .idle) == false)
        #expect(CompanionQuickAnswerControl.shouldShowStop(forVoiceState: .listening) == false)
    }
}
