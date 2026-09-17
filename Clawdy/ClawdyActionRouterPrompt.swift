//
//  ClawdyActionRouterPrompt.swift
//  Clawdy
//
//  Composes the ROUTING section of the warm voice agent's system prompt from the loaded
//  actions. The shared preamble (the PLAN-vs-ACT heuristic, the "your ENTIRE reply is one
//  marker line" rule, and the sacred pointing exception) is fixed; one block per action
//  supplies its marker, description and the user-editable `## when` guidance. Pure, so the
//  exact prompt text is unit-testable.
//

import Foundation

enum ClawdyActionRouterPrompt {
    static func compose(actions: [ClawdyAction]) -> String {
        let actionBlocks = actions.map { action in
            "\(action.directiveMarker) — \(action.name.lowercased()): \(action.description)\n\(action.whenToRoute)"
        }.joined(separator: "\n\n")

        return """
        actions (routing):
        you double as the router for clawdy's ACTIONS — separate, longer-running agent jobs that run in their own process instead of a quick voice reply. decide between answering inline versus routing to an action the SAME way a coding agent decides between just DOING a task and stopping to PLAN one first. you PLAN — route to an action — when the request needs gathering information from across the web or multiple sources, is multi-step or open-ended, or asks you to produce a compiled artifact (a page, gallery, list, comparison, or report). you just ACT — answer inline as a quick voice reply — when the request is simple, single-step, and immediately answerable right now from what's on the screen or from your own general knowledge.

        when (and only when) the request is one of the plan-worthy jobs an action below covers, do NOT answer it yourself and do NOT speak. instead your ENTIRE reply must be exactly one line: that action's marker followed by a single clear sentence describing the task. nothing before it, nothing after it, no spoken text, no point tag.

        the actions you can route to:

        \(actionBlocks)

        any request that is NOT covered by an action — a normal question you can answer well in a sentence or two, or any on-screen pointing question — you answer yourself and never use a marker. an on-screen POINTING question ("where do i click…", "which button…") is ALWAYS a quick answer with a POINT tag, NEVER a route.
        """
    }
}
