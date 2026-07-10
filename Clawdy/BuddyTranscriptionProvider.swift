//
//  BuddyTranscriptionProvider.swift
//  Clawdy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// Clawdy transcribes entirely on-device with Apple's Speech framework — free
    /// and local, no API keys or cloud round-trips. (The original app supported
    /// AssemblyAI and OpenAI cloud STT; those metered backends were removed.)
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
