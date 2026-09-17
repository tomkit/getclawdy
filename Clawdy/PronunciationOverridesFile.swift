//
//  PronunciationOverridesFile.swift
//  Clawdy
//
//  `~/.clawdy/pronunciations.txt` — the user's own "say it this way" list for the built-in
//  voice, one `word: phonemes` per line in Misaki IPA (the alphabet Kokoro speaks). A
//  commented template is installed on first launch, next to the skills and `router.md`,
//  and the file is re-read on every turn so an edit takes effect without a relaunch.
//

import Foundation

enum PronunciationOverridesFile {
    static let fileName = "pronunciations.txt"

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawdy/\(fileName)")
    }

    static let template = """
    # Clawdy pronunciations — teach the built-in voice how to say a word.
    #
    # One per line:   word: phonemes
    # Phonemes are Misaki IPA, the alphabet Kokoro reads (stress marks ˈ and ˌ go before the
    # stressed vowel). To hear what Clawdy would say for a word today, run:
    #   cd Packages/ClawdyVoice && swift run g2pdump "your word"
    # Lines starting with # are ignored. Matching is case-insensitive, whole words only.
    #
    # After a turn, ~/Library/Application Support/Clawdy/debug/last-turn/guessed-words.txt lists the
    # words the voice had to guess — the ones worth an entry here.
    #
    # clawdy: klˈɔdi
    # tomkit: tˈɑmkɪt
    """

    /// Writes the template if the file doesn't exist. Never overwrites.
    static func installTemplateIfMissing(at url: URL = defaultURL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (template + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The overrides currently on disk (empty when the file is missing or unreadable).
    static func load(from url: URL = defaultURL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(contents)
    }

    /// Pure parser: `word: phonemes` (or `word = phonemes`), `#` comments, blank lines skipped.
    static func parse(_ contents: String) -> [String: String] {
        var overrides: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separatorIndex = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let word = line[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let phonemes = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !phonemes.isEmpty else { continue }
            overrides[word] = phonemes
        }
        return overrides
    }
}
