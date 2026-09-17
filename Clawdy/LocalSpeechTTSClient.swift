//
//  LocalSpeechTTSClient.swift
//  Clawdy
//
//  Local, free text-to-speech using AVSpeechSynthesizer (AVFoundation). Replaces
//  the metered ElevenLabs cloud TTS. The public surface (speakText / isPlaying /
//  stopPlayback) deliberately matches the old ElevenLabsTTSClient so the
//  CompanionManager state machine and overlay timing are unchanged.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechTTSClient: NSObject, SpeechTTSProviding {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Tracks whether speech is currently being spoken. AVSpeechSynthesizer's own
    /// `isSpeaking` briefly lags the delegate callbacks, so we maintain our own
    /// flag updated from the delegate for reliable transient-overlay timing.
    private var isCurrentlySpeaking = false

    /// Guards `prewarm()` so the silent priming utterance is only ever spoken once.
    private var hasPrewarmed = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// The best installed system voice for the current language: a Premium voice if the
    /// user has downloaded one (System Settings → Accessibility → Spoken Content), else
    /// Enhanced, else the compact default. Premium/Enhanced are neural and far less
    /// robotic; they can't be bundled, so this only helps when one is already installed.
    nonisolated static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let languageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let languagePrefix = String(languageCode.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(languagePrefix) }
        func best(_ quality: AVSpeechSynthesisVoiceQuality) -> AVSpeechSynthesisVoice? {
            candidates.first { $0.quality == quality && $0.language == languageCode }
                ?? candidates.first { $0.quality == quality }
        }
        return best(.premium) ?? best(.enhanced) ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    /// The identifier of the voice replies use (so cues can be rendered in the same voice).
    nonisolated static var preferredVoiceIdentifier: String? { preferredVoice()?.identifier }

    /// Primes AVSpeechSynthesizer so the FIRST real spoken response doesn't pay the
    /// one-time engine warmup (allocating the audio unit + loading the voice), which
    /// otherwise adds a noticeable hitch before the first utterance. We speak a
    /// single space at volume 0 (inaudible) which forces the synthesis pipeline to
    /// spin up without making any sound. No-op after the first call. This does NOT
    /// touch `isCurrentlySpeaking`, so it never reads as real playback to the
    /// transient-cursor timing.
    func prewarm() {
        guard !hasPrewarmed else { return }
        hasPrewarmed = true

        let primingUtterance = AVSpeechUtterance(string: " ")
        primingUtterance.volume = 0
        if let preferredVoice = Self.preferredVoice() {
            primingUtterance.voice = preferredVoice
        }
        speechSynthesizer.speak(primingUtterance)
    }

    /// Speaks `text` aloud through the system audio output. Returns as soon as
    /// playback has been enqueued (mirroring the old client, which returned right
    /// after `player.play()`), so the caller can flip into the "responding" state.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Stop anything already speaking so utterances don't overlap.
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmedText)
        // The best installed voice for the locale (Premium > Enhanced > compact).
        if let preferredVoice = Self.preferredVoice() {
            utterance.voice = preferredVoice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false

        isCurrentlySpeaking = true
        speechSynthesizer.speak(utterance)
        print("🔊 Local TTS: speaking \(trimmedText.count) characters")
    }

    /// Whether speech audio is currently playing back.
    var isPlaying: Bool {
        isCurrentlySpeaking || speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isCurrentlySpeaking = false
    }
}

extension LocalSpeechTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isCurrentlySpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isCurrentlySpeaking = false }
    }
}
