//
//  ElevenLabsTTSClient.swift
//  Clawdy
//
//  Optional higher-quality TTS that calls the ElevenLabs API DIRECTLY with the
//  user's own API key (no proxy, no Cloudflare Worker). Conforms to
//  SpeechTTSProviding so CompanionManager can speak through it exactly like the
//  on-device Apple synthesizer.
//
//  Robustness: every request is bounded by a timeout, the network fetch runs
//  off the main actor, and any failure throws so the caller can silently fall
//  back to Apple TTS. The HTTP request/body/header construction and voices
//  parsing live in the pure `ElevenLabsAPI` so they're unit-testable; this file
//  only does the I/O and audio playback.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: NSObject, SpeechTTSProviding {
    /// The user's API key and chosen voice id, kept in sync by CompanionManager
    /// right before each utterance. Pulled live so a key the user just cleared
    /// never gets used.
    var apiKey: String?
    var voiceID: String = ElevenLabsAPI.defaultVoiceID

    /// How long any single ElevenLabs request may take before it's abandoned and
    /// we fall back to Apple TTS. Mirrors the bounded-wait philosophy of the CLI
    /// process runner so the voice flow can never hang.
    private let requestTimeoutSeconds: TimeInterval

    /// A single long-lived session so rapid back-to-back utterances reuse the
    /// connection pool instead of churning sockets.
    private let urlSession: URLSession

    private var audioPlayer: AVAudioPlayer?

    /// Our own playing flag, updated from the AVAudioPlayer delegate, because
    /// the player's own state can briefly lag the callbacks.
    private var isCurrentlyPlaying = false

    init(requestTimeoutSeconds: TimeInterval = 12) {
        self.requestTimeoutSeconds = requestTimeoutSeconds
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = requestTimeoutSeconds
        sessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: sessionConfiguration)
        super.init()
    }

    /// Synthesizes `text` via ElevenLabs and plays it. Throws on any failure
    /// (missing key, non-2xx status, empty/undecodable audio, network error,
    /// timeout, cancellation) so the caller falls back to Apple TTS.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Read the key into a local and immediately clear the stored copy so the
        // secret isn't retained on this client for the rest of the session.
        let usableAPIKey = apiKey
        apiKey = nil
        guard let usableAPIKey, TTSProviderSelection.isUsableElevenLabsKey(usableAPIKey) else {
            throw ElevenLabsTTSError.missingAPIKey
        }

        // Stop anything already speaking so utterances don't overlap.
        stopPlayback()

        let speechRequest = try ElevenLabsAPI.makeSpeechRequest(
            apiKey: usableAPIKey,
            voiceID: voiceID,
            text: trimmedText,
            requestTimeout: requestTimeoutSeconds
        )

        // Fetch off the main actor. URLSession's async data(for:) suspends
        // without blocking, and honors Task cancellation (the awaiting Task is
        // cancelled when the user speaks again — surfaced as URLError.cancelled).
        let (audioData, response) = try await urlSession.data(for: speechRequest)
        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse,
           !ElevenLabsAPI.isSuccessStatus(httpResponse.statusCode) {
            throw ElevenLabsTTSError.httpStatus(httpResponse.statusCode)
        }
        guard !audioData.isEmpty else {
            throw ElevenLabsTTSError.emptyAudio
        }

        // Decode the audio off the main actor — AVAudioPlayer(data:) parses the
        // stream up front, which we don't want to do while holding the main
        // thread. Player state itself stays main-actor-isolated below.
        let player = try await Self.decodeAudioPlayer(from: audioData)
        try Task.checkCancellation()

        player.delegate = self
        audioPlayer = player

        // play() returns false if playback can't start. Without checking it, no
        // delegate callback would fire and `isCurrentlyPlaying` would stick true
        // forever, spinning the transient-cursor fade loop. So only mark playing
        // when play() actually succeeds; otherwise reset and throw to fall back.
        isCurrentlyPlaying = true
        guard player.play() else {
            isCurrentlyPlaying = false
            audioPlayer = nil
            throw ElevenLabsTTSError.playbackFailed
        }
        print("🔊 ElevenLabs TTS: speaking \(trimmedText.count) characters")
    }

    /// Decodes MP3 audio data into an AVAudioPlayer off the main actor. Runs on a
    /// detached task so the (potentially non-trivial) decode doesn't block the
    /// main thread; the returned player is then used only from @MainActor.
    private nonisolated static func decodeAudioPlayer(from audioData: Data) async throws -> AVAudioPlayer {
        try await Task.detached(priority: .userInitiated) {
            do {
                let player = try AVAudioPlayer(data: audioData)
                player.prepareToPlay()
                return player
            } catch {
                throw ElevenLabsTTSError.audioDecodeFailed
            }
        }.value
    }

    /// Whether audio is currently playing back.
    var isPlaying: Bool {
        isCurrentlyPlaying || (audioPlayer?.isPlaying ?? false)
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
        }
        audioPlayer = nil
        isCurrentlyPlaying = false
    }

    /// Fetches the voices on the user's account so the settings picker can list
    /// them. Returns an empty array if parsing yields nothing; throws on network
    /// failure or a non-2xx status so the UI can offer the manual-voice-id path.
    func fetchAvailableVoices() async throws -> [ElevenLabsVoice] {
        let usableAPIKey = apiKey
        apiKey = nil
        guard let usableAPIKey, TTSProviderSelection.isUsableElevenLabsKey(usableAPIKey) else {
            throw ElevenLabsTTSError.missingAPIKey
        }
        let voicesRequest = ElevenLabsAPI.makeVoicesRequest(
            apiKey: usableAPIKey,
            requestTimeout: requestTimeoutSeconds
        )
        let (voicesData, response) = try await urlSession.data(for: voicesRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !ElevenLabsAPI.isSuccessStatus(httpResponse.statusCode) {
            throw ElevenLabsTTSError.httpStatus(httpResponse.statusCode)
        }
        return try ElevenLabsAPI.parseVoices(from: voicesData)
    }
}

extension ElevenLabsTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isCurrentlyPlaying = false }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.isCurrentlyPlaying = false }
    }
}
