//
//  AnnotationModeWatchdog.swift
//  Clawdy
//
//  Pure, testable timing logic for the annotation-mode wedge DETECTOR.
//  Annotation mode is armed on the push-to-talk PRESS and normally torn down on
//  a clean key RELEASE. But a window-manager shortcut (e.g. ctrl+option+arrow to
//  move a window) can force-disable the listen-only event tap during a heavy-input
//  window, dropping the user's modifier key-UP so the release never fires and the
//  overlay wedges on. This watchdog is the FINAL backstop for that case.
//
//  IMPORTANT: it must NEVER interrupt a legitimate long hold. A user building a
//  research/page request can physically hold Ctrl+Option for well over the cap
//  while speaking a long prompt — that is not a wedge. So when the cap elapses the
//  watchdog RECONCILES against the LIVE hardware modifier flags (the same check
//  the tap-reenable reconcile uses): if the chord is STILL held it's a real hold
//  and the timer is re-armed for another interval; only when the chord is NO
//  longer held (armed but keys are actually up) is it a confirmed wedge that tears
//  down. The Task-based timer lives in CompanionManager; keeping the decision here
//  (no I/O, no Timer) makes it unit-testable without driving the real clock.
//

import Foundation

enum AnnotationModeWatchdog {
    /// Interval after which the watchdog re-checks whether annotation mode is a
    /// confirmed wedge. Chosen well above a normal push-to-talk hold; on each
    /// elapse a still-held chord simply re-arms, so this is a poll interval, not a
    /// hard timeout that can interrupt a real interaction.
    static let maximumActiveDurationSeconds: TimeInterval = 18

    /// Whether annotation mode should be force-torn-down now.
    ///
    /// Fires only when ALL of these hold:
    ///   - annotation mode is still armed (a normal release/escape/success would
    ///     have already cleared the flag, so this is false in every normal path),
    ///   - at least `maximumActiveDurationSeconds` have elapsed since it was armed,
    ///     and
    ///   - the live hardware modifier flags NO LONGER contain the shortcut chord —
    ///     i.e. the keys are actually up while annotation mode is still armed, the
    ///     signature of a missed-release wedge.
    ///
    /// When the chord is still physically held this returns false so the caller
    /// re-arms instead of interrupting a legitimate long spoken prompt.
    static func shouldForceTeardown(
        isAnnotationModeActive: Bool,
        liveFlagsContainShortcut: Bool,
        elapsedSeconds: TimeInterval,
        maximumActiveDurationSeconds: TimeInterval = maximumActiveDurationSeconds
    ) -> Bool {
        guard isAnnotationModeActive else { return false }
        guard elapsedSeconds >= maximumActiveDurationSeconds else { return false }
        return !liveFlagsContainShortcut
    }
}
