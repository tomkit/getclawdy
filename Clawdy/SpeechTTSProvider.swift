//
//  SpeechTTSProvider.swift
//  Clawdy
//
//  Common abstraction over the text-to-speech backends Clawdy can speak
//  through. The on-device Apple synthesizer (`LocalSpeechTTSClient`) is the
//  free default and the automatic fallback; the optional ElevenLabs client
//  (`ElevenLabsTTSClient`) calls the ElevenLabs API directly with the user's
//  own key for higher-quality speech.
//
//  Everything in this file that decides WHICH provider to use and WHEN to fall
//  back is a pure, side-effect-free function so it can be unit-tested headlessly
//  without a network or a real synthesizer.
//

import Foundation

/// Character-level alignment for ONE spoken clip: the exact characters voiced and the
/// audio times at which each is spoken. Produced by the ElevenLabs `/with-timestamps`
/// endpoint; used to sync the shadow-cursor advance to the moment an element is named.
///
/// TRAP 2 (per-clip timing) — these times are RELATIVE to THIS clip's own audio zero,
/// NOT a global timeline. `StreamingResponseSpeaker` speaks a response as multiple
/// clips (first sentence as one clip, the batched remainder as another), and each clip
/// is a separate `AVAudioPlayer` starting at t=0. A point's fire time must therefore be
/// measured against — and scheduled on — the SAME clip's playhead it was computed from.
struct SpeechClipAlignment: Equatable {
    /// One entry per character in the clip's ORIGINAL (non-normalized) text — see TRAP 1
    /// in `ElevenLabsAPI.parseSpeechWithTimestamps`.
    let characters: [String]
    /// The audio time (seconds, clip-relative) at which each character STARTS being voiced.
    let characterStartTimesSeconds: [Double]
    /// The audio time (seconds, clip-relative) at which each character FINISHES.
    let characterEndTimesSeconds: [Double]

    /// True when the model returned no usable timing (so the caller degrades to the
    /// untimed, fixed-dwell pointing sequence).
    var isEmpty: Bool { characters.isEmpty }
}

/// What a provider reports about ONE spoken clip so the cursor can be synced to it: the
/// character-level alignment (or nil), plus a reader for that clip's own playhead. Apple
/// TTS returns nils for both (graceful degradation — the pointing sequence falls back to
/// the fixed per-point dwell).
struct SpokenClipTiming {
    /// Character-level alignment for this clip, or nil when the provider produced none
    /// (Apple TTS, an empty/failed ElevenLabs alignment).
    let alignment: SpeechClipAlignment?
    /// Reads seconds elapsed since THIS clip's audio started playing (from the specific
    /// `AVAudioPlayer.currentTime` — TRAP 2), or nil once the clip is no longer the
    /// actively-playing clip (it finished or was superseded by the next clip). A nil
    /// return tells the scheduler to stop waiting and advance immediately for that point.
    let playheadSecondsReader: (@MainActor () -> TimeInterval?)?

    /// The "no timing available" value used by Apple and by the default protocol
    /// implementation, so callers gracefully degrade.
    static let none = SpokenClipTiming(alignment: nil, playheadSecondsReader: nil)
}

/// Anything that can speak a string aloud. Both `LocalSpeechTTSClient` and
/// `ElevenLabsTTSClient` conform, so `CompanionManager` can speak through
/// whichever provider the user selected. The surface deliberately matches the
/// original ElevenLabs client (speakText / isPlaying / stopPlayback) so the
/// overlay timing and state machine are unchanged.
@MainActor
protocol SpeechTTSProviding: AnyObject {
    /// Speaks `text` aloud. Returns once playback has been enqueued/started so
    /// the caller can flip into the "responding" state. Throws if the provider
    /// can't produce audio (missing key, network failure, timeout, bad
    /// response, decode failure) — the caller is expected to fall back.
    func speakText(_ text: String) async throws
    /// Speaks `text` and reports any character-level timing the provider produced,
    /// plus a reader for the clip's own playhead, so the caller can sync the shadow
    /// cursor to the spoken words. Providers WITHOUT timing (Apple) fall back to the
    /// default implementation below, which speaks via `speakText` and returns
    /// `SpokenClipTiming.none` — so callers degrade gracefully to untimed pointing.
    /// Only `ElevenLabsTTSClient` overrides this to return real alignment.
    func speakTextReportingTiming(_ text: String) async throws -> SpokenClipTiming
    /// Whether audio is currently playing back.
    var isPlaying: Bool { get }
    /// Stops any in-progress playback immediately.
    func stopPlayback()
    /// Optional warm-up (e.g. priming the on-device synthesizer so the first utterance has no
    /// cold-start delay). No-op by default so callers can hold the client as the protocol type;
    /// the local Apple client overrides it.
    func prewarm()
}

