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
