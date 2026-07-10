//
//  ElevenLabsAPI.swift
//  Clawdy
//
//  Pure, testable construction of the HTTP requests Clawdy sends DIRECTLY to
//  the ElevenLabs API (no proxy, no Cloudflare Worker) and parsing of the
//  /v1/voices response. Keeping URL/header/body construction and response
//  decoding out of the networking client means they can be unit-tested
//  headlessly without touching the network.
//

import Foundation

/// A voice available on the user's ElevenLabs account, as surfaced by the
/// settings voice picker.
struct ElevenLabsVoice: Equatable, Identifiable {
    /// ElevenLabs voice id (e.g. "21m00Tcm4TlvDq8ikWAM"). Used as `id`.
    let voiceID: String
    /// Human-readable name shown in the picker (e.g. "Rachel").
    let name: String

    var id: String { voiceID }
}

/// Errors surfaced by the ElevenLabs networking client. Every case is treated
/// as a reason to silently fall back to Apple TTS (see
/// `TTSProviderSelection.shouldFallBackToApple`).
enum ElevenLabsTTSError: LocalizedError, Equatable {
    /// No usable API key was configured.
    case missingAPIKey
    /// The voice id couldn't form a valid request URL (e.g. it contained
    /// characters that can't appear in a URL path even after encoding).
    case invalidVoiceID
    /// The server returned a non-2xx status (e.g. 401 invalid key, 429 rate
    /// limited, 5xx outage).
    case httpStatus(Int)
    /// The response body contained no audio data.
    case emptyAudio
    /// The audio data couldn't be decoded into a playable sound.
    case audioDecodeFailed
    /// The decoded audio failed to start playing.
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No ElevenLabs API key is configured."
        case .invalidVoiceID:
            return "The selected ElevenLabs voice id is not valid."
        case .httpStatus(let statusCode):
            return "ElevenLabs returned HTTP status \(statusCode)."
        case .emptyAudio:
            return "ElevenLabs returned no audio."
        case .audioDecodeFailed:
            return "Couldn't decode the audio ElevenLabs returned."
        case .playbackFailed:
            return "Couldn't start playing the audio ElevenLabs returned."
        }
    }
}

/// Pure factory + parser for ElevenLabs HTTP calls.
enum ElevenLabsAPI {
    /// Base URL for the public ElevenLabs API.
    static let baseURLString = "https://api.elevenlabs.io"

    /// Default voice id ("Rachel"), a stock ElevenLabs voice every account has.
    /// Used until the user picks one of their own voices.
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    /// Flash model — ElevenLabs' lowest-latency model (~75ms time-to-first-byte),
    /// which matters because the reply is spoken right after generation. Combined
    /// with the streaming endpoint below this minimizes the silent gap before the
    /// user hears the first audio.
    static let defaultModelID = "eleven_flash_v2_5"

    /// HTTP header name carrying the user's API key. NOT a bearer token —
    /// ElevenLabs uses a custom `xi-api-key` header.
    static let apiKeyHeaderName = "xi-api-key"

    /// Builds the POST text-to-speech request for `text` in `voiceID`.
    ///
    /// Endpoint: `POST {base}/v1/text-to-speech/{voice_id}/stream` with the key in
    /// the `xi-api-key` header, JSON body, and `Accept: audio/mpeg` so the response
    /// is MP3 audio. The `/stream` endpoint emits audio as soon as the model starts
    /// generating (lower time-to-first-byte than the buffered endpoint), which —
    /// paired with the flash model — gets spoken audio back faster. `requestTimeout`
    /// bounds the whole request so a stalled network can't hang the voice flow.
    static func makeSpeechRequest(
        apiKey: String,
        voiceID: String,
        text: String,
        modelID: String = defaultModelID,
        requestTimeout: TimeInterval = 12
    ) throws -> URLRequest {
        // Percent-encode the voice id as a single path segment so a manually
        // entered id containing spaces or other path-unsafe characters can't
        // produce a nil URL (which a force-unwrap would crash on). If it still
        // can't form a valid URL, throw so the caller falls back to Apple TTS.
        let encodedVoiceID = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        guard let encodedVoiceID,
              let url = URL(string: "\(baseURLString)/v1/text-to-speech/\(encodedVoiceID)/stream") else {
            throw ElevenLabsTTSError.invalidVoiceID
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let requestBody: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        return request
    }

    /// Builds the GET request that lists the voices on the user's account.
    ///
    /// Endpoint: `GET {base}/v1/voices` with the key in the `xi-api-key` header.
    static func makeVoicesRequest(
        apiKey: String,
        requestTimeout: TimeInterval = 12
    ) -> URLRequest {
        let url = URL(string: "\(baseURLString)/v1/voices")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parses the `/v1/voices` JSON response into `ElevenLabsVoice` values.
    ///
    /// The response shape is `{ "voices": [ { "voice_id": ..., "name": ... } ] }`.
    /// Entries missing either field are skipped rather than failing the whole
    /// parse, so one malformed voice doesn't break the picker.
    static func parseVoices(from data: Data) throws -> [ElevenLabsVoice] {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let topLevelDictionary = jsonObject as? [String: Any],
              let voicesArray = topLevelDictionary["voices"] as? [[String: Any]] else {
            return []
        }
        return voicesArray.compactMap { voiceDictionary in
            guard let voiceID = voiceDictionary["voice_id"] as? String,
                  let name = voiceDictionary["name"] as? String else {
                return nil
            }
            return ElevenLabsVoice(voiceID: voiceID, name: name)
        }
    }

    /// Whether an HTTP status code counts as success (2xx).
    static func isSuccessStatus(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }
}
