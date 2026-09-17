//
//  ClawdySkillStore.swift
//  Clawdy
//
//  Loads the skills the warm router can hand a request to:
//
//      ~/.clawdy/router.md                     the routing prompt template, editable (written once)
//      ~/.clawdy/skills/README.md              how Clawdy skills + routing work (written once)
//      ~/.clawdy/skills/research/SKILL.md      the built-in Clawdy skill, editable
//      ~/.clawdy/skills/<name>/SKILL.md        any Clawdy skill the user writes
//      ~/.claude/skills/<name>/SKILL.md        the user's ordinary Claude Code skills   (harness)
//      ~/.codex/skills/<name>/SKILL.md         the user's ordinary Codex skills         (harness)
//
//  Clawdy skills are loaded from the Clawdy dotfiles dir (injectable for tests); the
//  built-in research skill is shipped there on first launch so it can be read and edited.
//  Harness skills are read from whichever harness is the SELECTED coach engine, and only
//  when "Use my Claude Code setup" is on (with it off the dedicated run couldn't load the
//  skill either). Loading is cheap and happens on EVERY push-to-talk turn, so an edit or a
//  newly-installed skill applies on the next question with no relaunch — the warm `claude`
//  process respawns itself when its system prompt changes.
//
//  Failure policy: a malformed SKILL.md is logged and SKIPPED (never crashes the app,
//  never disables other skills). A malformed `research/SKILL.md` falls back to the
//  built-in research skill so research keeps working.
//

import Foundation

