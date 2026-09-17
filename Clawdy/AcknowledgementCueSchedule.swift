//
//  AcknowledgementCueSchedule.swift
//  Clawdy
//
//  Pure timing policy for the spoken "I heard you / still working" cues that give
//  instant feedback after push-to-talk release, based on the classic response-time
//  thresholds (≈0.1s: feels instant; ≈1s: flow kept; ≈10s: attention lost):
//
//    t = 0      an EARCON (a short non-verbal blip) — always, it can't clash with speech
//    t ≈ 3s     a short filler in the reply's own voice ("hmm, let me look")
//    t ≈ 8s     a progress line ("still checking")
//    t ≈ 15s    a longer-wait line ("this one's taking a bit")
//
//  The verbal fillers deliberately don't start before ~3s: with Sonnet + low effort an
//  easy answer reaches first audio at ~2–2.5s, and a filler that starts at 1s and runs
//  ~1s would collide with the answer on most turns (either stuttering through a fade or
//  delaying the answer). A filler fires only if no reply audio has started; reply audio
//  always preempts a filler; the turn ending for any reason cancels the rest.
//

import Foundation

enum AcknowledgementCueSchedule {
    enum Cue: Equatable {
        case earcon
        case filler(phrases: [String])
    }

    struct Step: Equatable {
        let delaySeconds: TimeInterval
        let cue: Cue
    }

    /// The default schedule. Phrases are pools; the player picks one at random so a
    /// repeated wait doesn't sound canned.
    static let `default`: [Step] = [
        Step(delaySeconds: 0, cue: .earcon),
        Step(delaySeconds: 3.0, cue: .filler(phrases: ["hmm, let me look.", "let me check.", "one sec."])),
        Step(delaySeconds: 8.0, cue: .filler(phrases: ["still checking.", "still on it.", "almost there."])),
        Step(delaySeconds: 15.0, cue: .filler(phrases: ["this one's taking a bit.", "still working on it, hang on."]))
    ]

    /// Every distinct filler phrase in a schedule (what the renderer pre-renders).
    static func allPhrases(in schedule: [Step] = `default`) -> [String] {
        schedule.flatMap { step -> [String] in
            if case .filler(let phrases) = step.cue { return phrases }
            return []
        }
    }

    /// Whether a step due at `elapsed` should still fire: only while the reply hasn't
    /// produced audio and the turn is still in flight.
    static func shouldFire(step: Step, replyAudioHasStarted: Bool, turnHasEnded: Bool) -> Bool {
        !replyAudioHasStarted && !turnHasEnded
    }
}
