import Foundation

/// Decodes one line of NDJSON / JSONL into a JSON object dictionary.
///
/// This is the single shared implementation of the `trim → require non-empty →
/// UTF-8 encode → parse as a top-level JSON object` pattern that several stream
/// parsers (`ClaudeStreamEvent`, `ResearchStreamParser`, `CodexEngine`'s agent
/// message parser, and `TranscriptParser`) each open their line handling with.
///
/// Semantics (preserved byte-for-byte from those call sites):
/// - Leading/trailing whitespace AND newline characters are trimmed first.
/// - A blank line (empty after trimming) returns `nil`.
/// - A line that is not valid UTF-8 returns `nil`.
/// - A line whose top-level JSON value is not an object (e.g. a bare array,
///   number, string, or `null`) returns `nil`.
/// - Otherwise the decoded `[String: Any]` object is returned. Callers layer
///   their own field lookups (`type`, `result`, …) on top of this.
func decodeJSONLine(_ line: String) -> [String: Any]? {
    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLine.isEmpty,
          let lineData = trimmedLine.data(using: .utf8),
          let jsonObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
        return nil
    }
    return jsonObject
}
