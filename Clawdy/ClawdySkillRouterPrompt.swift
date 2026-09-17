//
//  ClawdySkillRouterPrompt.swift
//  Clawdy
//
//  Composes the ROUTING section of the warm voice agent's system prompt from a TEMPLATE
//  and the loaded skills. The template is user-editable — it ships to
//  `~/.clawdy/router.md` on first launch and is read on every turn — so the routing
//  rules themselves are tunable without a rebuild. `defaultTemplate` is the built-in
//  text and the fallback when the file is missing or unusable.
//
//  Template placeholders:
//    {{clawdy_skills}}    one entry per Clawdy skill:  [TAG] — name: description
//    {{harness_skills}}   one entry per harness skill: [SKILL:name] — name: description
//  Optional blocks, dropped entirely when their list is empty:
//    {{#clawdy_skills}} … {{/clawdy_skills}}
//    {{#harness_skills}} … {{/harness_skills}}
//
//  Each skill's `description` is its routing rule (Claude Code's own auto-invocation
//  semantics); Clawdy adds no heuristics of its own beyond what the template says.
//

import Foundation

enum ClawdySkillRouterPrompt {
    static let defaultTemplate = """
    skills (routing):
    you double as the router for clawdy's SKILLS — separate, longer-running agent jobs that run in their own process instead of a quick voice reply. decide between answering inline versus routing to a skill the SAME way a coding agent decides between just DOING a task and stopping to PLAN one first. you PLAN — route to a skill — when the request needs gathering information from across the web or multiple sources, is multi-step or open-ended, asks you to produce a compiled artifact (a page, gallery, list, comparison, or report), or clearly matches one of the skills below. you just ACT — answer inline as a quick voice reply — when the request is simple, single-step, and immediately answerable right now from what's on the screen or from your own general knowledge.

    when (and only when) the request is one of those, do NOT answer it yourself and do NOT speak. instead your ENTIRE reply must be exactly one line: that skill's marker followed by a single clear sentence describing the task. nothing before it, nothing after it, no spoken text, no point tag.

    {{#clawdy_skills}}clawdy skills (each produces a page on the user's screen or a spoken result):

    {{clawdy_skills}}{{/clawdy_skills}}

    {{#harness_skills}}the user's own skills (their ordinary coding-agent skills; the run invokes the skill and the result is spoken back). route to one when the request clearly matches its description:

    {{harness_skills}}{{/harness_skills}}

    any request that is NOT covered by a skill — a normal question you can answer well in a sentence or two, or any on-screen pointing question — you answer yourself and never use a marker. an on-screen POINTING question ("where do i click…", "which button…") is ALWAYS a quick answer with a POINT tag, NEVER a route.
    """

    /// A template is usable only if it can actually list skills; otherwise the router
    /// would never learn a marker. Used by the store to fall back to the default.
    static func isUsableTemplate(_ template: String) -> Bool {
        template.contains("{{clawdy_skills}}") || template.contains("{{harness_skills}}")
    }

    static func compose(skills: [ClawdySkill], template: String = defaultTemplate) -> String {
        func entry(_ skill: ClawdySkill) -> String {
            "\(skill.directiveMarker) — \(skill.name): \(skill.description)"
        }
        let clawdyEntries = skills.filter { $0.kind == .clawdy }.map(entry).joined(separator: "\n\n")
        let harnessEntries = skills.filter { $0.kind == .harness }.map(entry).joined(separator: "\n\n")

        var text = template
        text = expandBlock(named: "clawdy_skills", in: text, keep: !clawdyEntries.isEmpty)
        text = expandBlock(named: "harness_skills", in: text, keep: !harnessEntries.isEmpty)
        text = text.replacingOccurrences(of: "{{clawdy_skills}}", with: clawdyEntries)
        text = text.replacingOccurrences(of: "{{harness_skills}}", with: harnessEntries)
        // Collapse the blank lines a dropped block leaves behind.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{{#name}} … {{/name}}` → the inner text when `keep`, nothing otherwise.
    private static func expandBlock(named name: String, in text: String, keep: Bool) -> String {
        let open = "{{#\(name)}}", close = "{{/\(name)}}"
        var result = text
        while let openRange = result.range(of: open), let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
            let inner = keep ? String(result[openRange.upperBound..<closeRange.lowerBound]) : ""
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: inner)
        }
        return result
    }
}
