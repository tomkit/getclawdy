//
//  KokoroTTSClient.swift
//  Clawdy
//
//  Clawdy's built-in voice: Kokoro-82M running on-device through the `ClawdyVoice` package
//  (ONNX Runtime + the Misaki G2P). Conforms to `SpeechTTSProviding` like the Apple and
//  ElevenLabs clients, so the manager and `StreamingResponseSpeaker` speak through it the
//  same way. The DEFAULT provider; Apple's `AVSpeechSynthesizer` is only the invisible last
//  resort when the model can't load (missing/corrupt file, an unsupported machine).
//
//  Latency shape: synthesis runs on the `KokoroSynthesizer` actor (never the main thread)
//  at roughly 0.25× real time on Apple silicon (the fp16 model; int8 measured 2.4× slower here). `StreamingResponseSpeaker`
//  calls `prepareClip` the moment a sentence completes, so sentence N+1 is synthesized
//  WHILE sentence N plays; `speak(preparedClip:)` then waits for the cue gate and starts
//  playback. Playback goes through `AVAudioPlayer` from in-memory WAV bytes (the same
//  path ElevenLabs clips and the pre-rendered cue files use).
//

import AVFoundation
import ClawdyVoice
import Foundation

@MainActor
final class KokoroTTSClient: NSObject, SpeechTTSProviding {
    /// The bundled model file name (see `scripts/fetch-models.sh`).
    static let bundledModelFileName = "kokoro-v1.0.fp16"

    /// Where the app bundle keeps the model, or nil when it was not bundled.
    nonisolated static var bundledModelURL: URL? {
        Bundle.main.url(forResource: bundledModelFileName, withExtension: "onnx")
    }

    /// True when the model file is present — the cheap, synchronous check provider
    /// resolution uses before the session has finished loading.
    nonisolated static var isModelBundled: Bool { bundledModelURL != nil }

    /// The voice replies (and cues) use. Persisted by the manager.
    var voice: KokoroVoice = .defaultVoice

    /// Awaited right before a clip starts playing (the spoken-cue arbiter gate), AFTER
    /// synthesis, so the model's work overlaps the acknowledgement instead of waiting for it.
    var playbackGate: (@MainActor () async -> Void)?

    /// Set once the model failed to load; provider resolution then falls back to Apple.
    private(set) var didFailToLoad = false

    private var synthesizerTask: Task<KokoroSynthesizer?, Never>?
    private var currentPlayer: AVAudioPlayer?
    /// Clips between "asked to play" and "audio started" — counted so `isPlaying` never dips
    /// to false in the gap between two sentences (which would fade the overlay early).
    private var clipsAwaitingPlayback = 0

    /// Loads the ONNX session and runs a warm-up inference in the background. Idempotent.
    func prewarm() {
        guard synthesizerTask == nil else { return }
        guard let modelURL = Self.bundledModelURL else {
            didFailToLoad = true
            return
        }
        let overrides = PronunciationOverridesFile.load()
        synthesizerTask = Task.detached(priority: .userInitiated) {
            do {
                let synthesizer = try KokoroSynthesizer(modelURL: modelURL)
                await synthesizer.setPronunciationOverrides(overrides)
                await synthesizer.prewarm()
                return synthesizer
            } catch {
                print("⚠️ Kokoro voice unavailable, falling back to Apple TTS: \(error)")
                return nil
            }
        }
        Task { [weak self] in
            if await self?.synthesizerTask?.value == nil { self?.didFailToLoad = true }
        }
    }

    /// The loaded synthesizer (awaits the background load), or nil when unavailable.
    func synthesizer() async -> KokoroSynthesizer? {
        if synthesizerTask == nil { prewarm() }
        return await synthesizerTask?.value
    }

    /// Re-reads `~/.clawdy/pronunciations.txt` (called on each turn — it's a tiny file).
    func reloadPronunciationOverrides() async {
        let overrides = PronunciationOverridesFile.load()
        await synthesizer()?.setPronunciationOverrides(overrides)
    }

    /// Synthesizes `text` to WAV bytes without playing it (used for the cue cache).
    func renderWAV(_ text: String, voice: KokoroVoice) async throws -> Data {
        guard let synthesizer = await synthesizer() else { throw KokoroSynthesizerError.modelProducedNoAudio }
        let samples = try await synthesizer.synthesize(text: text, voice: voice)
        return WAVFile.data(samples: samples, sampleRate: KokoroSynthesizer.sampleRate)
    }

    // MARK: - Speaking

    /// A sentence whose synthesis has been started (or finished) but not yet played.
    struct PreparedClip {
        let id = UUID()
        let text: String
        let wavData: Task<Data, Error>
    }

    /// Synthesis tasks that haven't been played yet, so `stopPlayback()` (a re-press, Stop)
    /// can cancel them — otherwise a six-sentence reply interrupted at sentence two would
    /// keep the actor busy for seconds and delay the NEXT turn's first clip.
    private var inFlightPrepareTasks: [UUID: Task<Data, Error>] = [:]

    /// Starts synthesizing `text` in the background immediately. Call this as soon as a
    /// sentence is known so the model works while earlier sentences are still playing.
    func prepareClip(_ text: String) -> PreparedClip {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = self.voice
        let wavData = Task<Data, Error> { [weak self] in
            guard let self, let synthesizer = await self.synthesizer() else { throw KokoroSynthesizerError.modelProducedNoAudio }
            try Task.checkCancellation()
            let samples = try await synthesizer.synthesize(text: trimmedText, voice: voice)
            return WAVFile.data(samples: samples, sampleRate: KokoroSynthesizer.sampleRate)
        }
        let clip = PreparedClip(text: trimmedText, wavData: wavData)
        inFlightPrepareTasks[clip.id] = wavData
        return clip
    }

    /// Plays a prepared clip: awaits its synthesis, the cue gate, then starts playback and
    /// returns (the caller polls `isPlaying` for the end, like the Apple client).
    func speak(preparedClip: PreparedClip) async throws {
        clipsAwaitingPlayback += 1
        defer {
            clipsAwaitingPlayback -= 1
            inFlightPrepareTasks[preparedClip.id] = nil
        }
        let wavData = try await preparedClip.wavData.value
        try Task.checkCancellation()
        await playbackGate?()
        try Task.checkCancellation()
        currentPlayer?.stop()
        play(wavData)
        print("🔊 Kokoro TTS: speaking \(preparedClip.text.count) characters")
    }

    // MARK: - SpeechTTSProviding

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        try await speak(preparedClip: prepareClip(trimmedText))
    }

    var isPlaying: Bool {
        clipsAwaitingPlayback > 0 || (currentPlayer?.isPlaying ?? false)
    }

    func stopPlayback() {
        for task in inFlightPrepareTasks.values { task.cancel() }
        inFlightPrepareTasks = [:]
        currentPlayer?.stop()
        currentPlayer = nil
    }

    // MARK: - Playback

    private func play(_ wavData: Data) {
        guard let player = try? AVAudioPlayer(data: wavData) else { return }
        player.delegate = self
        currentPlayer = player
        player.play()
    }
}

extension KokoroTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.currentPlayer === player { self.currentPlayer = nil }
        }
    }
}
