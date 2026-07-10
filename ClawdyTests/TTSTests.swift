//
//  TTSTests.swift
//  ClawdyTests
//
//  Headless unit tests for the bring-your-own-key TTS layer: provider
//  selection, the fallback-to-Apple decision, ElevenLabs request construction
//  (URL / headers incl. xi-api-key / JSON body), and voices-response parsing.
//  None of these touch the Keychain or the network — only the pure logic.
//

import Testing
import Foundation
@testable import Clawdy

struct TTSTests {

    // MARK: - Provider selection

    @Test func appleSelectionAlwaysResolvesToApple() {
        #expect(TTSProviderSelection.resolveProviderKind(selectedEngine: .apple, hasUsableElevenLabsKey: false) == .apple)
        #expect(TTSProviderSelection.resolveProviderKind(selectedEngine: .apple, hasUsableElevenLabsKey: true) == .apple)
    }

    @Test func elevenLabsSelectionResolvesToElevenLabsOnlyWithUsableKey() {
        #expect(TTSProviderSelection.resolveProviderKind(selectedEngine: .elevenLabs, hasUsableElevenLabsKey: true) == .elevenLabs)
    }

    @Test func elevenLabsSelectionFallsBackToAppleWithoutKey() {
        #expect(TTSProviderSelection.resolveProviderKind(selectedEngine: .elevenLabs, hasUsableElevenLabsKey: false) == .apple)
    }

    // MARK: - Usable key detection

    @Test func nilOrEmptyOrWhitespaceKeyIsNotUsable() {
        #expect(TTSProviderSelection.isUsableElevenLabsKey(nil) == false)
        #expect(TTSProviderSelection.isUsableElevenLabsKey("") == false)
        #expect(TTSProviderSelection.isUsableElevenLabsKey("   \n\t ") == false)
    }

    @Test func nonEmptyKeyIsUsable() {
        #expect(TTSProviderSelection.isUsableElevenLabsKey("sk_abc123") == true)
    }

    // MARK: - Fallback decision

