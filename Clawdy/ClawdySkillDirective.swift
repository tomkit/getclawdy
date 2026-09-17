//
//  ClawdySkillDirective.swift
//  Clawdy
//
//  Pure parsing of the ROUTER directive for ANY loaded skill. The warm Clawdy agent is
//  the router: on each turn it either answers quickly itself OR emits a single structured
//  directive as its ENTIRE reply:
//
//      [TAG] <one-line task description>
//
//  where TAG is one of the loaded skills' markers — `[RESEARCH]` for the built-in Clawdy
//  skill, `[SKILL:name]` for one of the user's harness skills. This generalizes
//  `ResearchDirective` (kept as the research-specific wrapper the existing tests use) to
//  the whole skill set, and provides the streaming TTS-suppression check so no marker is
//  ever spoken aloud while the reply is still arriving. Side-effect-free, unit-testable.
//

import Foundation

enum ClawdySkillDirective {
    /// A parsed directive: WHICH skill the router chose and the task it wrote.
    struct Match: Equatable {
        let skill: ClawdySkill
        /// The task text after the marker, trimmed; nil when the marker had no text.
        let taskDescription: String?
    }

    /// Parses the warm agent's full reply against the loaded skills. A directive is the
    /// ENTIRE reply: it must START with a skill's marker. Anything that merely mentions a
    /// marker mid-sentence is a normal spoken answer. The longest matching marker wins so
    /// `[RESEARCH_DEEP]` can't be mistaken for `[RESEARCH]`.
    static func parse(from responseText: String, skills: [ClawdySkill]) -> Match? {
        let trimmedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = skills
            .filter { trimmedReply.hasPrefix($0.directiveMarker) }
            .sorted { $0.directiveMarker.count > $1.directiveMarker.count }
        guard let skill = candidates.first else { return nil }
        let taskText = String(trimmedReply.dropFirst(skill.directiveMarker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(skill: skill, taskDescription: taskText.isEmpty ? nil : taskText)
    }

    /// True while the streaming accumulated reply could STILL become (or already is) a
    /// directive for any loaded skill — used to hold TTS until we know whether the agent
    /// is routing. False as soon as the opening characters can't be a marker.
    static func looksLikeDirectivePrefix(_ accumulatedText: String, skills: [ClawdySkill]) -> Bool {
        let trimmedSoFar = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSoFar.isEmpty else { return false }
        return skills.contains { skill in
            trimmedSoFar.hasPrefix(skill.directiveMarker) || skill.directiveMarker.hasPrefix(trimmedSoFar)
        }
    }
}