extension SpeechTTSProviding {
    /// Default: speak with no timing. Apple (and any fake in tests) uses this, so an
    /// Apple-TTS turn always degrades to the untimed, fixed-dwell pointing sequence.
    func speakTextReportingTiming(_ text: String) async throws -> SpokenClipTiming {
        try await speakText(text)
        return .none
    }
    func prewarm() {}
}

/// Which text-to-speech engine the user has chosen in settings.
enum TTSEngineKind: String, CaseIterable, Identifiable {
    /// On-device `AVSpeechSynthesizer`. Free, always available, no key.
    case apple
    /// ElevenLabs cloud TTS, called directly with the user's own API key.
    case elevenLabs

    var id: String { rawValue }

    /// Short label for the settings picker.
    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    /// One-line description shown under the picker so the user understands the
    /// trade-off (free/local vs. their own paid key).
    var settingsSubtitle: String {
        switch self {
        case .apple: return "Free, on-device"
        case .elevenLabs: return "Your API key"
        }
    }
}

/// Pure decision logic for the TTS layer. No state, no I/O — every function
/// here is unit-testable.
enum TTSProviderSelection {
    /// Decides which provider should actually speak an utterance, given the
    /// user's selected engine and whether a usable ElevenLabs key is present.
    ///
    /// Apple is always usable. ElevenLabs is only usable when the user both
    /// selected it AND has a non-empty key configured; otherwise we silently
    /// resolve to Apple so the voice flow never goes silent.
    static func resolveProviderKind(
        selectedEngine: TTSEngineKind,
        hasUsableElevenLabsKey: Bool
    ) -> TTSEngineKind {
        switch selectedEngine {
        case .apple:
            return .apple
        case .elevenLabs:
            return hasUsableElevenLabsKey ? .elevenLabs : .apple
        }
    }

    /// Whether an API key string is usable at all (non-empty after trimming).
    /// A whitespace-only key counts as missing.
    static func isUsableElevenLabsKey(_ key: String?) -> Bool {
        guard let key else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether an error thrown while speaking through ElevenLabs should trigger
    /// a silent fallback to Apple TTS for that utterance.
    ///
    /// Every ElevenLabs failure mode — missing/invalid key, network failure,
    /// rate-limit, timeout, bad HTTP status, empty/undecodable audio — falls
    /// back so the user always hears *something*. The exception is
    /// cancellation: the user spoke again, so we must NOT fall back (that would
    /// speak a stale utterance over the new interaction).
    ///
    /// Cancellation reaches us two ways: as `CancellationError` from an explicit
    /// `Task.checkCancellation()`, but ALSO as `URLError(.cancelled)` because
    /// `URLSession`'s async `data(for:)` surfaces a cancelled Task as a URL
    /// error rather than a `CancellationError`. Both must suppress fallback.
    static func shouldFallBackToApple(for error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }
}

// MARK: - Audio-synced pointing

/// Which audio moment a point's cursor advance is anchored on. Kept as an enum so the
/// anchor strategy is a ONE-LINE change during live tuning (see `PointAudioSyncTuning`).
enum PointAudioAnchorStrategy: Equatable {
    /// Anchor on the START time of the word IMMEDIATELY BEFORE the tag position — i.e.
    /// the word that names the element (the model places the [POINT] tag right after it).
    /// This is the intended default: the claw arrives as the name is spoken.
    case startOfWordBeforeTag
    /// Anchor on the audio time AT the tag's character position. Kept as an easy
    /// alternative to try during tuning.
    case atTagPosition
}

/// The tunables that shape how the shadow cursor is synced to (and slightly LEADS)
/// ElevenLabs speech. Grouped in ONE place ON PURPOSE: the user tunes the FEEL against a
/// live build, so the lead and the anchor strategy must be trivial to adjust together.
/// `var` (not `let`) so a live/experimental build can poke these without a redesign.
enum PointAudioSyncTuning {
    /// How far AHEAD of the named word the claw should ARRIVE. We subtract this from the
    /// anchor time so the advance fires early — the cursor is pointing at the element by
    /// the time the user hears its name. ~0.4s felt right in bring-up; tune here.
    static var leadSeconds: Double = 0.4

