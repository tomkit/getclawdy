//
//  ThinkingCueState.swift
//  Clawdy
//
//  Pure, testable timing logic for the visual "thinking" cue shown when a turn
//  runs slow. While a request is in flight, if NO audio and NO answer text has
//  begun within `appearanceDelaySeconds`, a non-intrusive animated indicator is
//  shown on the existing cursor overlay so a slow turn doesn't feel dead.
//
//  IMPORTANT: this is PURELY a visual cue. It never times out, cancels, or
//  retries the request — the turn keeps running to completion. The cue must
//  disappear the instant the first audio/answer starts or the request ends or is
//  cancelled. Keeping the decision here (no I/O, no Timer) makes the show/hide
//  rule unit-testable without driving the real clock or UI.
//

import Foundation

enum ThinkingCueState {
    /// How long a request may run with NO audio and NO answer text before the
    /// visual thinking cue appears. A named constant so it's easy to tune.
    static let appearanceDelaySeconds: TimeInterval = 10

    /// Whether the thinking cue should currently be visible.
    ///
    /// The cue shows only when ALL of these hold:
    ///   - a request is still in flight (not finished or cancelled),
    ///   - no audio and no answer text has begun yet, and
    ///   - at least `appearanceDelaySeconds` have elapsed since the request began.
    ///
    /// The moment audio/answer begins or the request ends, the first two guards go
    /// false and the cue hides — there is no timeout or retry anywhere in here.
    static func shouldShowCue(
        isRequestInFlight: Bool,
        hasAnswerOrAudioStarted: Bool,
        elapsedSeconds: TimeInterval,
        appearanceDelaySeconds: TimeInterval = appearanceDelaySeconds
    ) -> Bool {
        guard isRequestInFlight else { return false }
        guard !hasAnswerOrAudioStarted else { return false }
        return elapsedSeconds >= appearanceDelaySeconds
    }
}