    @Test func everyElevenLabsErrorFallsBackToApple() {
        #expect(TTSProviderSelection.shouldFallBackToApple(for: ElevenLabsTTSError.missingAPIKey) == true)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: ElevenLabsTTSError.httpStatus(401)) == true)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: ElevenLabsTTSError.httpStatus(429)) == true)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: ElevenLabsTTSError.emptyAudio) == true)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: ElevenLabsTTSError.audioDecodeFailed) == true)
        let networkTimeout = URLError(.timedOut)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: networkTimeout) == true)
    }

    @Test func cancellationDoesNotFallBack() {
        #expect(TTSProviderSelection.shouldFallBackToApple(for: CancellationError()) == false)
    }

    @Test func urlSessionCancellationDoesNotFallBack() {
        // URLSession's async data(for:) surfaces a cancelled Task as
        // URLError(.cancelled), NOT CancellationError. This must also suppress
        // fallback so a re-triggered utterance never overlaps the new one.
        #expect(TTSProviderSelection.shouldFallBackToApple(for: URLError(.cancelled)) == false)
    }

    @Test func nonCancellationURLErrorsStillFallBack() {
        // A genuine network failure (not a cancellation) must still fall back.
        #expect(TTSProviderSelection.shouldFallBackToApple(for: URLError(.notConnectedToInternet)) == true)
        #expect(TTSProviderSelection.shouldFallBackToApple(for: URLError(.timedOut)) == true)
    }

    // MARK: - Speech request construction

    @Test func speechRequestHasCorrectURLMethodAndTimeout() throws {
        let request = try ElevenLabsAPI.makeSpeechRequest(
            apiKey: "sk_secret",
            voiceID: "voice123",
            text: "hello there",
            requestTimeout: 9
        )
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice123/stream")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 9)
    }

    @Test func speechRequestCarriesAPIKeyInXiApiKeyHeader() throws {
        let request = try ElevenLabsAPI.makeSpeechRequest(apiKey: "sk_secret", voiceID: "v", text: "hi")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk_secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
        // The key must NOT be sent as a bearer token.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func speechRequestBodyContainsTextVoiceAndModel() throws {
        let request = try ElevenLabsAPI.makeSpeechRequest(
            apiKey: "sk_secret",
            voiceID: "v",
            text: "speak this",
            modelID: "eleven_turbo_v2_5"
        )
        let bodyData = try #require(request.httpBody)
        let bodyObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let body = try #require(bodyObject)
        #expect(body["text"] as? String == "speak this")
        #expect(body["model_id"] as? String == "eleven_turbo_v2_5")
        let voiceSettings = body["voice_settings"] as? [String: Any]
        #expect(voiceSettings != nil)
    }

    @Test func speechRequestUsesDefaultModelWhenUnspecified() throws {
        let request = try ElevenLabsAPI.makeSpeechRequest(apiKey: "k", voiceID: "v", text: "t")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model_id"] as? String == ElevenLabsAPI.defaultModelID)
    }

    @Test func speechRequestPercentEncodesVoiceIDWithSpacesInsteadOfCrashing() throws {
        // A manually-entered voice id with internal spaces previously force-
        // unwrapped a nil URL and crashed. It must now produce a valid,
        // percent-encoded URL (or throw) — never trap.
        let request = try ElevenLabsAPI.makeSpeechRequest(
            apiKey: "k",
            voiceID: "bad voice id",
            text: "t"
        )
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/bad%20voice%20id/stream")
    }

    // MARK: - Voices request construction

    @Test func voicesRequestHasCorrectURLMethodAndHeader() {
        let request = ElevenLabsAPI.makeVoicesRequest(apiKey: "sk_secret")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/voices")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    // MARK: - Voices response parsing

    @Test func parsesWellFormedVoicesResponse() throws {
        let json = """
        { "voices": [
            { "voice_id": "id1", "name": "Rachel" },
            { "voice_id": "id2", "name": "Domi" }
        ] }
        """.data(using: .utf8)!
        let voices = try ElevenLabsAPI.parseVoices(from: json)
        #expect(voices == [
            ElevenLabsVoice(voiceID: "id1", name: "Rachel"),
            ElevenLabsVoice(voiceID: "id2", name: "Domi")
        ])
    }

    @Test func skipsVoiceEntriesMissingRequiredFields() throws {
        let json = """
        { "voices": [
            { "voice_id": "id1", "name": "Rachel" },
            { "name": "NoID" },
            { "voice_id": "id3" }
        ] }
        """.data(using: .utf8)!
        let voices = try ElevenLabsAPI.parseVoices(from: json)
        #expect(voices == [ElevenLabsVoice(voiceID: "id1", name: "Rachel")])
    }

    @Test func returnsEmptyForMissingVoicesArray() throws {
        let json = "{ \"something_else\": true }".data(using: .utf8)!
        #expect(try ElevenLabsAPI.parseVoices(from: json) == [])
    }

    @Test func throwsForMalformedJSON() {
        let notJSON = "this is not json".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try ElevenLabsAPI.parseVoices(from: notJSON)
        }
    }

    // MARK: - Status helper

    @Test func successStatusClassification() {
        #expect(ElevenLabsAPI.isSuccessStatus(200) == true)
        #expect(ElevenLabsAPI.isSuccessStatus(299) == true)
        #expect(ElevenLabsAPI.isSuccessStatus(401) == false)
        #expect(ElevenLabsAPI.isSuccessStatus(429) == false)
        #expect(ElevenLabsAPI.isSuccessStatus(500) == false)
    }

    // MARK: - with-timestamps request construction

    @Test func withTimestampsRequestHasCorrectURLAndAcceptsJSON() throws {
        let request = try ElevenLabsAPI.makeSpeechWithTimestampsRequest(
            apiKey: "sk_secret",
            voiceID: "voice123",
            text: "hello there",
            requestTimeout: 9
        )
        // The timestamps endpoint is /with-timestamps (NOT /stream) and returns JSON, so
        // Accept must be application/json — never audio/mpeg.
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice123/with-timestamps")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 9)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func withTimestampsRequestDefaultsToFlashModel() throws {
        let request = try ElevenLabsAPI.makeSpeechWithTimestampsRequest(apiKey: "k", voiceID: "v", text: "t")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        // Flash is the default for the timestamps path (verified to return alignment).
        #expect(body["model_id"] as? String == "eleven_flash_v2_5")
        #expect(body["model_id"] as? String == ElevenLabsAPI.timestampPrimaryModelID)
    }

    // MARK: - Model fallback selection (flash -> turbo, never multilingual)

    @Test func timestampModelFallbackChainIsFlashThenTurboOnly() {
        // The chain must be exactly flash -> turbo. A multilingual model must NOT appear:
        // only flash and turbo were verified to return alignment.
        #expect(ElevenLabsAPI.timestampModelFallbackChain == ["eleven_flash_v2_5", "eleven_turbo_v2_5"])
        #expect(!ElevenLabsAPI.timestampModelFallbackChain.contains { $0.contains("multilingual") })
    }

    @Test func nextTimestampModelFallsBackFlashToTurboThenStops() {
        // flash -> turbo -> nil (no multilingual fallback).
        #expect(ElevenLabsAPI.nextTimestampModel(after: "eleven_flash_v2_5") == "eleven_turbo_v2_5")
        #expect(ElevenLabsAPI.nextTimestampModel(after: "eleven_turbo_v2_5") == nil)
        // An unknown model has no successor (never silently jumps into the chain).
        #expect(ElevenLabsAPI.nextTimestampModel(after: "eleven_multilingual_v2") == nil)
    }

    // MARK: - with-timestamps response parsing

    /// A well-formed envelope yields the decoded audio bytes and the `alignment` arrays.
    @Test func parsesWithTimestampsEnvelopeAudioAndAlignment() throws {
        let audioBytes = Data([0x49, 0x44, 0x33, 0x04]) // arbitrary "MP3-ish" bytes
        let audioBase64 = audioBytes.base64EncodedString()
        let json = """
        {
          "audio_base64": "\(audioBase64)",
          "alignment": {
            "characters": ["h", "i"],
            "character_start_times_seconds": [0.0, 0.12],
            "character_end_times_seconds": [0.12, 0.30]
          },
          "normalized_alignment": {
            "characters": ["H", "I"],
            "character_start_times_seconds": [9.0, 9.1],
            "character_end_times_seconds": [9.1, 9.2]
          }
        }
        """.data(using: .utf8)!

        let parsed = try ElevenLabsAPI.parseSpeechWithTimestamps(from: json)
        #expect(parsed.audioData == audioBytes)
        // TRAP 1: we read `alignment` (original text), NOT `normalized_alignment`. If the
        // parser had grabbed the normalized block, the times would be [9.0, 9.1].
        #expect(parsed.alignment.characters == ["h", "i"])
        #expect(parsed.alignment.characterStartTimesSeconds == [0.0, 0.12])
        #expect(parsed.alignment.characterEndTimesSeconds == [0.12, 0.30])
    }

    @Test func withTimestampsParseThrowsWhenAudioMissing() {
        let json = """
        { "alignment": { "characters": ["a"], "character_start_times_seconds": [0.0], "character_end_times_seconds": [0.1] } }
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try ElevenLabsAPI.parseSpeechWithTimestamps(from: json)
        }
    }

    @Test func withTimestampsParseYieldsEmptyAlignmentWhenAlignmentMissing() throws {
        // Audio present but no alignment block → empty alignment (caller degrades to the
        // untimed pointing sequence rather than crashing).
        let audioBase64 = Data([0x01, 0x02]).base64EncodedString()
        let json = "{ \"audio_base64\": \"\(audioBase64)\" }".data(using: .utf8)!
        let parsed = try ElevenLabsAPI.parseSpeechWithTimestamps(from: json)
        #expect(parsed.alignment.isEmpty)
    }
}
