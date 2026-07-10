//
//  ResearchAudioCuePlayer.swift
//  Clawdy
//
//  Short, subtle SYSTEM-sound cues for the autonomous research subsystem so the
//  user gets non-verbal feedback on a run's lifecycle without the app ever
//  speaking. These are DELIBERATELY NOT routed through the TTS / AVSpeechSynthesizer
//  path: a research run happens in the background while the user may still be
//  getting a spoken quick-answer reply, and a cue must never talk over that voice.
//  Named macOS system sounds (NSSound(named:)) are used instead — quiet, familiar,
//  and instantly recognizable.
//
//  The player is injected into `ResearchSessionManager` (which forwards it to each
//  `ResearchSession`, where the cues actually fire) so tests can substitute a
//  recording stub and assert WHICH cue fires on WHICH lifecycle transition
//  (accept → acknowledge, complete → done, fail → error, stop → none) without any
//  real audio. Cues are always on — there is no user mute toggle; the `isMuted`
//  hook remains (defaulting to never-muted) only as an injection seam for tests.
//

import AppKit

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
final class SystemSoundResearchAudioCuePlayer: ResearchAudioCuePlayer {
    /// Gate evaluated at play time. Always `false` in production (cues are always
    /// on); a test can inject `{ true }` to assert the gate silences every cue.
    private let isMuted: () -> Bool

    /// The sink that actually renders a named system sound. Injectable so tests can
    /// assert the cue → sound-name mapping (and the gate) WITHOUT real audio. In
    /// production this plays the named /System/Library/Sounds file at a reduced
    /// volume.
    private let playNamedSystemSound: (String) -> Void

    /// Volume for every cue: quiet enough to be a gentle background signal rather
    /// than an alert. Named so its intent is obvious at the call site.
    private static let cueVolumePleasantlyQuiet: Float = 0.6

    init(
        isMuted: @escaping () -> Bool = { false },
        playNamedSystemSound: @escaping (String) -> Void = SystemSoundResearchAudioCuePlayer.playRealSystemSound
    ) {
        self.isMuted = isMuted
        self.playNamedSystemSound = playNamedSystemSound
    }

    func play(_ cue: ResearchAudioCue) {
        guard !isMuted() else { return }
        playNamedSystemSound(Self.systemSoundName(for: cue))
    }

    /// Plays a named macOS system sound at the quiet cue volume. Returns silently if
    /// the name doesn't resolve to a bundled system sound.
    private static func playRealSystemSound(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = cueVolumePleasantlyQuiet
        sound.play()
    }

    /// The named /System/Library/Sounds file chosen for each cue. Distinct and
    /// intentionally subtle:
    ///   - acknowledge → "Tink"  (a soft, brief tap that the run has begun)
    ///   - done        → "Glass" (a pleasant chime that the deliverable is ready)
    ///   - error       → "Basso" (a gentle low tone signaling a failure)
    static func systemSoundName(for cue: ResearchAudioCue) -> String {
        switch cue {
        case .acknowledge:
            return "Tink"
        case .done:
            return "Glass"
        case .error:
            return "Basso"
        }
    }
}
