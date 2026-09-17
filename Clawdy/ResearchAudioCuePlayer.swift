//
//  ResearchAudioCuePlayer.swift
//  Clawdy
//
//  The research subsystem's audio-cue seam: a run starting, finishing, or failing asks
//  the player for a cue. In production every cue is a SPOKEN line in the reply's own
//  voice, routed through `SpokenCueArbiter` (`SpokenResearchAudioCuePlayer`) so it can
//  never play over the reply or the user's recording. There are no sound effects.
//  Tests inject a recording fake.
//

import Foundation

/// The three research-lifecycle moments that get an audio cue. A user-initiated
/// Stop is intentionally NOT represented here — stopping a run is silent.
enum ResearchAudioCue: Equatable {
    /// A `[RESEARCH]` directive was accepted and a run is starting.
    case acknowledge
    /// A run finished successfully and a deliverable is ready.
    case done
    /// A run failed.
    case error
}

/// Plays a research lifecycle cue. Abstracted behind a protocol purely so tests can
/// inject a recording stub in place of real audio.
protocol ResearchAudioCuePlayer: AnyObject {
    func play(_ cue: ResearchAudioCue)
}

/// The real player: maps each cue to a distinct, subtle named macOS system sound
/// and plays it at a reduced volume so it stays quiet and non-jarring. Cues are
/// always on — there is no user mute toggle; the `isMuted` hook remains only as a
/// test seam (defaulting to never-muted).

/// A cue player that does nothing: the default for a `ResearchSession`/manager built
/// without one (tests, tools). The app injects `SpokenResearchAudioCuePlayer`.
final class SilentResearchAudioCuePlayer: ResearchAudioCuePlayer {
    func play(_ cue: ResearchAudioCue) {}
}
