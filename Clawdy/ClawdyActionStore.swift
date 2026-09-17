//
//  ClawdyActionStore.swift
//  Clawdy
//
//  Loads the user's actions from the Clawdy dotfiles directory, `~/.clawdy/actions/`
//  (injectable for tests), and ships the built-in research action there on first
//  launch so it can be read and edited like any other.
//
//  Layout:
//      ~/.clawdy/actions/README.md            how the format works (written once)
//      ~/.clawdy/actions/research/ACTION.md   the built-in action, editable
//      ~/.clawdy/actions/<name>/ACTION.md     any action the user teaches Clawdy
//
//  Loading is cheap (a handful of small files) and happens on EVERY push-to-talk turn
//  (`CompanionManager` composes the router prompt from the current set), so an edit takes
//  effect on the next question with no relaunch. Note the warm `claude` process is spawned
//  with the router prompt baked in via `--append-system-prompt`; `ClaudePersistentSession`
//  already respawns itself when the requested system prompt differs from the live one, so
//  the first turn after an edit pays one cold start and then stays warm.
//
//  Failure policy: a malformed ACTION.md is logged and SKIPPED (never crashes the app,
//  never disables other actions). If the user's `research/ACTION.md` is malformed, the
//  built-in research action is used instead so research keeps working.
//

import Foundation

struct ClawdyActionStore {
    /// The Clawdy dotfiles directory, `~/.clawdy`.
    static func defaultDotfilesDirectory(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true).appendingPathComponent(".clawdy", isDirectory: true)
    }

    /// The production store, rooted at `~/.clawdy/actions`.
    static let shared = ClawdyActionStore(
        actionsDirectory: defaultDotfilesDirectory().appendingPathComponent("actions", isDirectory: true)
    )

    let actionsDirectory: URL
    private let fileManager: FileManager

    init(actionsDirectory: URL, fileManager: FileManager = .default) {
        self.actionsDirectory = actionsDirectory
        self.fileManager = fileManager
    }

    // MARK: - Loading

    /// All actions the router should know about, built-in research first. The user's
    /// `research/ACTION.md` (if present and valid) REPLACES the built-in one — that's how
    /// the research prompts are retuned. Every other `<name>/ACTION.md` is added in
    /// alphabetical order. Tags must be unique: a later action reusing an earlier tag is
    /// skipped with a log line, since the router couldn't tell them apart.
    func loadActions() -> [ClawdyAction] {
        var actions: [ClawdyAction] = []
        var seenTags: Set<String> = []

        let researchAction = loadAction(id: ClawdyAction.builtInResearchID) ?? .builtInResearch
        actions.append(researchAction)
        seenTags.insert(researchAction.tag)

        for id in userActionIDs() where id != ClawdyAction.builtInResearchID {
            guard let action = loadAction(id: id) else { continue }
            guard !seenTags.contains(action.tag) else {
                print("⚠️ Clawdy action '\(id)' reuses tag [\(action.tag)] already taken by another action — skipped")
                continue
            }
            seenTags.insert(action.tag)
            actions.append(action)
        }
        return actions
    }

    /// Every subdirectory of the actions directory that contains an ACTION.md, sorted.
    private func userActionIDs() -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: actionsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(ClawdyActionFile.fileName).path) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Parses one `<id>/ACTION.md`, or nil if it's absent or malformed (logged).
    func loadAction(id: String) -> ClawdyAction? {
        let fileURL = actionFileURL(id: id)
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        do {
            return try ClawdyActionFile.parse(markdown: markdown, id: id)
        } catch {
            print("⚠️ Clawdy action '\(id)' at \(fileURL.path) could not be loaded: \(error) — skipped")
            return nil
        }
    }

    func actionFileURL(id: String) -> URL {
        actionsDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(ClawdyActionFile.fileName)
    }

    // MARK: - First-launch install

    /// Writes the built-in research action and a README into the actions directory if
    /// they aren't there yet. Never overwrites: once shipped, the files are the user's.
    func installDefaultsIfMissing() {
        let researchFileURL = actionFileURL(id: ClawdyAction.builtInResearchID)
        if !fileManager.fileExists(atPath: researchFileURL.path) {
            do {
                try fileManager.createDirectory(at: researchFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ClawdyActionFile.render(.builtInResearch).write(to: researchFileURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the built-in research action to \(researchFileURL.path): \(error)")
            }
        }
        let readmeURL = actionsDirectory.appendingPathComponent("README.md")
        if !fileManager.fileExists(atPath: readmeURL.path) {
            do {
                try fileManager.createDirectory(at: actionsDirectory, withIntermediateDirectories: true)
                try Self.readmeText.write(to: readmeURL, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ Could not write the actions README to \(readmeURL.path): \(error)")
            }
        }
    }

    static let readmeText = """
    # Clawdy actions

    An ACTION is a longer-running job Clawdy can hand off to a separate agent instead of
    answering out loud — `research/` is the built-in one. Each action is a folder here with
    an `ACTION.md` in it. Edit `research/ACTION.md` to retune research, or add a new folder
    to teach Clawdy something new. Changes apply on your next question (no relaunch).

    ## Format

    ```
    ---
    name: Trip planner
    tag: TRIP                      # the router emits `[TRIP] <task>`; A-Z, 0-9, _ only
    description: plans a multi-day trip and builds an itinerary page.
    tools: WebSearch, WebFetch, Write        # claude --allowedTools (optional)
    max_budget_usd: 5                        # optional
    plan_phase: true                         # ask clarifying questions first? (optional)
    execute_timeout_seconds: 600             # optional
    deliverable: html                        # only `html` for now
    deliverable_file: report.html            # optional
    ---

    ## when
    Tell the router when to use this action, and give 2-3 examples of the exact line to
    emit, e.g.  - user says "plan me 3 days in kyoto": [TRIP] plan a 3-day kyoto itinerary.

    ## execute-message
    What the agent should do. Write ONE self-contained HTML page to {{outputPath}}.
    ```

    Only `tag`, `description`, `## when` and `## execute-message` are required. Anything
    you leave out (`## plan`, `## execute`, `## follow-up`, `## follow-up-message`,
    `## codex-execute`, `## codex-follow-up`, and the frontmatter options) is inherited
    from the built-in research action — open `research/ACTION.md` to see all of them.

    Placeholders you can use in any prompt section:
    `{{task}}` the task the router extracted · `{{outputPath}}` the absolute deliverable
    path · `{{outputDir}}` the run's output directory.

    Rules: a spoken on-screen pointing question always stays a quick answer (never routed);
    `POINT` and `FOLLOWUP` are reserved tags; two actions can't share a tag.
    """
}
