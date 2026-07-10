//
//  AnnotationWedgeTests.swift
//  ClawdyTests
//
//  Tests for the annotation-mode wedge fix: the three layered escape hatches that
//  keep the annotation overlay from getting stuck on when a window-manager
//  shortcut (e.g. ctrl+option+arrow) grabs the keys and the modifier key-UP
//  `flagsChanged` is lost, so the normal `.released` transition never fires.
//
//    (i)   reconciledTransition — synthesize the missed release when the live
//          hardware flags no longer contain the chord we still think is held.
//    (ii)  the keyCode-53 (Escape) mapping — Escape while armed cancels, while
//          not armed is inert.
//    (iii) the wedge-detector watchdog — never interrupts a still-held long prompt,
//          only tears down a confirmed wedge.
//
//  Plus INTEGRATION coverage that the aborts are TRUE aborts (cancel without
//  submitting) and that the watchdog Task is cancelled on every normal exit.
//

import Testing
import CoreGraphics
import AppKit
@testable import Clawdy

/// Spy dictation manager that records which teardown path an abort took, so a test
/// can prove the abort cancels WITHOUT submitting (never the normal release path,
/// which finalizes and submits recognized speech).
@MainActor
private final class DictationAbortSpy: BuddyDictationManager {
    private(set) var cancelWithoutSubmitCallCount = 0
    private(set) var lastCancelPreserveDraftText: Bool?
    private(set) var submittingReleaseCallCount = 0

    override func cancelCurrentDictation(preserveDraftText: Bool = true) {
        cancelWithoutSubmitCallCount += 1
        lastCancelPreserveDraftText = preserveDraftText
        // Intentionally does NOT call super: the spy only records the routing and
        // must not touch the real audio engine / recognition session in tests.
    }

    override func stopPushToTalkFromKeyboardShortcut() {
        submittingReleaseCallCount += 1
    }
}

@MainActor
struct AnnotationWedgeTests {

    // MARK: - (i) reconciledTransition (missed-release recovery)

    @Test func reconciledTransitionSynthesizesReleaseWhenChordNoLongerHeld() {
        // We thought the chord was held, but the live flags no longer contain it
        // (the key-UP flagsChanged was eaten while the tap was disabled).
        let transition = BuddyPushToTalkShortcut.reconciledTransition(
            wasPressed: true,
            liveFlagsContainShortcut: false
        )
        #expect(transition == .released)
    }

    @Test func reconciledTransitionReturnsNilWhenChordStillGenuinelyHeld() {
        // Still holding the chord — no synthetic release, the real release will fire.
        let transition = BuddyPushToTalkShortcut.reconciledTransition(
            wasPressed: true,
            liveFlagsContainShortcut: true
        )
        #expect(transition == nil)
    }

