//
//  ClawdyActionDirective.swift
//  Clawdy
//
//  Pure parsing of the ROUTER directive for ANY registered action. The warm Clawdy
//  agent is the router: on each turn it either answers quickly itself OR emits a single
//  structured directive as its ENTIRE reply:
//
//      [TAG] <one-line task description>
//
//  where TAG is one of the loaded actions' tags (`[RESEARCH]` for the built-in one).
//  This generalizes `ResearchDirective` (which stays as the research-specific wrapper the
//  existing tests and call sites use) to the whole action set, and provides the streaming
//  TTS-suppression check so no marker is ever spoken aloud while the reply is still
//  arriving. Side-effect-free and unit-testable.
//

import Foundation

enum ClawdyActionDirective {
    /// A parsed directive: WHICH action the router chose and the task it wrote.
    struct Match: Equatable {
        let action: ClawdyAction
        /// The task text after the marker, trimmed; nil when the marker had no text.
        let taskDescription: String?
    }

    /// Parses the warm agent's full reply against the loaded actions. A directive is the
    /// ENTIRE reply: it must START with an action's marker. Anything that merely mentions
    /// a marker mid-sentence is a normal spoken answer. The longest matching marker wins
    /// so `[RESEARCH_DEEP]` can't be mistaken for `[RESEARCH]`.
    static func parse(from responseText: String, actions: [ClawdyAction]) -> Match? {
        let trimmedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = actions
            .filter { trimmedReply.hasPrefix($0.directiveMarker) }
            .sorted { $0.directiveMarker.count > $1.directiveMarker.count }
        guard let action = candidates.first else { return nil }
        let taskText = String(trimmedReply.dropFirst(action.directiveMarker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(action: action, taskDescription: taskText.isEmpty ? nil : taskText)
    }

    /// True while the streaming accumulated reply could STILL become (or already is) a
    /// directive for any loaded action — used to hold TTS until we know whether the
    /// agent is routing. False as soon as the opening characters can't be a marker.
    static func looksLikeDirectivePrefix(_ accumulatedText: String, actions: [ClawdyAction]) -> Bool {
        let trimmedSoFar = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSoFar.isEmpty else { return false }
        return actions.contains { action in
            trimmedSoFar.hasPrefix(action.directiveMarker) || action.directiveMarker.hasPrefix(trimmedSoFar)
        }
    }
}
