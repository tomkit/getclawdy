//
//  ClawdySkillRouterPrompt.swift
//  Clawdy
//
//  Composes the ROUTING section of the warm voice agent's system prompt from the loaded
//  skills. The shared preamble (the PLAN-vs-ACT heuristic, the "your ENTIRE reply is one
//  marker line" rule, and the sacred pointing exception) is fixed; each skill contributes
//  its marker and its `description` — the routing rule, exactly as Claude Code uses a
//  skill's description to decide when to invoke it. Pure, so the prompt is unit-testable.
//

import Foundation

enum ClawdySkillRouterPrompt {
    static func compose(skills: [ClawdySkill]) -> String {
        let clawdySkills = skills.filter { $0.kind == .clawdy }
        let harnessSkills = skills.filter { $0.kind == .harness }

        func block(_ skill: ClawdySkill) -> String {
            "\(skill.directiveMarker) — \(skill.name): \(skill.description)"
        }
        var groups: [String] = []
        if !clawdySkills.isEmpty {
            groups.append("clawdy skills (each produces a page on the user's screen or a spoken result):\n\n"
                + clawdySkills.map(block).joined(separator: "\n\n"))
        }
        if !harnessSkills.isEmpty {
            groups.append("""
            the user's own skills (their ordinary coding-agent skills; the run invokes the skill and the result is spoken back). route to one when the request clearly matches its description:

            \(harnessSkills.map(block).joined(separator: "\n\n"))
            """)
        }

        return """
        skills (routing):
        you double as the router for clawdy's SKILLS — separate, longer-running agent jobs that run in their own process instead of a quick voice reply. decide between answering inline versus routing to a skill the SAME way a coding agent decides between just DOING a task and stopping to PLAN one first. you PLAN — route to a skill — when the request needs gathering information from across the web or multiple sources, is multi-step or open-ended, asks you to produce a compiled artifact (a page, gallery, list, comparison, or report), or clearly matches one of the skills below. you just ACT — answer inline as a quick voice reply — when the request is simple, single-step, and immediately answerable right now from what's on the screen or from your own general knowledge.

        when (and only when) the request is one of those, do NOT answer it yourself and do NOT speak. instead your ENTIRE reply must be exactly one line: that skill's marker followed by a single clear sentence describing the task. nothing before it, nothing after it, no spoken text, no point tag.

        \(groups.joined(separator: "\n\n"))

        any request that is NOT covered by a skill — a normal question you can answer well in a sentence or two, or any on-screen pointing question — you answer yourself and never use a marker. an on-screen POINTING question ("where do i click…", "which button…") is ALWAYS a quick answer with a POINT tag, NEVER a route.
        """
    }
}
