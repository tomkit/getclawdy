//
//  ClawdyActionFile.swift
//  Clawdy
//
//  The ON-DISK format of a Clawdy action — `~/.clawdy/actions/<name>/ACTION.md` — and
//  the pure parse/render pair for it. The format is deliberately the one this audience
//  already writes for Claude Code skills: a small `key: value` frontmatter block between
//  `---` lines, then `## section` headings whose bodies are the prompts. No YAML
//  dependency: the frontmatter parser accepts only `key: value` lines (comma-separated
//  values for lists), which is all an action needs.
//
//      ---
//      name: Research
//      tag: RESEARCH
//      description: deep, multi-source web research …
//      tools: WebSearch, WebFetch, Write
//      max_budget_usd: 5
//      plan_phase: true
//      execute_timeout_seconds: 600
//      deliverable: html
//      deliverable_file: report.html
//      ---
//
//      ## when
//      <routing guidance + examples of the `[TAG] task` line>
//
//      ## plan            (claude plan-phase system prompt)
//      ## execute         (claude execute-phase system prompt)
//      ## execute-message (claude execute-phase -p message; {{outputPath}} etc.)
//      ## follow-up       (claude follow-up system prompt)
//      ## follow-up-message
//      ## codex-execute   (codex stdin prompt; task + answers are prepended by the engine)
//      ## codex-follow-up
//
//  A user action needs only `tag`, `description`, `## when` and `## execute-message`
//  (plus `## codex-execute` if they use Codex) — every other field falls back to the
//  built-in research action's value, so teaching Clawdy a new job is mostly writing
//  those two sections. `parse` is pure and throws a readable error for a malformed file;
//  `render` writes an action back out in the same format (used to ship the built-in).
//

import Foundation

enum ClawdyActionFile {
    static let fileName = "ACTION.md"

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingFrontmatter
        case missingTag
        case invalidTag(String)
        case missingSection(String)
        case invalidValue(key: String, value: String)
        case unsupportedDeliverable(String)

