//
//  AcknowledgementCueSchedule.swift
//  Clawdy
//
//  Pure timing policy for the spoken "I heard you / still working" cues that give
//  instant feedback after push-to-talk release, based on the classic response-time
//  thresholds (≈0.1s: feels instant; ≈1s: flow kept; ≈10s: attention lost). Every cue is
//  VOICE, in the reply's own voice — never a sound effect:
//
//    t ≈ 1s     a micro-acknowledgement ("okay.") — a beat after the keys come up, the
//               way a listener nods after you finish, not the instant you stop; the
//               pre-rendered clip makes the timing exact. Real WORDS only: the
//               interjections ("mm-hm", "hmm") come out garbled from the model.
//    t ≈ 3s     a short filler ("hmm, let me look.")
//    t ≈ 8s     a progress line ("still checking.")
//    t ≈ 15s    a longer-wait line ("this one's taking a bit.")
//
//  The later fillers don't start before ~3s: with Sonnet + low effort an easy answer
//  reaches first audio at ~2–2.5s, and a filler that starts at 1s and runs ~1s would
//  collide with it. A filler fires only while the reply is still silent (and is dropped
//  the moment the reply's first TEXT arrives, since audio is then <1s away); the turn
//  ending for any reason cancels the rest.
//

import Foundation

enum AcknowledgementCueSchedule {
    struct Step: Equatable {
        let delaySeconds: TimeInterval
        /// A pool; the arbiter picks one at random so repeats don't sound canned.
        let phrases: [String]
    }

    // Phrasing follows the register of ChatGPT's voice mode: short, warm, conversational —
    // an assistant who's listening, not a status line. Real words only (interjections
    // like "mm-hm"/"hmm" come out garbled from the model).
    static let `default`: [Step] = [
        Step(delaySeconds: 1.0, phrases: ["okay.", "got it.", "sure.", "alright."]),
        Step(delaySeconds: 3.0, phrases: ["let me check.", "let me take a look.", "one moment."]),
        Step(delaySeconds: 8.0, phrases: ["still checking.", "still looking, bear with me.", "almost there."]),
        Step(delaySeconds: 15.0, phrases: ["this is taking a little longer than usual, hang tight.", "still working on it."])
    ]

    /// Every distinct phrase the schedule can speak (what the renderer pre-renders).
    static func allPhrases(in schedule: [Step] = `default`) -> [String] {
        schedule.flatMap(\.phrases)
    }

    /// The pause between key release and the acknowledgement (the first step's delay).
    static var acknowledgementDelaySeconds: TimeInterval { `default`.first?.delaySeconds ?? 0 }

    /// Whether a step due now should still fire: only while the reply hasn't produced
    /// TEXT yet (audio follows text within ~1s) and the turn is still in flight.
    static func shouldFire(step: Step, replyHasBegun: Bool, turnHasEnded: Bool) -> Bool {
        !replyHasBegun && !turnHasEnded
    }
}
