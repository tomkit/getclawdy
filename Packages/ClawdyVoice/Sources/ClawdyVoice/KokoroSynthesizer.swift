//
//  KokoroSynthesizer.swift
//  ClawdyVoice
//
//  Text → speech samples with Kokoro-82M (ONNX Runtime, CPU) and the Misaki G2P, entirely
//  on-device. One instance owns the ORT session, the G2P and the loaded voices; it is an
//  actor because a run takes ~0.2× real time (about 0.6 s for a 3 s sentence) and must
//  never block the main thread.
//
//  Pipeline for one sentence: `SpokenTextNormalizer` (markdown/URLs/times → speakable
//  words) → pronunciation overrides (`[word](/phonemes/)` markup) → `EnglishG2P.phonemize`
//  → `KokoroVocabulary.tokenize` → the model (`tokens` [1, n+2] int64 with a 0 pad on each
//  end, `style` = row min(n, 510)−1 of the voice, `speed` [1]) → float32 mono at 24 kHz.
//  Inputs longer than 510 tokens are split at sentence/clause boundaries and concatenated.
//

import Foundation
import OnnxRuntimeBindings

public struct KokoroVoice: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// The voices bundled with the package, best-graded first (Kokoro's own quality grades).
    public static let bundled: [KokoroVoice] = [
        KokoroVoice(id: "af_heart", displayName: "Heart"),
        KokoroVoice(id: "af_bella", displayName: "Bella"),
        KokoroVoice(id: "am_fenrir", displayName: "Fenrir"),
        KokoroVoice(id: "am_michael", displayName: "Michael"),
        KokoroVoice(id: "bf_emma", displayName: "Emma"),
        KokoroVoice(id: "bm_george", displayName: "George"),
    ]
    public static let defaultVoice = bundled[0]
}

public enum KokoroSynthesizerError: Error {
    case modelFileMissing(URL)
    case voiceMissing(String)
    case emptyInput
    case modelProducedNoAudio
}