    /// Which audio moment to anchor on. Default anchors on the start of the naming word.
    static var anchorStrategy: PointAudioAnchorStrategy = .startOfWordBeforeTag
}

/// Pure, side-effect-free mapping from a POINT's text position to the audio time at which
/// its cursor advance should fire. No AVFoundation, no network — every function here is
/// unit-tested. The async polling that WAITS for those times lives in `CompanionManager`.
enum PointAudioSyncMapper {
    /// Assigns a position in the full spoken (tag-stripped) text to one of the speaker's
    /// clips and re-bases it into that clip's own text.
    ///
    /// `StreamingResponseSpeaker` speaks clip 0 = the first sentence, clip 1 = the batched
    /// remainder. `firstClipTextLength` is the character length of clip 0. A position below
    /// it belongs to clip 0 (position unchanged); a position at/above it belongs to clip 1,
    /// re-based to clip 1's own zero — TRAP 2: clip 1's alignment times start at 0, so its
    /// positions must be measured from the start of clip 1's text, not the global text.
    static func clipAssignment(
        spokenPosition: Int,
        firstClipTextLength: Int
    ) -> (clipOrdinal: Int, positionInClip: Int) {
        if spokenPosition < firstClipTextLength {
            return (0, max(0, spokenPosition))
        }
        // Re-base into clip 1's own text coordinate space.
        return (1, max(0, spokenPosition - firstClipTextLength))
    }

    /// The clip-relative audio time (seconds) at which to fire the advance for a point
    /// named at `positionInClip`, applying the anchor strategy, subtracting `leadSeconds`,
    /// and CLAMPING to >= 0 (the playhead can never be negative, and a word early in the
    /// clip must still fire immediately rather than at a negative time). Returns nil when
    /// the alignment is empty (no timing → the caller degrades to the untimed sequence).
    static func fireTimeSeconds(
        alignment: SpeechClipAlignment,
        positionInClip: Int,
        strategy: PointAudioAnchorStrategy,
        leadSeconds: Double
    ) -> Double? {
        guard !alignment.isEmpty else { return nil }
        let characterCount = alignment.characters.count
        // Guard against a malformed response whose time arrays are shorter than the
        // character array — fall back to no timing rather than index out of range.
        guard alignment.characterStartTimesSeconds.count == characterCount else { return nil }

        let anchorCharacterIndex: Int
        switch strategy {
        case .atTagPosition:
            anchorCharacterIndex = min(max(0, positionInClip), characterCount - 1)
        case .startOfWordBeforeTag:
            anchorCharacterIndex = indexOfWordStartBefore(
                positionInClip: positionInClip,
                characters: alignment.characters
            )
        }
        let anchorTime = alignment.characterStartTimesSeconds[anchorCharacterIndex]
        return max(0, anchorTime - leadSeconds)
    }

    /// The character index at which the WORD immediately before `positionInClip` begins.
    /// Walks back over any whitespace between the word and the tag position, then back
    /// over the word's own characters to its first one. Clamped into range so it is always
    /// a valid index into the alignment arrays.
    static func indexOfWordStartBefore(positionInClip: Int, characters: [String]) -> Int {
        let characterCount = characters.count
        guard characterCount > 0 else { return 0 }

        func isWhitespace(_ character: String) -> Bool {
            character == " " || character == "\n" || character == "\t"
        }

        // Start at the last character strictly BEFORE the tag position.
        var index = min(max(0, positionInClip), characterCount) - 1
        if index < 0 { return 0 }
        // Skip any whitespace sitting between the naming word and the tag position.
        while index > 0 && isWhitespace(characters[index]) { index -= 1 }
        // Walk to the start of this word (stop when the previous character is whitespace).
        while index > 0 && !isWhitespace(characters[index - 1]) { index -= 1 }
        return max(0, min(index, characterCount - 1))
    }
}