        var description: String {
            switch self {
            case .missingFrontmatter: return "missing the leading `---` frontmatter block"
            case .missingTag: return "frontmatter needs a `tag:` (e.g. `tag: RESEARCH`)"
            case .invalidTag(let tag): return "`tag: \(tag)` must be uppercase letters/digits/underscores and not POINT or FOLLOWUP"
            case .missingSection(let name): return "missing the required `## \(name)` section"
            case .invalidValue(let key, let value): return "`\(key): \(value)` isn't a valid value"
            case .unsupportedDeliverable(let kind): return "`deliverable: \(kind)` isn't supported yet (only `html`)"
            }
        }
    }

    // MARK: - Parse

    /// Parses an `ACTION.md` into an action. `id` is the directory name; `fallback`
    /// supplies every value the file leaves out (the built-in research action).
    static func parse(
        markdown: String,
        id: String,
        fallback: ClawdyAction = .builtInResearch
    ) throws -> ClawdyAction {
        let (frontmatter, body) = try splitFrontmatter(markdown)
        let sections = parseSections(body)

        guard let tag = frontmatter["tag"]?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else {
            throw ParseError.missingTag
        }
        guard ClawdyAction.isValidTag(tag) else { throw ParseError.invalidTag(tag) }

        var action = fallback
        action.id = id
        action.tag = tag
        action.name = frontmatter["name"] ?? id.capitalized
        if let description = frontmatter["description"] { action.description = description }
        if let toolsValue = frontmatter["tools"] {
            action.tools = toolsValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let budgetValue = frontmatter["max_budget_usd"] {
            guard let budget = Double(budgetValue) else { throw ParseError.invalidValue(key: "max_budget_usd", value: budgetValue) }
            action.maxBudgetUSD = budget
        }
        if let planValue = frontmatter["plan_phase"] {
            guard let plan = parseBool(planValue) else { throw ParseError.invalidValue(key: "plan_phase", value: planValue) }
            action.planPhase = plan
        }
        if let timeoutValue = frontmatter["execute_timeout_seconds"] {
            guard let timeout = TimeInterval(timeoutValue), timeout > 0 else {
                throw ParseError.invalidValue(key: "execute_timeout_seconds", value: timeoutValue)
            }
            action.executeTimeoutSeconds = timeout
        }
        if let deliverableValue = frontmatter["deliverable"] {
            guard let kind = ClawdyAction.DeliverableKind(rawValue: deliverableValue) else {
                throw ParseError.unsupportedDeliverable(deliverableValue)
            }
            action.deliverable = kind
        }
        if let fileName = frontmatter["deliverable_file"], !fileName.isEmpty { action.deliverableFileName = fileName }

        // `when` is the one section every action must write: without it the router has
        // no idea when to use the action.
        guard let whenToRoute = sections["when"], !whenToRoute.isEmpty else { throw ParseError.missingSection("when") }
        action.whenToRoute = whenToRoute
        if let value = sections["plan"] { action.planSystemPrompt = value }
        if let value = sections["execute"] { action.executeSystemPrompt = value }
        if let value = sections["execute-message"] { action.executeMessageTemplate = value }
        if let value = sections["follow-up"] { action.followUpSystemPrompt = value }
        if let value = sections["follow-up-message"] { action.followUpMessageTemplate = value }
        // Codex has no system prompt: a user action that wrote only the Claude
        // `execute-message` still works on Codex by reusing that text on stdin.
        if let value = sections["codex-execute"] {
            action.codexExecuteTemplate = value
        } else if let value = sections["execute-message"] {
            action.codexExecuteTemplate = value
        }
        if let value = sections["codex-follow-up"] {
            action.codexFollowUpTemplate = value
        } else if let value = sections["follow-up-message"] {
            action.codexFollowUpTemplate = value
        }
        return action
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Splits the leading `---` … `---` block into a `key: value` dictionary and the rest.
    static func splitFrontmatter(_ markdown: String) throws -> ([String: String], String) {
        let lines = markdown.components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            throw ParseError.missingFrontmatter
        }
        var frontmatter: [String: String] = [:]
        var lineIndex = 1
        var closed = false
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            lineIndex += 1
            if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { frontmatter[key] = value }
        }
        guard closed else { throw ParseError.missingFrontmatter }
        let body = lines[lineIndex...].joined(separator: "\n")
        return (frontmatter, body)
    }

    /// Splits the body into `## heading` sections (heading names lowercased, bodies
    /// trimmed of surrounding blank lines). Text before the first heading is ignored.
    static func parseSections(_ body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentName: String?
        var currentLines: [String] = []
        func flush() {
            if let name = currentName {
                sections[name] = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                currentLines = []
            } else if currentName != nil {
                currentLines.append(line)
            }
        }
        flush()
        return sections
    }

    // MARK: - Render

    /// Renders an action in the on-disk format (used to ship the built-in research
    /// action into `~/.clawdy/actions/research/ACTION.md` so users can read and edit it).
    static func render(_ action: ClawdyAction) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(action.name)")
        lines.append("tag: \(action.tag)")
        lines.append("description: \(action.description)")
        lines.append("tools: \(action.tools.joined(separator: ", "))")
        lines.append("max_budget_usd: \(ResearchArguments.trimmedBudgetString(action.maxBudgetUSD))")
        lines.append("plan_phase: \(action.planPhase)")
        lines.append("execute_timeout_seconds: \(Int(action.executeTimeoutSeconds))")
        lines.append("deliverable: \(action.deliverable.rawValue)")
        lines.append("deliverable_file: \(action.deliverableFileName)")
        lines.append("---")
        lines.append("")
        func section(_ name: String, _ text: String) {
            lines.append("## \(name)")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        section("when", action.whenToRoute)
        section("plan", action.planSystemPrompt)
        section("execute", action.executeSystemPrompt)
        section("execute-message", action.executeMessageTemplate)
        section("follow-up", action.followUpSystemPrompt)
        section("follow-up-message", action.followUpMessageTemplate)
        section("codex-execute", action.codexExecuteTemplate)
        section("codex-follow-up", action.codexFollowUpTemplate)
        return lines.joined(separator: "\n")
    }
}
