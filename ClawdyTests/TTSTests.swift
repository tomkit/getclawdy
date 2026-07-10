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
}