struct ClawdySkillStore {
    /// The Clawdy dotfiles directory, `~/.clawdy`.
    static func defaultDotfilesDirectory(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true).appendingPathComponent(".clawdy", isDirectory: true)
    }

    /// Where each harness keeps its user-level skills.
    static func harnessSkillsDirectory(for engineKind: CoachEngineKind, homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        let home = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        switch engineKind {
        case .claudeCode: return home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex/skills", isDirectory: true)
        }
    }

    /// The production store, rooted at `~/.clawdy/skills`.
    static let shared = ClawdySkillStore(
        clawdySkillsDirectory: defaultDotfilesDirectory().appendingPathComponent("skills", isDirectory: true)
    )

    let clawdySkillsDirectory: URL
    /// The user-editable routing prompt template (`~/.clawdy/router.md`).
    let routerTemplateFileURL: URL
    private let fileManager: FileManager

    init(clawdySkillsDirectory: URL, routerTemplateFileURL: URL? = nil, fileManager: FileManager = .default) {
        self.clawdySkillsDirectory = clawdySkillsDirectory
        self.routerTemplateFileURL = routerTemplateFileURL
            ?? clawdySkillsDirectory.deletingLastPathComponent().appendingPathComponent("router.md")
        self.fileManager = fileManager
    }

    // MARK: - Router template

    /// The routing prompt template: the user's `router.md` if it exists and can still
    /// list skills, else the built-in default (logged once per load so a broken edit is
    /// visible without taking routing away).
    func loadRouterTemplate() -> String {
        guard let text = try? String(contentsOf: routerTemplateFileURL, encoding: .utf8) else {
            return ClawdySkillRouterPrompt.defaultTemplate
        }
        guard ClawdySkillRouterPrompt.isUsableTemplate(text) else {
            print("⚠️ \(routerTemplateFileURL.path) has no {{clawdy_skills}} / {{harness_skills}} placeholder — using the built-in routing prompt")
            return ClawdySkillRouterPrompt.defaultTemplate
        }
        return text
    }

    // MARK: - Loading

    /// Every skill the router should know about: built-in research first (replaced by a
    /// valid user `research/SKILL.md`), then the other Clawdy skills alphabetically, then
    /// — when `harnessSkillsDirectory` is given — the harness skills alphabetically. Tags
    /// must be unique; a later skill reusing an earlier tag is skipped with a log line.
    func loadSkills(harnessSkillsDirectory: URL? = nil) -> [ClawdySkill] {
        var skills: [ClawdySkill] = []
        var seenTags: Set<String> = []
        func add(_ skill: ClawdySkill, from source: String) {
            guard !seenTags.contains(skill.tag) else {
                print("⚠️ Clawdy skill '\(skill.id)' (\(source)) reuses marker [\(skill.tag)] already taken — skipped")
                return
            }
            seenTags.insert(skill.tag)
            skills.append(skill)
        }

        add(loadClawdySkill(id: ClawdySkill.builtInResearchID) ?? .builtInResearch, from: "built-in")
        for id in skillIDs(in: clawdySkillsDirectory) where id != ClawdySkill.builtInResearchID {
            if let skill = loadClawdySkill(id: id) { add(skill, from: clawdySkillsDirectory.path) }
        }
        if let harnessSkillsDirectory {
            for id in skillIDs(in: harnessSkillsDirectory) {
                let fileURL = harnessSkillsDirectory.appendingPathComponent(id).appendingPathComponent(ClawdySkillFile.fileName)
                guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8),
                      let skill = ClawdySkillFile.parseHarnessSkill(markdown: markdown, id: id) else { continue }
                add(skill, from: harnessSkillsDirectory.path)
            }
        }
        return skills
    }

    /// Every subdirectory containing a SKILL.md, sorted.
    private func skillIDs(in directory: URL) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(ClawdySkillFile.fileName).path) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Parses one Clawdy `<id>/SKILL.md`, or nil if it's absent or malformed (logged).
    func loadClawdySkill(id: String) -> ClawdySkill? {
        let fileURL = clawdySkillFileURL(id: id)
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        do {
            return try ClawdySkillFile.parseClawdySkill(markdown: markdown, id: id)
        } catch {
            print("⚠️ Clawdy skill '\(id)' at \(fileURL.path) could not be loaded: \(error) — skipped")
            return nil
        }
    }

    func clawdySkillFileURL(id: String) -> URL {
        clawdySkillsDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(ClawdySkillFile.fileName)
    }

    // MARK: - First-launch install

    /// The skills Clawdy ships into `~/.clawdy/skills` on first launch: the built-in
    /// research skill (rendered from code so it can never drift) and a small example
    /// skill, `trip-planner`, that doubles as the template for writing a new one.
    static let bundledSkillFiles: [(id: String, markdown: String)] = [
        (ClawdySkill.builtInResearchID, ClawdySkillFile.render(.builtInResearch)),
        ("trip-planner", bundledTripPlannerMarkdown)
    ]

    /// Writes the bundled skills and a README into the Clawdy skills directory if they
    /// aren't there yet. Never overwrites: once shipped, the files are the user's.
    func installDefaultsIfMissing() {
        for bundled in Self.bundledSkillFiles {
            let fileURL = clawdySkillFileURL(id: bundled.id)
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bundled.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the bundled skill '\(bundled.id)' to \(fileURL.path): \(error)")
            }
        }
        if !fileManager.fileExists(atPath: routerTemplateFileURL.path) {
            do {
                try fileManager.createDirectory(at: routerTemplateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ClawdySkillRouterPrompt.defaultTemplate.write(to: routerTemplateFileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the routing prompt template to \(routerTemplateFileURL.path): \(error)")
            }
        }
        let readmeURL = clawdySkillsDirectory.appendingPathComponent("README.md")
        if !fileManager.fileExists(atPath: readmeURL.path) {
            do {
                try fileManager.createDirectory(at: clawdySkillsDirectory, withIntermediateDirectories: true)
                try Self.readmeText.write(to: readmeURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the skills README to \(readmeURL.path): \(error)")
            }
        }
    }

    /// The bundled example skill: a plain SKILL.md (description + body, no phase
    /// sections) that shows the minimum needed to teach Clawdy a page-producing job.
    static let bundledTripPlannerMarkdown = """
    ---
    name: trip-planner
    description: plans a multi-day (or single-day) trip and builds a self-contained itinerary page with a day-by-day plan, neighborhoods, and a few specific places to eat. use for asks like "plan me N days in <place>", "put together an itinerary for <place>", "what should i do with a weekend in <place>". do NOT use for a quick fact about a place (answer that inline). example — user says "plan me 3 days in kyoto": [TRIP_PLANNER] plan a 3-day kyoto itinerary with a day-by-day plan and places to eat.
    allowed-tools: WebSearch, WebFetch, Write
    clawdy-deliverable: html
    clawdy-plan-phase: false
    clawdy-max-budget-usd: 3
    ---

    plan this trip: {{task}}

    research the destination on the web now, yourself, in this one turn (do not defer to any background job). then write ONE self-contained HTML itinerary page to the absolute path {{outputPath}}: a short intro, then one section per day with a morning / afternoon / evening plan, the neighborhood each stop is in, and one specific place to eat per day with a one-line reason. keep it practical and specific — real place names, rough timings, how to get between stops. inline <style> only, no external scripts, fonts, or stylesheets; a subtle red accent (#E5342B) for headings. do not write any other file. when you're done, briefly confirm in one sentence.
    """

    static let readmeText = """
    # Clawdy skills

    Clawdy can hand a spoken request to a SKILL that runs in its own agent instead of
    answering out loud. Two kinds are available:

    - Your ordinary harness skills (`~/.claude/skills/*/SKILL.md`, or `~/.codex/skills`
      when Codex is selected). Nothing to do — they're offered to the router as-is, and the
      result is spoken back to you.
    - Clawdy skills in this folder — written for Clawdy's interface (voice in; a page on
      your screen or a spoken answer out). `research/` is the built-in one; edit it to
      retune research, or add a folder with a `SKILL.md` to teach Clawdy something new.

    Changes apply on your next question (no relaunch).

    ## Routing

    The voice agent is the router. On every question it either answers inline or, when a
    skill's `description` matches, replies with exactly one line — `[TAG] <task>` — and
    Clawdy starts that skill in a separate process. So your `description` IS the routing
    rule: say when to use the skill and give an example line. On-screen pointing questions
    are always answered inline, never routed.

    The routing prompt itself is `~/.clawdy/router.md`. Edit it to change how the router
    decides. Keep the `{{clawdy_skills}}` and `{{harness_skills}}` placeholders (that's
    where the skill list goes; the `{{#…}} … {{/…}}` blocks around them are dropped when
    that list is empty). If the file loses both placeholders, Clawdy falls back to the
    built-in prompt. Changes apply on your next question.

    ## Format (same as a Claude Code / Codex skill)

    ```
    ---
    name: trip-planner
    description: plans a multi-day trip and builds an itinerary page. use for "plan me N days in <place>". example — user says "plan me 3 days in kyoto": [TRIP_PLANNER] plan a 3-day kyoto itinerary.
    allowed-tools: WebSearch, WebFetch, Write
    clawdy-tag: TRIP_PLANNER             # optional; default is the name upper-cased
    clawdy-deliverable: html             # html (a page opens on screen) or none (spoken result)
    clawdy-deliverable-file: report.html # optional
    clawdy-max-budget-usd: 5             # optional
    clawdy-plan-phase: true              # ask clarifying questions first? optional
    clawdy-execute-timeout-seconds: 600  # optional
    ---

    Plan the trip {{task}} and write ONE self-contained HTML page to {{outputPath}}.
    ```

    Only `description` is required. The body is what the agent does; if it doesn't spell
    out phases, it's used whole as the execute instructions. For full control, split it
    into `## Plan`, `## Execute`, `## Execute message`, `## Follow-up`,
    `## Follow-up message`, `## Codex execute`, `## Codex follow-up` — see `research/`.

    Placeholders: `{{task}}` the task the router extracted · `{{outputPath}}` the absolute
    deliverable path · `{{outputDir}}` the run's output directory · `{{skill}}` the name.

    Rules: `POINT` and `FOLLOWUP` are reserved tags; two skills can't share a marker.
    """
}
