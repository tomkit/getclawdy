//
//  ResearchDirective.swift
//  Clawdy
//
//  Pure parsing for the ROUTER directive the warm Clawdy agent emits when it
//  decides a spoken prompt is actually a deep-research request rather than a
//  quick voice answer. The warm agent is the router: on each turn it either
//  answers quickly itself (today's behavior, unchanged) OR emits a single
//  structured directive
//
//      [RESEARCH] <one-line task description>
//
//  as its ENTIRE reply. The app parses that directive here — mirroring the
//  existing [POINT:...] tag parser — and hands the task to the separate research
//  subsystem instead of speaking the reply.
//
//  Everything here is side-effect-free and unit-testable.
//

import Foundation

enum ResearchDirective {
    /// The marker the warm router agent emits at the very start of its reply when
    /// it routes a prompt to the research subsystem.
    static let tag = "[RESEARCH]"

    /// Outcome of inspecting the warm agent's full reply for a research directive.
    struct ParseResult: Equatable {
        /// True when the reply is a research directive (routes to the research
        /// subsystem) rather than a normal spoken answer.
        let isResearchRequest: Bool
        /// The task description the agent wrote after the marker, trimmed. Nil when
        /// this isn't a research directive, or the marker had no text after it.
        let taskDescription: String?
    }

    /// Parses the warm agent's full reply. A research directive is the ENTIRE
    /// reply: it must START with `[RESEARCH]` (the router emits nothing else — no
    /// spoken text, no POINT tag), followed by the one-line task description.
    /// Anything that merely mentions the marker mid-sentence is treated as a
    /// normal spoken answer, not a route.
    static func parse(from responseText: String) -> ParseResult {
        let trimmedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReply.hasPrefix(tag) else {
            return ParseResult(isResearchRequest: false, taskDescription: nil)
        }
        let taskText = String(trimmedReply.dropFirst(tag.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(
            isResearchRequest: true,
            taskDescription: taskText.isEmpty ? nil : taskText
        )
    }

    /// True while the streaming accumulated reply text could STILL become (or
    /// already is) a research directive. Used by the streaming pipeline to suppress
    /// text-to-speech so the `[RESEARCH]` marker is never spoken aloud while we wait
    /// to see whether the warm agent is routing. Returns false for any reply whose
    /// opening characters can't be the start of the marker — that's an ordinary
    /// spoken answer and TTS should proceed normally.
    static func looksLikeResearchPrefix(_ accumulatedText: String) -> Bool {
        let trimmedSoFar = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSoFar.isEmpty else { return false }
        // Already a directive, or the partial text is still a prefix of the marker
        // (e.g. "[RESE" on its way to "[RESEARCH]").
        return trimmedSoFar.hasPrefix(tag) || tag.hasPrefix(trimmedSoFar)
    }
}
