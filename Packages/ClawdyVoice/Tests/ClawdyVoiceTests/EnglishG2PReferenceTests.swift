//
//  EnglishG2PReferenceTests.swift
//  ClawdyVoiceTests
//
//  Pins the vendored G2P against references produced by the upstream Python `misaki`
//  (lexicon path, `g2p-reference.tsv`) and by Hugging Face `transformers` running the
//  SAME `us_bart.safetensors` (fallback network, `bart-reference.tsv` + the numeric
//  encoder/logit dump). Regenerate the fixtures with the scripts noted in each file if
//  the lexicon or weights are ever updated.
//

import XCTest
@testable import ClawdyVoice

final class EnglishG2PReferenceTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The BART port must reproduce transformers' greedy decode for every reference word.
    func testFallbackNetworkMatchesTransformersReference() throws {
        let network = EnglishFallbackNetwork(british: false)
        var mismatches: [String] = []
        for line in try fixture("bart-reference.tsv").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let produced = network.phonemes(forWord: parts[0])
            if produced != parts[1] { mismatches.append("\(parts[0]): expected \(parts[1]) got \(produced)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Numeric check of the forward pass (encoder row 0 + first-step logits for "clawdy").
    func testFallbackNetworkNumericsMatchTransformers() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture("bart-numeric-reference.json").utf8)) as? [String: [Double]])
        let expectedEncoderRow = try XCTUnwrap(json["encoder_row0"]).map(Float.init)
        let expectedLogits = try XCTUnwrap(json["first_logits"]).map(Float.init)

        let config = try EnglishFallbackNetwork.loadConfig()
        let model = try BARTModel(config: config, weights: try EnglishFallbackNetwork.loadWeights())
        var graphemeToToken: [Character: Int] = [:]
        for (index, grapheme) in config.graphemeChars.enumerated() { graphemeToToken[grapheme] = index }
        let inputTokenIDs = [config.bosTokenId] + "clawdy".map { graphemeToToken[$0]! } + [config.eosTokenId]

        let encoderOutput = model.encode(tokenIDs: inputTokenIDs)
        let encoderRow = Array(encoderOutput.row(0))
        let logits = Array(model.decode(decoderTokenIDs: [config.bosTokenId], encoderOutput: encoderOutput).row(0))

        func maxAbsDiff(_ left: [Float], _ right: [Float]) -> Float { zip(left, right).map { abs($0 - $1) }.max() ?? .infinity }
        XCTAssertLessThan(maxAbsDiff(encoderRow, expectedEncoderRow), 1e-4)
        XCTAssertLessThan(maxAbsDiff(logits, expectedLogits), 1e-3)
    }

    /// Every lexicon-covered reference line must phonemize like Python misaki. Lines with "❓"
    /// in the reference (an OOV word, which the Python run had no fallback for) are skipped.
    /// The comparison ignores STRESS MARKS and straight-vs-curly quotes: the port tags parts
    /// of speech with NLTagger instead of spaCy, which shifts the stress choice on a few
    /// function words ("there", "that") without changing the phonemes themselves.
    func testLexiconPathMatchesPythonMisaki() throws {
        let g2p = EnglishG2P(british: false)
        func comparable(_ phonemes: String) -> String {
            phonemes.replacingOccurrences(of: "ˈ", with: "").replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        }
        var mismatches: [String] = []
        for line in try fixture("g2p-reference.tsv").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            guard !parts[1].contains("❓") else { continue }
            let (produced, _) = g2p.phonemize(text: parts[0])
            if comparable(produced) != comparable(parts[1]) { mismatches.append("\(parts[0])\n  expected \(parts[1])\n  got      \(produced)") }
        }
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    /// The port bugs fixed while vendoring (each was silent or wrong in MisakiSwift 1.0.1):
    /// decimals read as dotted abbreviations, "twenty" missing from num2words, currency
    /// detached from decimal amounts, "%" swallowed as punctuation, intra-word hyphens
    /// spoken as a dash, and a stray space after a numeric suffix.
    func testNumberAndSymbolFixes() {
        let g2p = EnglishG2P(british: false)
        func phonemes(_ text: String) -> String { g2p.phonemize(text: text).0 }
        XCTAssertEqual(phonemes("4.2"), "fˈɔɹ pYnt tˈu")
        XCTAssertEqual(phonemes("1,024"), "wˈʌn θˈWzᵊnd twˈɛnti fˈɔɹ")
        XCTAssertEqual(phonemes("$12.50"), "twˈɛlv dˈɑləɹz ænd fˈɪfti sˈɛnts")
        XCTAssertEqual(phonemes("87%"), "ˈATi sˈɛvən pəɹsˈɛnt")
        XCTAssertEqual(phonemes("Wi-Fi"), "wˈIfˌI")
        XCTAssertEqual(phonemes("mm-hm."), "mhm.")
        XCTAssertEqual(phonemes("the 2nd one"), "ðə sˈɛkənd wˈʌn")
        // A lowercase sentence start used to glue the period onto the previous word.
        XCTAssertEqual(phonemes("i'm clawdy. ask me"), "ˌIm klˈɔdi. ˈæsk mˌi")
        XCTAssertEqual(phonemes("e.g. this"), "ˌiʤˈi ðɪs")
        // The fallback network is fed lowercase unless the word is an acronym.
        XCTAssertEqual(phonemes("Xcode"), "ˈɛksˌOd")
    }

    func testOutOfVocabularyWordsFallBackToTheNetworkInsteadOfUnknownMarker() {
        let g2p = EnglishG2P(british: false)
        let (phonemes, _) = g2p.phonemize(text: "clawdy is ready.")
        XCTAssertEqual(phonemes, "klˈɔdi ɪz ɹˈɛdi.")
    }
}

final class RomajiPronunciationTests: XCTestCase {
    /// Japanese words in Hepburn romaji get a rule-based reading (penultimate stress),
    /// instead of the English fallback network's guess.
    func testRomajiWordsAreReadBySyllable() {
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Aomori"), "ɑOmˈOɹi")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Shibuya"), "ʃibˈujɑ")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Nebuta"), "nɛbˈutɑ")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Nakamura"), "nɑkɑmˈuɹɑ")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Shinjuku"), "ʃinʤˈuku")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Nihon"), "nˈihOn")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Sapporo"), "sɑpˈOɹO")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Kannami"), "kɑnnˈɑmi")
        XCTAssertEqual(RomajiPronunciation.phonemes(for: "Ryokan"), "ɹjˈOkɑn")
    }

    /// English spellings that don't parse as romaji are left to the network.
    func testNonRomajiWordsAreNotClaimed() {
        for word in ["clawdy", "tomkit", "Xcode", "Vercel", "Figma", "Szymanski", "Okonkwo", "ab"] {
            XCTAssertNil(RomajiPronunciation.phonemes(for: word), word)
        }
    }

    func testG2PUsesTheRomajiReadingForUnknownJapaneseWordsOnly() {
        let g2p = EnglishG2P(british: false)
        let (phonemes, tokens) = g2p.phonemize(text: "Aomori and Tokyo, then clawdy.")
        XCTAssertEqual(phonemes, "ɑOmˈOɹi ænd tˈOkiˌO, ðˈɛn klˈɔdi.")
        XCTAssertEqual(tokens.first?._.rating, EnglishG2P.romajiRating)
        XCTAssertEqual(tokens.last { $0.text == "clawdy" }?._.rating, EnglishFallbackNetwork.fallbackRating)
    }
}