public actor KokoroSynthesizer {
    public static let sampleRate: Double = 24_000
    /// Rows × columns of one voice blob (`voices-v1.0.bin` entry flattened to float32).
    static let styleRows = 510
    static let styleWidth = 256

    private let session: ORTSession
    private let environment: ORTEnv
    private let g2p: EnglishG2P
    private var loadedVoices: [String: [Float]] = [:]
    private let normalizer = SpokenTextNormalizer()

    /// Words the user wants said a specific way (`~/.clawdy/pronunciations.txt`), lowercase
    /// word → Misaki phonemes. Applied before the G2P as `[word](/phonemes/)` markup, on top
    /// of `builtInPronunciations` (a user entry for the same word wins).
    public var pronunciationOverrides: [String: String] = [:]

    /// Pronunciations the lexicon gets wrong for words Clawdy itself says. Interjections are
    /// the notable gap: misaki spells "mm-hm" as `mhm` (no vowel), which the model renders as
    /// a broken "meh"; the dictionary transcription /əmˈhʌm/ is what a person says.
    public static let builtInPronunciations: [String: String] = [
        "mm-hm": "əmhˈʌm",
        "mmhm": "əmhˈʌm",
        "mm-hmm": "əmhˈʌm",
        "uh-huh": "ʌhˈʌ",
        "hmm": "hˈʌmm",
        "hm": "hˈʌmm",
        "clawdy": "klˈɔdi",
    ]

    /// Loads the ONNX model at `modelURL` (the app bundles it; tests point at a downloaded copy).
    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw KokoroSynthesizerError.modelFileMissing(modelURL)
        }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        // A handful of threads is the sweet spot: the graph is small and more threads add
        // scheduling overhead without cutting latency.
        try options.setIntraOpNumThreads(Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
        session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
        g2p = EnglishG2P(british: false)
    }

    public func setPronunciationOverrides(_ overrides: [String: String]) {
        pronunciationOverrides = overrides
    }

    /// Runs one short inference so the first real request pays no first-run cost.
    public func prewarm() {
        _ = try? synthesize(phonemes: "hˈA.", voice: KokoroVoice.defaultVoice, speed: 1.0)
    }

    /// The phonemes Kokoro will be fed for `text` (exposed for tests and tooling).
    public func phonemes(for text: String) -> String {
        let spoken = normalizer.normalize(text)
        let overrides = Self.builtInPronunciations.merging(pronunciationOverrides) { _, userEntry in userEntry }
        let marked = PronunciationOverrideMarkup.apply(overrides: overrides, to: spoken)
        return g2p.phonemize(text: marked).0
    }

    /// Speaks `text` in `voice`; returns mono float32 samples at 24 kHz.
    public func synthesize(text: String, voice: KokoroVoice, speed: Float = 1.0) throws -> [Float] {
        let phonemes = phonemes(for: text)
        return try synthesize(phonemes: phonemes, voice: voice, speed: speed)
    }

    /// Synthesizes already-phonemized input, splitting anything over the model's token limit.
    public func synthesize(phonemes: String, voice: KokoroVoice, speed: Float = 1.0) throws -> [Float] {
        let chunks = PhonemeChunker.split(phonemes, maximumTokens: KokoroVocabulary.maximumTokensPerRun)
        guard !chunks.isEmpty else { throw KokoroSynthesizerError.emptyInput }
        let style = try loadVoice(voice)
        var samples: [Float] = []
        for chunk in chunks {
            // A cancelled caller (the user spoke again) stops paying for chunks it will never
            // play; one ORT run can't be interrupted, so at most one chunk of work is wasted.
            try Task.checkCancellation()
            let tokens = KokoroVocabulary.tokenize(chunk)
            guard !tokens.isEmpty else { continue }
            samples += try run(tokens: tokens, style: style, speed: speed)
        }
        guard !samples.isEmpty else { throw KokoroSynthesizerError.modelProducedNoAudio }
        return samples
    }

    // MARK: - Model I/O

    private func loadVoice(_ voice: KokoroVoice) throws -> [Float] {
        if let cached = loadedVoices[voice.id] { return cached }
        guard let url = Bundle.module.url(forResource: voice.id, withExtension: "bin", subdirectory: "Resources/voices") else {
            throw KokoroSynthesizerError.voiceMissing(voice.id)
        }
        let data = try Data(contentsOf: url)
        let expectedCount = Self.styleRows * Self.styleWidth
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            throw KokoroSynthesizerError.voiceMissing(voice.id)
        }
        var values = [Float](repeating: 0, count: expectedCount)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        loadedVoices[voice.id] = values
        return values
    }

    func run(tokens: [Int64], style: [Float], speed: Float) throws -> [Float] {
        // The style row is chosen by the number of phoneme tokens (before padding).
        let styleRow = min(tokens.count, Self.styleRows) - 1
        let styleValues = Array(style[(styleRow * Self.styleWidth)..<((styleRow + 1) * Self.styleWidth)])
        let paddedTokens: [Int64] = [0] + tokens + [0]

        let tokensValue = try ORTValue(
            tensorData: NSMutableData(data: paddedTokens.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .int64,
            shape: [1, NSNumber(value: paddedTokens.count)]
        )
        let styleValue = try ORTValue(
            tensorData: NSMutableData(data: styleValues.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .float,
            shape: [1, NSNumber(value: Self.styleWidth)]
        )
        let speedValue = try ORTValue(
            tensorData: NSMutableData(data: [speed].withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .float,
            shape: [1]
        )
        let outputs = try session.run(
            withInputs: ["tokens": tokensValue, "style": styleValue, "speed": speedValue],
            outputNames: ["audio"],
            runOptions: nil
        )
        guard let audioValue = outputs["audio"] else { throw KokoroSynthesizerError.modelProducedNoAudio }
        let audioData = try audioValue.tensorData() as Data
        var samples = [Float](repeating: 0, count: audioData.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { audioData.copyBytes(to: $0) }
        return samples
    }
}

/// Splits a phoneme string into runs of at most `maximumTokens` vocabulary tokens, cutting
/// at sentence ends first, then clause punctuation, then spaces, then hard.
enum PhonemeChunker {
    static func split(_ phonemes: String, maximumTokens: Int) -> [String] {
        let trimmed = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if KokoroVocabulary.tokenize(trimmed).count <= maximumTokens { return [trimmed] }

        for separators in [Set<Character>(".!?"), Set<Character>(";:,—"), Set<Character>(" ")] {
            var pieces: [String] = []
            var current = ""
            for character in trimmed {
                current.append(character)
                if separators.contains(character) {
                    pieces.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { pieces.append(current) }
            guard pieces.count > 1 else { continue }

            // Greedily pack pieces into runs under the limit.
            var runs: [String] = []
            var run = ""
            for piece in pieces {
                let candidate = run + piece
                if KokoroVocabulary.tokenize(candidate).count > maximumTokens, !run.isEmpty {
                    runs.append(run.trimmingCharacters(in: .whitespaces))
                    run = piece
                } else {
                    run = candidate
                }
            }
            if !run.isEmpty { runs.append(run.trimmingCharacters(in: .whitespaces)) }
            if runs.allSatisfy({ KokoroVocabulary.tokenize($0).count <= maximumTokens }) {
                return runs.filter { !$0.isEmpty }
            }
        }

        // Hard split by token count as the last resort.
        var runs: [String] = []
        var run = ""
        for character in trimmed {
            if KokoroVocabulary.tokenIDs[character] != nil, KokoroVocabulary.tokenize(run).count >= maximumTokens {
                runs.append(run)
                run = ""
            }
            run.append(character)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}

/// Wraps overridden words in Misaki's `[word](/phonemes/)` markup so the G2P uses the given
/// pronunciation verbatim. Matching is whole-word and case-insensitive; a possessive or
/// plural "'s"/"s" after the word is left for the G2P to handle as usual.
public enum PronunciationOverrideMarkup {
    public static func apply(overrides: [String: String], to text: String) -> String {
        guard !overrides.isEmpty else { return text }
        var output = ""
        var currentWord = ""
        func flushWord() {
            guard !currentWord.isEmpty else { return }
            let lowercased = currentWord.lowercased()
            if let phonemes = overrides[lowercased] {
                output += "[\(currentWord)](/\(phonemes)/)"
            } else if lowercased.hasSuffix("'s"), let phonemes = overrides[String(lowercased.dropLast(2))] {
                // Possessive: override the base word, leave the "'s" to the G2P.
                output += "[\(currentWord.dropLast(2))](/\(phonemes)/)'s"
            } else {
                output += currentWord
            }
            currentWord = ""
        }
        for character in text {
            // A hyphen INSIDE a word ("mm-hm", "well-known") keeps the compound one key.
            let isInnerHyphen = character == "-" && !currentWord.isEmpty
            if character.isLetter || character.isNumber || character == "'" || isInnerHyphen {
                currentWord.append(character)
            } else {
                flushWord()
                output.append(character)
            }
        }
        flushWord()
        return output
    }
}
