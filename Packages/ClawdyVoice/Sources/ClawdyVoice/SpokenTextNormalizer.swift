//
//  SpokenTextNormalizer.swift
//  ClawdyVoice
//
//  Turns a model reply (markdown, URLs, key chords, times, paths) into the plain spoken
//  words the G2P expects. Misaki already expands numbers, currency, ordinals and percent;
//  this pass only handles what a coding assistant's answer contains that a novel doesn't.
//  Pure and deterministic so every rule is unit-tested.
//

import Foundation

public struct SpokenTextNormalizer: Sendable {
    public init() {}

    /// Keyboard/UI abbreviations the lexicon can't say, spoken as their full names.
    static let abbreviationExpansions: [String: String] = [
        "ctrl": "control", "cmd": "command", "opt": "option", "esc": "escape", "alt": "alt",
        "fn": "function", "pgup": "page up", "pgdn": "page down", "btn": "button",
        "config": "config", "repo": "repo", "readme": "read me", "env": "env",
    ]

    public func normalize(_ text: String) -> String {
        var output = text
        output = Self.stripCodeFences(output)
        output = Self.stripMarkdown(output)
        output = Self.speakURLsAndFileNames(output)
        output = Self.speakTimes(output)
        output = Self.speakKeyChords(output)
        output = Self.speakBreadcrumbs(output)
        output = Self.expandAbbreviations(output)
        output = Self.stripUnspeakableSymbols(output)
        output = Self.collapseWhitespace(output)
        return output
    }

    // MARK: - Rules

    /// ```lang … ``` fences: keep the content, drop the fence markers.
    static func stripCodeFences(_ text: String) -> String {
        text.replacingOccurrences(of: #"```[a-zA-Z0-9_-]*\n?"#, with: " ", options: .regularExpression)
    }

    /// Bold/italic/inline-code markers, headings, list bullets and `[text](url)` links → text.
    static func stripMarkdown(_ text: String) -> String {
        var output = text
        // [label](target) → label, unless the target is Misaki phoneme/stress markup (/…/, #…#, a number).
        output = output.replacingOccurrences(
            of: #"\[([^\]]+)\]\((?!/|#|[+-]?\d)[^)]*\)"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(^|\n)\s{0,3}#{1,6}\s+"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(^|\n)\s*(?:[-*+•]|\d+[.)])\s+"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\*{1,3}([^*\n]+)\*{1,3}"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(^|[\s(])_([^_\n]+)_(?=[\s.,;:!?)]|$)"#, with: "$1$2", options: .regularExpression)
        output = output.replacingOccurrences(of: "`", with: "")
        return output
    }

    /// `https://getclawdy.com/docs` → "getclawdy dot com slash docs"; `report.html` → "report dot html".
    static func speakURLsAndFileNames(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: #"\b(?:https?://|www\.)"#, with: "", options: .regularExpression)
        // A dot between letter/digit runs where the right side is a short alphabetic suffix (TLD or extension).
        output = output.replacingOccurrences(
            of: #"(?<=[A-Za-z0-9])\.(?=[A-Za-z]{2,6}\b)"#, with: " dot ", options: .regularExpression)
        // Slashes inside paths/URLs (no spaces around them) are spoken.
        // (Not inside "(/…/)": that is Misaki pronunciation markup, which must pass through.)
        output = output.replacingOccurrences(of: #"(?<=[^\s(])/(?=[^\s)])"#, with: " slash ", options: .regularExpression)
        output = output.replacingOccurrences(of: "~ slash ", with: "tilde slash ")
        return output
    }

    /// `3:45` → "3 45", `5:05` → "5 oh 5", `12:00` → "12 o'clock" (the colon is a pause to Kokoro).
    static func speakTimes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b(?!:)"#) else { return text }
        let nsText = text as NSString
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let hour = nsText.substring(with: match.range(at: 1))
            let minute = nsText.substring(with: match.range(at: 2))
            let spoken: String
            if minute == "00" {
                spoken = "\(hour) o'clock"
            } else if minute.hasPrefix("0") {
                spoken = "\(hour) oh \(minute.dropFirst())"
            } else {
                spoken = "\(hour) \(minute)"
            }
            output = (output as NSString).replacingCharacters(in: match.range, with: spoken)
        }
        return output
    }

    /// `Ctrl+Option`, `Cmd-Shift-P` → the key names separated by spaces.
    static func speakKeyChords(_ text: String) -> String {
        let keyName = #"(?:ctrl|control|cmd|command|opt|option|alt|shift|fn|esc|escape|tab|enter|return|space|delete|backspace|[A-Za-z0-9]|F\d{1,2}|↑|↓|←|→)"#
        let pattern = #"\b((?:"# + keyName + #")(?:\s?[+\-]\s?"# + keyName + #")+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let nsText = text as NSString
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let chord = nsText.substring(with: match.range)
            let spoken = chord.replacingOccurrences(of: #"\s?[+\-]\s?"#, with: " ", options: .regularExpression)
            output = (output as NSString).replacingCharacters(in: match.range, with: spoken)
        }
        return output
    }

    /// `Settings > Privacy & Security > Screen Recording` → commas (a short pause between steps).
    static func speakBreadcrumbs(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*(?:>|›|→)\s*"#, with: ", ", options: .regularExpression)
    }

    static func expandAbbreviations(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z]+\b"#) else { return text }
        let nsText = text as NSString
        var output = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let word = nsText.substring(with: match.range)
            if let expansion = abbreviationExpansions[word.lowercased()], expansion != word.lowercased() {
                output = (output as NSString).replacingCharacters(in: match.range, with: expansion)
            }
        }
        return output
    }

    /// Emoji, box-drawing, and other symbols the G2P would either drop or spell.
    static func stripUnspeakableSymbols(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmojiModifier { return false }
            if scalar.value == 0xFE0F || scalar.value == 0x200D { return false }   // variation selector, ZWJ
            if (0x2500...0x27BF).contains(scalar.value) && !"→↑↓←".unicodeScalars.contains(scalar) { return false }
            if "|<>{}\\^*#".unicodeScalars.contains(scalar) { return false }
            return true
        }.map(Character.init))
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]*\n+[ \t]*"#, with: ". ", options: .regularExpression)
            .replacingOccurrences(of: #"\.\s*\."#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
