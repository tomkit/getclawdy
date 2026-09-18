//
//  KokoroSynthesizerTests.swift
//  ClawdyVoiceTests
//
//  The model file is git-ignored (scripts/fetch-models.sh downloads it), so the inference
//  tests SKIP when it's absent; the vocabulary, chunker, normalizer and override tests
//  always run.
//

import XCTest
@testable import ClawdyVoice

final class KokoroSynthesizerTests: XCTestCase {
    private static var modelURL: URL {
        // Packages/ClawdyVoice/Tests/ClawdyVoiceTests/<this file> → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Clawdy/Models/kokoro-v1.0.fp16.onnx")
    }

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func testVocabularyMatchesKokoroConfig() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("kokoro-vocab.json"))) as? [String: Int])
        XCTAssertEqual(KokoroVocabulary.tokenIDs.count, json.count)
        for (phoneme, id) in json {
            XCTAssertEqual(KokoroVocabulary.tokenIDs[Character(phoneme)], Int64(id), "token for \(phoneme)")
        }
        XCTAssertEqual(KokoroVocabulary.tokenize("klˈɔdi ɪz ɹˈɛdi."), [53, 54, 156, 76, 46, 51, 16, 102, 68, 16, 123, 156, 86, 46, 51, 4])
    }

    /// Every character the G2P can emit for ordinary English must be in the vocabulary (an
    /// unknown character would be silently dropped from the speech).
    func testG2POutputStaysInsideTheVocabulary() {
        let g2p = EnglishG2P(british: false)
        let corpus = "The quick brown fox jumps over the lazy dog. Really? Yes! It's 4.2 GB — $12.50, 87%; \"quoted\" (parenthetical) hmm… clawdy, xcode, nakamura."
        let phonemes = g2p.phonemize(text: corpus).0
        let unknown = phonemes.filter { KokoroVocabulary.tokenIDs[$0] == nil }
        XCTAssertEqual(unknown, "", "characters outside the Kokoro vocabulary: \(unknown)")
    }

    func testChunkerSplitsLongInputAtSentenceBoundaries() {
        let sentence = "ðˈɪs ɪz ɐ lˈɔŋ sˈɛntəns wɪð mˈɛni fˈOnimz."   // ~44 tokens
        let long = Array(repeating: sentence, count: 20).joined(separator: " ")
        let chunks = PhonemeChunker.split(long, maximumTokens: 510)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(KokoroVocabulary.tokenize(chunk).count, 510)
            XCTAssertTrue(chunk.hasSuffix("."), "chunks end at a sentence boundary: \(chunk.suffix(10))")
        }
        XCTAssertEqual(chunks.map { $0.filter { $0 != " " } }.joined(), long.filter { $0 != " " })
    }

    func testChunkerReturnsShortInputUnchanged() {
        XCTAssertEqual(PhonemeChunker.split("  hˈA. ", maximumTokens: 510), ["hˈA."])
        XCTAssertEqual(PhonemeChunker.split("   ", maximumTokens: 510), [])
    }

    func testPronunciationOverrideMarkup() {
        let overrides = ["clawdy": "klˈɔdi", "tomkit": "tˈɑmkɪt"]
        XCTAssertEqual(PronunciationOverrideMarkup.apply(overrides: overrides, to: "Hey Clawdy, tomkit's here."),
                       "Hey [Clawdy](/klˈɔdi/), [tomkit](/tˈɑmkɪt/)'s here.")
        XCTAssertEqual(PronunciationOverrideMarkup.apply(overrides: [:], to: "unchanged"), "unchanged")
        XCTAssertEqual(PronunciationOverrideMarkup.apply(overrides: ["mm-hm": "əmhˈʌm"], to: "mm-hm. ok"), "[mm-hm](/əmhˈʌm/). ok")
        let g2p = EnglishG2P(british: false)
        XCTAssertEqual(g2p.phonemize(text: PronunciationOverrideMarkup.apply(overrides: ["clawdy": "klˈɔːdi"], to: "clawdy is ready.")).0,
                       "klˈɔːdi ɪz ɹˈɛdi.")
    }

    func testBuiltInPronunciationsFixTheInterjectionsAndUserEntriesWin() async throws {
        let synthesizer = try makeSynthesizer()
        let mmhm = await synthesizer.phonemes(for: "mm-hm.")
        XCTAssertEqual(mmhm, "əmhˈʌm.")
        let hmm = await synthesizer.phonemes(for: "Hmm, okay.")
        XCTAssertEqual(hmm, "hˈʌmm, ˌOkˈA.")
        await synthesizer.setPronunciationOverrides(["clawdy": "klˈɔːdi"])
        let userWins = await synthesizer.phonemes(for: "clawdy")
        XCTAssertEqual(userWins, "klˈɔːdi")
    }

    func testNormalizerRules() {
        let normalizer = SpokenTextNormalizer()
        XCTAssertEqual(normalizer.normalize("Click **Export** then `Save`."), "Click Export then Save.")
        XCTAssertEqual(normalizer.normalize("See https://getclawdy.com/docs for details."), "See getclawdy dot com slash docs for details.")
        XCTAssertEqual(normalizer.normalize("Open report.html in Safari."), "Open report dot html in Safari.")
        XCTAssertEqual(normalizer.normalize("Your meeting is at 3:45 pm, not 5:05 or 12:00."), "Your meeting is at 3 45 pm, not 5 oh 5 or 12 o'clock.")
        XCTAssertEqual(normalizer.normalize("Press Ctrl+Option, then Cmd-Shift-P."), "Press control Option, then command Shift P.")
        XCTAssertEqual(normalizer.normalize("Open Settings > Privacy & Security > Screen Recording."), "Open Settings, Privacy & Security, Screen Recording.")
        XCTAssertEqual(normalizer.normalize("Run `npm install -g @anthropic-ai/claude-code` now."), "Run npm install -g @anthropic-ai slash claude-code now.")
        XCTAssertEqual(normalizer.normalize("- first\n- second\n1. third"), "first. second. third")
        XCTAssertEqual(normalizer.normalize("Done ✅ 🎉 and the [docs](https://x.y) say so."), "Done and the docs say so.")
        XCTAssertEqual(normalizer.normalize("It costs $12.50 (87% off)."), "It costs $12.50 (87% off).")
        // Misaki override markup passes through untouched.
        XCTAssertEqual(normalizer.normalize("[Clawdy](/klˈɔdi/) is here."), "[Clawdy](/klˈɔdi/) is here.")
    }

    // MARK: - Inference (skipped without the model)

    private func makeSynthesizer() throws -> KokoroSynthesizer {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.modelURL.path), "Kokoro model not downloaded (run scripts/fetch-models.sh)")
        return try KokoroSynthesizer(modelURL: Self.modelURL)
    }

    /// The Swift run must reproduce kokoro-onnx's raw output for identical tokens/style/speed.
    /// Sample-for-sample equality is NOT expected: the int8 kernels differ between ONNX
    /// Runtime versions (Python's int8 output only correlates 0.15 sample-wise with its own
    /// fp32 output while sounding identical). The same predicted duration and a ≥0.99
    /// correlation of the 20 ms RMS envelopes is what "the same speech" looks like.
    func testInferenceMatchesKokoroOnnxReference() async throws {
        let synthesizer = try makeSynthesizer()
        let referenceData = try Data(contentsOf: fixtureURL("ref-clawdy-is-ready-raw.f32"))
        var reference = [Float](repeating: 0, count: referenceData.count / 4)
        _ = reference.withUnsafeMutableBytes { referenceData.copyBytes(to: $0) }

        let samples = try await synthesizer.synthesize(phonemes: "klˈɔdi ɪz ɹˈɛdi.", voice: .defaultVoice)
        XCTAssertEqual(samples.count, reference.count, "the duration predictor must agree")

        func envelope(_ signal: [Float], frame: Int = 480) -> [Float] {
            stride(from: 0, to: signal.count - frame, by: frame).map { start in
                sqrt(signal[start..<(start + frame)].map { $0 * $0 }.reduce(0, +) / Float(frame))
            }
        }
        func correlation(_ left: [Float], _ right: [Float]) -> Float {
            let count = Float(min(left.count, right.count))
            let meanLeft = left.reduce(0, +) / count, meanRight = right.reduce(0, +) / count
            var covariance: Float = 0, varianceLeft: Float = 0, varianceRight: Float = 0
            for (l, r) in zip(left, right) {
                covariance += (l - meanLeft) * (r - meanRight)
                varianceLeft += (l - meanLeft) * (l - meanLeft)
                varianceRight += (r - meanRight) * (r - meanRight)
            }
            return covariance / (varianceLeft * varianceRight).squareRoot()
        }
        let envelopeCorrelation = correlation(envelope(samples), envelope(reference))
        XCTAssertGreaterThan(envelopeCorrelation, 0.99, "envelope correlation with the Python reference: \(envelopeCorrelation)")
    }

    func testGuessedWordsAreTheOnesTheLexiconDidNotKnow() async throws {
        let synthesizer = try makeSynthesizer()
        let guessed = await synthesizer.guessedWords(in: "Open Xcode and ask Nakamura about the formula, then ping tomkit.")
        XCTAssertEqual(guessed, ["Xcode", "tomkit"], "Nakamura is read as romaji, not guessed")
        let none = await synthesizer.guessedWords(in: "The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(none, [])
        // Built-in and user overrides are not guesses.
        let overridden = await synthesizer.guessedWords(in: "hey clawdy")
        XCTAssertEqual(overridden, [])
    }

    func testTextToSpeechProducesAudioOfPlausibleLength() async throws {
        let synthesizer = try makeSynthesizer()
        let samples = try await synthesizer.synthesize(text: "Hey, I'm Clawdy. Ask me anything on your screen.", voice: .defaultVoice)
        let seconds = Double(samples.count) / KokoroSynthesizer.sampleRate
        XCTAssertGreaterThan(seconds, 2)
        XCTAssertLessThan(seconds, 6)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05)
    }

    func testEveryBundledVoiceLoads() async throws {
        let synthesizer = try makeSynthesizer()
        for voice in KokoroVoice.bundled {
            let samples = try await synthesizer.synthesize(phonemes: "hˈA.", voice: voice)
            XCTAssertFalse(samples.isEmpty, voice.id)
        }
    }
}
