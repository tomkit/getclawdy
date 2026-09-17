//
//  ClawdySkillStore.swift
//  Clawdy
//
//  Loads the skills the warm router can hand a request to:
//
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
    private let fileManager: FileManager

    init(clawdySkillsDirectory: URL, fileManager: FileManager = .default) {
        self.clawdySkillsDirectory = clawdySkillsDirectory
        self.fileManager = fileManager
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

    /// Writes the built-in research skill and a README into the Clawdy skills directory
    /// if they aren't there yet. Never overwrites: once shipped, the files are the user's.
    func installDefaultsIfMissing() {
        let researchFileURL = clawdySkillFileURL(id: ClawdySkill.builtInResearchID)
        if !fileManager.fileExists(atPath: researchFileURL.path) {
            do {
                try fileManager.createDirectory(at: researchFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ClawdySkillFile.render(.builtInResearch).write(to: researchFileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the built-in research skill to \(researchFileURL.path): \(error)")
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