    @Test func reconciledTransitionReturnsNilWhenNeverPressed() {
        // Not armed to begin with — nothing to reconcile in either flag state.
        #expect(BuddyPushToTalkShortcut.reconciledTransition(
            wasPressed: false,
            liveFlagsContainShortcut: false
        ) == nil)
        #expect(BuddyPushToTalkShortcut.reconciledTransition(
            wasPressed: false,
            liveFlagsContainShortcut: true
        ) == nil)
    }

    @Test func modifierFlagsContainCurrentShortcutMatchesControlOptionChord() {
        // The current shortcut is ctrl + option. Both present → contained.
        let bothPresent = NSEvent.ModifierFlags([.control, .option]).rawValue
        #expect(BuddyPushToTalkShortcut.modifierFlagsContainCurrentShortcut(
            modifierFlagsRawValue: UInt64(bothPresent)
        ))

        // Only one of the two present → not contained.
        let onlyControl = NSEvent.ModifierFlags([.control]).rawValue
        #expect(!BuddyPushToTalkShortcut.modifierFlagsContainCurrentShortcut(
            modifierFlagsRawValue: UInt64(onlyControl)
        ))

        // No modifiers → not contained.
        #expect(!BuddyPushToTalkShortcut.modifierFlagsContainCurrentShortcut(
            modifierFlagsRawValue: 0
        ))
    }

    // MARK: - (ii) Escape (keyCode 53) mapping

    @Test func isEscapeKeyDownMatchesOnlyEscapeKeyDown() {
        #expect(BuddyPushToTalkShortcut.isEscapeKeyDown(eventType: .keyDown, keyCode: 53))
        // A different key going down is not the escape hatch.
        #expect(!BuddyPushToTalkShortcut.isEscapeKeyDown(eventType: .keyDown, keyCode: 49))
        // Escape key-UP does not trigger — only the key-down edge does.
        #expect(!BuddyPushToTalkShortcut.isEscapeKeyDown(eventType: .keyUp, keyCode: 53))
    }

    @Test func escapeCancelsOnlyWhenAnnotationModeIsArmed() {
        // Armed → Escape cancels annotation mode.
        #expect(CompanionManager.escapeShouldCancelAnnotation(isAnnotationModeActive: true))
        // Not armed → Escape is completely inert.
        #expect(!CompanionManager.escapeShouldCancelAnnotation(isAnnotationModeActive: false))
    }

    // MARK: - (iv) Both tap-disable reasons route through the reconcile

    @Test func bothTapDisableReasonsRouteThroughReconcile() {
        // A heavy-input window (the wedge trigger) surfaces as .tapDisabledByUserInput;
        // a slow callback surfaces as .tapDisabledByTimeout. BOTH must re-enable and
        // reconcile, so both map true here.
        #expect(BuddyPushToTalkShortcut.isTapDisableEvent(.tapDisabledByUserInput))
        #expect(BuddyPushToTalkShortcut.isTapDisableEvent(.tapDisabledByTimeout))
        // A normal modifier event is not a tap-disable event.
        #expect(!BuddyPushToTalkShortcut.isTapDisableEvent(.flagsChanged))
        #expect(!BuddyPushToTalkShortcut.isTapDisableEvent(.keyDown))
    }

    // MARK: - (iii) Wedge-detector watchdog timing decision

    @Test func watchdogTearsDownConfirmedWedgeWhenChordNoLongerHeld() {
        let interval = AnnotationModeWatchdog.maximumActiveDurationSeconds
        // Armed past the interval AND the chord is actually up → confirmed wedge.
        #expect(AnnotationModeWatchdog.shouldForceTeardown(
            isAnnotationModeActive: true,
            liveFlagsContainShortcut: false,
            elapsedSeconds: interval
        ))
    }

    @Test func watchdogDoesNotInterruptStillHeldLongPrompt() {
        let interval = AnnotationModeWatchdog.maximumActiveDurationSeconds
        // Armed past the interval but the chord is STILL physically held → the user
        // is mid-way through a legitimate long spoken prompt. Must NOT tear down.
        #expect(!AnnotationModeWatchdog.shouldForceTeardown(
            isAnnotationModeActive: true,
            liveFlagsContainShortcut: true,
            elapsedSeconds: interval + 60
        ))
    }

    @Test func watchdogDoesNotFireBeforeInterval() {
        let interval = AnnotationModeWatchdog.maximumActiveDurationSeconds
        #expect(!AnnotationModeWatchdog.shouldForceTeardown(
            isAnnotationModeActive: true,
            liveFlagsContainShortcut: false,
            elapsedSeconds: interval - 0.5
        ))
    }

    @Test func watchdogDoesNotFireOnceAnnotationModeReleasedOrReset() {
        // A normal release/escape/success clears isAnnotationModeActive — even far
        // past the interval with the chord absent, the watchdog must stay inert.
        let interval = AnnotationModeWatchdog.maximumActiveDurationSeconds
        #expect(!AnnotationModeWatchdog.shouldForceTeardown(
            isAnnotationModeActive: false,
            liveFlagsContainShortcut: false,
            elapsedSeconds: interval + 100
        ))
    }

    // MARK: - Integration: abort is a TRUE abort (cancel without submitting)

    @Test func abortCancelsDictationWithoutSubmitting() {
        let dictationSpy = DictationAbortSpy()
        let companionManager = CompanionManager(dictationManager: dictationSpy)

        companionManager.abortAnnotationModeAndDictation()

        // The abort took the cancel-WITHOUT-submit path, discarding the draft...
        #expect(dictationSpy.cancelWithoutSubmitCallCount == 1)
        #expect(dictationSpy.lastCancelPreserveDraftText == false)
        // ...and NEVER the normal release path, which would finalize + submit speech.
        #expect(dictationSpy.submittingReleaseCallCount == 0)
        // Annotation mode is torn down and the monitor's held-state is cleared so a
        // later clean press re-arms.
        #expect(!companionManager.isAnnotationModeActive)
        #expect(!companionManager.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed)
    }

    // MARK: - Integration: watchdog Task cancelled on every normal exit

    @Test func watchdogTaskIsCancelledByTeardownChokePoint() {
        let companionManager = CompanionManager(dictationManager: DictationAbortSpy())

        // Arm the watchdog the way a PTT press does.
        companionManager.startAnnotationModeWatchdog()
        #expect(companionManager.isAnnotationModeWatchdogActiveForTesting)

        // Every normal exit (release / escape / success / resign) funnels through
        // teardownAnnotationMode, which cancels the watchdog. Exercising that shared
        // choke point directly proves it can't fire after a clean teardown.
        companionManager.teardownAnnotationMode()
        #expect(!companionManager.isAnnotationModeWatchdogActiveForTesting)
    }
}
