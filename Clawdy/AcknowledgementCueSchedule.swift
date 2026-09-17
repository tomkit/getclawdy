//
//  AcknowledgementCueSchedule.swift
//  Clawdy
//
//  Pure timing policy for the spoken "I heard you / still working" cues that give
//  instant feedback after push-to-talk release, based on the classic response-time
//  thresholds (≈0.1s: feels instant; ≈1s: flow kept; ≈10s: attention lost). Every cue is
//  VOICE, in the reply's own voice — never a sound effect:
//
//    t ≈ 1s     an acknowledgement ("let me check.") — a beat after the keys come up, the
//               way a listener nods after you finish, not the instant you stop; the
//               pre-rendered clip makes the timing exact. Real WORDS only: the
//               interjections ("mm-hm", "hmm") come out garbled from the model.
//    t ≈ 6s     a short filler ("checking now.")
//    t ≈ 12s    a progress line ("still checking.")
//    t ≈ 20s    a longer-wait line ("this is taking a little longer than usual.")
//
//  The first filler waits until ~6s: an ordinary answer's first text lands at ~2–4s,
//  and the 1s acknowledgement already covers that stretch — a second line at 3s made
//  every quick question sound like two acknowledgements. A filler fires only while the reply is still silent (and is dropped
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
        // Users are almost always asking something, so the nod is "let me check", not "okay".
        Step(delaySeconds: 1.0, phrases: ["let me check.", "let me take a look.", "let me see.", "one moment."]),
        Step(delaySeconds: 6.0, phrases: ["checking now.", "looking into it.", "just a second."]),
        Step(delaySeconds: 12.0, phrases: ["still checking.", "still looking, bear with me.", "almost there."]),
        Step(delaySeconds: 20.0, phrases: ["this is taking a little longer than usual, hang tight.", "still working on it."])
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
