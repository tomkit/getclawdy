//
//  FollowUpDirective.swift
//  Clawdy
//
//  Pure parsing for the ROUTER directive the warm Clawdy agent emits when a
//  research session is FOCUSED and the user's spoken prompt is a genuine
//  continuation of that session's page — a question ABOUT it or an ask to ITERATE
//  on it — rather than a pointing question or a quick standalone answer.
//
//  This mirrors `[RESEARCH]` exactly, but for the lineage/continue-thread case:
//  the warm agent stays the router. On a focused turn it either
//    - answers a quick question inline (spoken), or
//    - points at an on-screen element with a [POINT:...] tag (pointing questions
//      are ALWAYS a quick POINT answer, NEVER a follow-up — the sacred rule), or
//    - emits a single structured directive
//
//          [FOLLOWUP] <one-line restatement>
//
//      as its ENTIRE reply, which the app routes to the focused session's own
//      `claude` thread (`followUpOnFocusedSession`) instead of speaking it.
//
//  Keeping this a SEPARATE marker from `[RESEARCH]` means a focused turn can still
//  spawn a brand-new research run (`[RESEARCH]`) for an unrelated topic, while a
//  continuation of the open page routes to the follow-up thread (`[FOLLOWUP]`).
//
//  Everything here is side-effect-free and unit-testable.
//

import Foundation

enum FollowUpDirective {
    /// The marker the warm router agent emits at the very start of its reply when a
    /// session is focused and the prompt is a continuation of that session's page.
    static let tag = "[FOLLOWUP]"

    /// Outcome of inspecting the warm agent's full reply for a follow-up directive.
    struct ParseResult: Equatable {
        /// True when the reply is a follow-up directive (routes to the focused
        /// session's own thread) rather than a normal spoken answer / POINT.
        let isFollowUpRequest: Bool
        /// The one-line restatement the agent wrote after the marker, trimmed. Nil
        /// when this isn't a follow-up directive, or the marker had no text after it.
        let promptText: String?
    }

    /// Parses the warm agent's full reply. A follow-up directive is the ENTIRE
    /// reply: it must START with `[FOLLOWUP]` (the router emits nothing else — no
    /// spoken text, no POINT tag). Anything that merely mentions the marker
    /// mid-sentence is a normal spoken answer, not a route.
    static func parse(from responseText: String) -> ParseResult {
        let trimmedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReply.hasPrefix(tag) else {
            return ParseResult(isFollowUpRequest: false, promptText: nil)
        }
        let promptText = String(trimmedReply.dropFirst(tag.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(
            isFollowUpRequest: true,
            promptText: promptText.isEmpty ? nil : promptText
        )
    }

    /// True while the streaming accumulated reply text could STILL become (or
    /// already is) a follow-up directive. Used alongside the `[RESEARCH]` check to
    /// suppress text-to-speech so the `[FOLLOWUP]` marker is never spoken aloud
    /// while we wait to see whether the warm agent is routing.
    static func looksLikeFollowUpPrefix(_ accumulatedText: String) -> Bool {
        let trimmedSoFar = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSoFar.isEmpty else { return false }
        return trimmedSoFar.hasPrefix(tag) || tag.hasPrefix(trimmedSoFar)
    }
}
