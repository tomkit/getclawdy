//
//  SentenceStreamBuffer.swift
//  Clawdy
//
//  Pure, testable buffering that turns the progressively-growing response text
//  (delivered as an ever-longer accumulated string) into COMPLETE sentences the
//  TTS layer can start speaking before the whole reply has arrived. This is what
//  lets Clawdy speak sentence one while the model is still writing sentence two,
//  cutting the long silent gap between the model finishing and audio starting.
//
//  Two guarantees, both important:
//   - A trailing `[POINT:x,y:label]` tag (which only ever appears at the very end)
//     is never spoken — even while it's still arriving character-by-character.
//   - Each chunk of text is handed to TTS exactly once: `consumeAccumulatedText`
//     returns only newly-completed sentences, and `consumeFinalText` returns only
//     whatever is still unspoken once the authoritative final text is known.
//

import Foundation

/// Stateful across one response: feed it the accumulated text on each delta and
/// it returns the sentences that have newly completed. Not thread-safe by design
/// — drive it from a single actor/queue (CompanionManager uses it on @MainActor).
final class SentenceStreamBuffer {
    /// Number of CHARACTERS of the cleaned (point-tag-stripped) spoken text that
    /// have already been handed out. Counts Characters, matching the Substring
    /// arithmetic below so indices never drift.
    private var spokenCharacterCount = 0

    /// Given the full accumulated response text so far, returns any sentences that
    /// have newly completed since the last call (point tag stripped). A sentence is
    /// considered complete only when its terminator (`.`/`!`/`?`/newline) is
    /// followed by whitespace — so a sentence still being written, or a half-typed
    /// point tag at the tail, is held back until more text confirms it.
    func consumeAccumulatedText(_ accumulatedText: String) -> [String] {
        let cleanedText = Self.strippingPointTag(from: accumulatedText)
        guard cleanedText.count > spokenCharacterCount else { return [] }

        let unspokenText = String(cleanedText.dropFirst(spokenCharacterCount))
        guard let boundaryCharacterOffset = Self.confirmedSentenceBoundaryOffset(in: unspokenText) else {
            return []
        }

        let readyText = String(unspokenText.prefix(boundaryCharacterOffset))
        spokenCharacterCount += boundaryCharacterOffset
        return Self.splitIntoNonEmptySentences(readyText)
    }

    /// Returns the text still unspoken once the authoritative final response is
    /// known — the last sentence (which often has no trailing space to confirm it
    /// mid-stream), point tag stripped. Returns nil if everything was already
    /// spoken. Advances the cursor so a second call returns nil.
    func consumeFinalText(_ finalText: String) -> String? {
        let cleanedText = Self.strippingPointTag(from: finalText)
        guard cleanedText.count > spokenCharacterCount else { return nil }

        let remainingText = String(cleanedText.dropFirst(spokenCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        spokenCharacterCount = cleanedText.count
        return remainingText.isEmpty ? nil : remainingText
    }

    // MARK: - Pure helpers (static so they're independently unit-testable)

    /// Removes a `[POINT:...]` tag so it is never spoken. Handles both the
    /// complete tag at the end and a tag that is still arriving (a trailing
    /// fragment that is the start of, or an unclosed, `[POINT:` tag) so streamed
    /// TTS never speaks a partial tag.
    static func strippingPointTag(from text: String) -> String {
        // A complete trailing tag: [POINT:anything-without-a-closing-bracket]
        if let completeTagRange = text.range(
            of: #"\[POINT:[^\]]*\]\s*$"#,
            options: .regularExpression
        ) {
            return String(text[..<completeTagRange.lowerBound])
        }

        // An in-progress tag at the very end: from the last '[', if that tail is
        // either a prefix of "[POINT:" (e.g. "[", "[PO") or an unclosed
        // "[POINT:..." being typed, drop it so it's withheld until complete.
        if let lastOpeningBracketIndex = text.lastIndex(of: "[") {
            let trailingFragment = text[lastOpeningBracketIndex...]
            if "[POINT:".hasPrefix(trailingFragment) || trailingFragment.hasPrefix("[POINT:") {
                return String(text[..<lastOpeningBracketIndex])
            }
        }

        return text
    }

    /// Returns the character offset just past the last CONFIRMED sentence
    /// terminator in `text` — a `.`/`!`/`?`/newline immediately followed by
    /// whitespace. Returns nil when no sentence has confirmably completed yet.
    /// Requiring a following whitespace (not end-of-string) avoids speaking a
    /// sentence that the model may still be extending and sidesteps decimals like
    /// "version 3.5" where the period is followed by a digit, not a space.
    static func confirmedSentenceBoundaryOffset(in text: String) -> Int? {
        let characters = Array(text)
        var lastBoundaryOffset: Int? = nil
        for characterIndex in characters.indices {
            let character = characters[characterIndex]
            let isTerminator = character == "." || character == "!" || character == "?" || character == "\n"
            guard isTerminator else { continue }
            let nextIndex = characterIndex + 1
            guard nextIndex < characters.count else { continue } // unconfirmed: nothing after it yet
            if characters[nextIndex].isWhitespace {
                lastBoundaryOffset = nextIndex
            }
        }
        return lastBoundaryOffset
    }

    /// Splits a run of one or more completed sentences into individual trimmed,
    /// non-empty sentences. Speaking them separately lets a native synthesizer
    /// breathe between them; the exact split is cosmetic, so a simple
    /// terminator-aware scan is enough.
    static func splitIntoNonEmptySentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { sentences.append(trailing) }
        return sentences
    }
}
