//
//  AcknowledgementCueRenderer.swift
//  Clawdy
//
//  Renders the short filler phrases ("hmm, let me look", "still checking") ONCE per voice
//  into a disk cache, so at play time a cue is a local file, never a network call. The
//  cue is rendered in the same voice the reply will use, so it sounds like the same
//  speaker pausing rather than a UI beep:
//
//    • Kokoro (the default): synthesized on-device through `KokoroTTSClient`; WAV on disk.
//    • Apple: `AVSpeechSynthesizer.write` into a CAF file (the selected system voice).
//    • ElevenLabs: one `/stream` request per phrase per voice (≈20 characters each, a
//      one-time cost when a voice is first used); MP3 on disk.
//
//  Cache: ~/Library/Application Support/Clawdy/cues/<provider>-<voice>/<phrase-hash>.<ext>
//  (app-owned, not the user-authored `~/.clawdy`). Rendering runs in the background at
//  launch and whenever the voice changes; a phrase that hasn't rendered yet is skipped
//  by the player rather than awaited.
//

import AVFoundation
import ClawdyVoice
import CryptoKit
import Foundation

struct AcknowledgementCueRenderer {
    /// Which voice a cue must match.
    enum Voice: Equatable {
        case kokoro(voiceID: String)
        case apple(voiceIdentifier: String?)
        case elevenLabs(voiceID: String)

        var cacheDirectoryName: String {
            switch self {
            case .kokoro(let voiceID): return "kokoro-" + Self.safe(voiceID)
            case .apple(let identifier): return "apple-" + Self.safe(identifier ?? "default")
            case .elevenLabs(let voiceID): return "elevenlabs-" + Self.safe(voiceID)
            }
        }

        var fileExtension: String {
            switch self {
            case .kokoro: return "wav"
            case .apple: return "caf"
            case .elevenLabs: return "mp3"
            }
        }

        private static func safe(_ value: String) -> String {
            String(value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." ? Character($0) : "_" })
        }
    }

    let cacheRootDirectory: URL

    init(cacheRootDirectory: URL = AcknowledgementCueRenderer.defaultCacheRootDirectory()) {
        self.cacheRootDirectory = cacheRootDirectory
    }

    static func defaultCacheRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clawdy/cues", isDirectory: true)
    }

    /// The on-disk location a rendered phrase lives at for `voice` (whether or not it exists yet).
    func fileURL(phrase: String, voice: Voice) -> URL {
        let digest = SHA256.hash(data: Data(phrase.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheRootDirectory
            .appendingPathComponent(voice.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("\(digest).\(voice.fileExtension)")
    }

    /// The rendered file if it exists, else nil (the player skips the cue).
    func cachedFileURL(phrase: String, voice: Voice) -> URL? {
        let url = fileURL(phrase: phrase, voice: voice)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Renders every phrase missing from the cache for `voice`. Safe to call repeatedly;
    /// already-rendered phrases are skipped. Failures are logged and skipped.
    func renderMissing(
        phrases: [String],
        voice: Voice,
        elevenLabsAPIKey: String? = nil,
        kokoroTTSClient: KokoroTTSClient? = nil
    ) async {
        for phrase in phrases where cachedFileURL(phrase: phrase, voice: voice) == nil {
            let destination = fileURL(phrase: phrase, voice: voice)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch voice {
                case .kokoro(let voiceID):
                    guard let kokoroTTSClient else { return }
                    let kokoroVoice = KokoroVoice.bundled.first { $0.id == voiceID } ?? .defaultVoice
                    let wavData = try await kokoroTTSClient.renderWAV(phrase, voice: kokoroVoice)
                    try wavData.write(to: destination, options: .atomic)
                case .apple(let voiceIdentifier):
                    try await Self.renderWithApple(phrase: phrase, voiceIdentifier: voiceIdentifier, to: destination)
                case .elevenLabs(let voiceID):
                    guard let elevenLabsAPIKey else { return }
                    try await Self.renderWithElevenLabs(phrase: phrase, voiceID: voiceID, apiKey: elevenLabsAPIKey, to: destination)
                }
            } catch {
                print("⚠️ Could not render cue '\(phrase)' for \(voice.cacheDirectoryName): \(error)")
            }
        }
    }

    // MARK: - Apple

    @MainActor
    private static func renderWithApple(phrase: String, voiceIdentifier: String?, to destination: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: phrase)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        var audioFile: AVAudioFile?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                if pcmBuffer.frameLength == 0 {
                    // End of stream.
                    if !didResume { didResume = true; continuation.resume() }
                    return
                }
                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(forWriting: destination, settings: pcmBuffer.format.settings)
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    if !didResume { didResume = true; continuation.resume(throwing: error) }
                }
            }
        }
        // Keep the synthesizer alive until the write finished.
        withExtendedLifetime(synthesizer) {}
    }

    // MARK: - ElevenLabs

    private static func renderWithElevenLabs(phrase: String, voiceID: String, apiKey: String, to destination: URL) async throws {
        let request = try ElevenLabsAPI.makeSpeechRequest(apiKey: apiKey, voiceID: voiceID, text: phrase)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ElevenLabsTTSError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try data.write(to: destination, options: .atomic)
    }
}
