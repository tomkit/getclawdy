//
//  ClawdySkillFile.swift
//  Clawdy
//
//  Pure parse/render for SKILL.md — the SAME file format Claude Code and Codex skills
//  use — read two ways:
//
//    • a CLAWDY skill (`~/.clawdy/skills/<name>/SKILL.md`): standard frontmatter
//      (`name`, `description`, `allowed-tools`) plus optional Clawdy-only keys
//      (`clawdy-tag`, `clawdy-deliverable` html|none, `clawdy-deliverable-file`,
//      `clawdy-max-budget-usd`, `clawdy-plan-phase`, `clawdy-execute-timeout-seconds`),
//      and a markdown body that is the agent's instructions. The body may be split into
//      phase sections — `## Plan`, `## Execute`, `## Execute message`, `## Follow-up`,
//      `## Follow-up message`, `## Codex execute`, `## Codex follow-up` — for full control
//      (the built-in research skill does); a body WITHOUT those headings is used whole as
//      the execute message, with generic plan/execute/follow-up prompts around it.
//    • a HARNESS skill (`~/.claude/skills/<name>/SKILL.md`, `~/.codex/skills/…`): only
//      `name`, `description` and `allowed-tools` are read; the body is the harness's
//      business (it loads the skill itself when the dedicated run invokes it).
//
//  The frontmatter parser handles what SKILL.md files actually use: `key: value` lines,
//  `key: |` / `key: >` block scalars for multi-line descriptions, and comma- or
//  space-separated tool lists. No YAML dependency.
//

import Foundation

enum ClawdySkillFile {
    static let fileName = "SKILL.md"

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingFrontmatter
        case missingDescription
        case invalidTag(String)
        case invalidValue(key: String, value: String)
        case unsupportedDeliverable(String)

        var description: String {
            switch self {
            case .missingFrontmatter: return "missing the leading `---` frontmatter block"
            case .missingDescription: return "frontmatter needs a `description:` — it's the routing rule"
            case .invalidTag(let tag): return "`clawdy-tag: \(tag)` must be uppercase letters/digits/underscores and not POINT or FOLLOWUP"
            case .invalidValue(let key, let value): return "`\(key): \(value)` isn't a valid value"
            case .unsupportedDeliverable(let kind): return "`clawdy-deliverable: \(kind)` must be `html` or `none`"
            }
        }
    }

    // MARK: - Parse: Clawdy skill

    /// Parses a Clawdy skill's SKILL.md. `id` is the directory name; unspecified values
    /// fall back to the built-in research skill's (frontmatter knobs) or the generic
    /// prompts (phase sections a plain body doesn't spell out).
    static func parseClawdySkill(markdown: String, id: String) throws -> ClawdySkill {
        let (frontmatter, body) = try splitFrontmatter(markdown)
        guard let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { throw ParseError.missingDescription }

        let name = frontmatter["name"]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? id
        let tag = frontmatter["clawdy-tag"]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? ClawdySkill.derivedTag(fromName: name)
        guard ClawdySkill.isValidTag(tag) else { throw ParseError.invalidTag(tag) }

        let research = ClawdySkill.builtInResearch
        var skill = research
        skill.id = id
        skill.name = name
        skill.kind = .clawdy
        skill.tag = tag
        skill.description = description
        if let toolsValue = frontmatter["allowed-tools"] { skill.tools = parseToolList(toolsValue) }
        if let budgetValue = frontmatter["clawdy-max-budget-usd"] {
            guard let budget = Double(budgetValue) else { throw ParseError.invalidValue(key: "clawdy-max-budget-usd", value: budgetValue) }
            skill.maxBudgetUSD = budget
        }
        if let planValue = frontmatter["clawdy-plan-phase"] {
            guard let plan = parseBool(planValue) else { throw ParseError.invalidValue(key: "clawdy-plan-phase", value: planValue) }
            skill.planPhase = plan
        }
        if let timeoutValue = frontmatter["clawdy-execute-timeout-seconds"] {
            guard let timeout = TimeInterval(timeoutValue), timeout > 0 else {
                throw ParseError.invalidValue(key: "clawdy-execute-timeout-seconds", value: timeoutValue)
            }
            skill.executeTimeoutSeconds = timeout
        }
        if let deliverableValue = frontmatter["clawdy-deliverable"] {
            guard let kind = ClawdySkill.DeliverableKind(rawValue: deliverableValue) else {
                throw ParseError.unsupportedDeliverable(deliverableValue)
            }
            skill.deliverable = kind
        }
        if let fileName = frontmatter["clawdy-deliverable-file"]?.nonEmpty { skill.deliverableFileName = fileName }

        // Prompts. A body with phase sections fills them in one by one (unspecified ones
        // keep the research/generic defaults for a Clawdy skill); a body with none of
        // them IS the execute message, framed by the generic prompts.
        let sections = parseSections(body)
        let hasPhaseSections = !phaseSectionNames.isDisjoint(with: sections.keys)
        if hasPhaseSections {
            if let value = sections["plan"] { skill.planSystemPrompt = value }
            if let value = sections["execute"] { skill.executeSystemPrompt = value }
            if let value = sections["execute message"] { skill.executeMessageTemplate = value }
            if let value = sections["follow-up"] { skill.followUpSystemPrompt = value }
            if let value = sections["follow-up message"] { skill.followUpMessageTemplate = value }
            skill.codexExecuteTemplate = sections["codex execute"] ?? sections["execute message"] ?? skill.codexExecuteTemplate
            skill.codexFollowUpTemplate = sections["codex follow-up"] ?? sections["follow-up message"] ?? skill.codexFollowUpTemplate
        } else {
            let instructions = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let executeMessage = instructions.isEmpty ? description : instructions
            skill.planSystemPrompt = ClawdySkill.genericPlanSystemPrompt
            skill.executeSystemPrompt = ClawdySkill.genericExecuteSystemPrompt
            skill.executeMessageTemplate = executeMessage
            skill.followUpSystemPrompt = ClawdySkill.genericFollowUpSystemPrompt
            skill.followUpMessageTemplate = ClawdySkill.genericFollowUpMessageTemplate
            skill.codexExecuteTemplate = executeMessage
            skill.codexFollowUpTemplate = ClawdySkill.genericFollowUpMessageTemplate
        }
        return skill
    }

    /// The `## …` headings a Clawdy skill may use to spell out each phase.
    static let phaseSectionNames: Set<String> = [
        "plan", "execute", "execute message", "follow-up", "follow-up message", "codex execute", "codex follow-up"
    ]

    // MARK: - Parse: harness skill

    /// Reads only what Clawdy needs from an ordinary harness skill: its name, its
    /// description (the routing rule) and its `allowed-tools`. Nil if it has no description
    /// (nothing to route on).
    static func parseHarnessSkill(markdown: String, id: String) -> ClawdySkill? {
        guard let (frontmatter, _) = try? splitFrontmatter(markdown) else { return nil }
        guard let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        let name = frontmatter["name"]?.trimmingCharacters(in: .whitespaces).nonEmpty ?? id
        let tools = frontmatter["allowed-tools"].map(parseToolList)
        return ClawdySkill.harness(name: name, description: description, allowedTools: tools)
    }

    // MARK: - Frontmatter

    /// Splits the leading `---` … `---` block into a key → value dictionary (keys
    /// lowercased) and the body. Supports `key: value`, and `key: |` / `key: >` block
    /// scalars whose indented continuation lines are joined (with newlines for `|`,
    /// spaces for `>`).
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
            guard let colonIndex = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" || value == "|-" || value == ">-" {
                // Block scalar: gather the following indented lines.
                var blockLines: [String] = []
                while lineIndex < lines.count, lines[lineIndex].hasPrefix(" ") || lines[lineIndex].isEmpty {
                    if lines[lineIndex].trimmingCharacters(in: .whitespaces) == "---" { break }
                    blockLines.append(lines[lineIndex])
                    lineIndex += 1
                }
                let indent = blockLines.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
                let dedented = blockLines.map { $0.isEmpty ? "" : String($0.dropFirst(indent)) }
                value = value.hasPrefix("|")
                    ? dedented.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    : dedented.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            } else if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                        || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { frontmatter[key] = value }
        }
        guard closed else { throw ParseError.missingFrontmatter }
        return (frontmatter, lines[lineIndex...].joined(separator: "\n"))
    }

    /// `allowed-tools: Read, Grep` or `allowed-tools: Read Grep Bash(git:*)` → the list.
    static func parseToolList(_ value: String) -> [String] {
        let separators = value.contains(",") ? CharacterSet(charactersIn: ",") : CharacterSet.whitespaces
        return value.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Splits the body into `## heading` sections. Heading names are normalized
    /// (lowercased, `_`/`-`/multiple spaces → one form: "execute-message" == "execute message").
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
                currentName = normalizeSectionName(String(line.dropFirst(3)))
                currentLines = []
            } else if currentName != nil {
                currentLines.append(line)
            }
        }
        flush()
        return sections
    }

    static func normalizeSectionName(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // "execute-message", "execute_message", "execute  message" → "execute message";
        // keep the hyphen in "follow-up" so it stays one word.
        let unified = lowered.replacingOccurrences(of: "follow-up", with: "followup")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        return unified.replacingOccurrences(of: "followup", with: "follow-up")
    }

    // MARK: - Render

    /// Renders a Clawdy skill in the on-disk format (used to ship the built-in research
    /// skill into `~/.clawdy/skills/research/SKILL.md` so users can read and edit it).
    static func render(_ skill: ClawdySkill) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(skill.name)")
        lines.append("description: |")
        for descriptionLine in skill.description.components(separatedBy: "\n") {
            lines.append(descriptionLine.isEmpty ? "" : "  " + descriptionLine)
        }
        lines.append("allowed-tools: \(skill.tools.joined(separator: ", "))")
        lines.append("clawdy-tag: \(skill.tag)")
        lines.append("clawdy-deliverable: \(skill.deliverable.rawValue)")
        lines.append("clawdy-deliverable-file: \(skill.deliverableFileName)")
        lines.append("clawdy-max-budget-usd: \(ResearchArguments.trimmedBudgetString(skill.maxBudgetUSD))")
        lines.append("clawdy-plan-phase: \(skill.planPhase)")
        lines.append("clawdy-execute-timeout-seconds: \(Int(skill.executeTimeoutSeconds))")
        lines.append("---")
        lines.append("")
        func section(_ name: String, _ text: String) {
            lines.append("## \(name)")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        section("Plan", skill.planSystemPrompt)
        section("Execute", skill.executeSystemPrompt)
        section("Execute message", skill.executeMessageTemplate)
        section("Follow-up", skill.followUpSystemPrompt)
        section("Follow-up message", skill.followUpMessageTemplate)
        section("Codex execute", skill.codexExecuteTemplate)
        section("Codex follow-up", skill.codexFollowUpTemplate)
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
