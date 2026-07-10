//
//  ClaudeResearchEngine.swift
//  Clawdy
//
//  The DEDICATED, SEPARATE research subsystem: a stand-alone `claude -p` process
//  (its own process, its own task, its own state) that is fully isolated from the
//  warm quick-answer `ClaudePersistentSession`. A quick Ctrl+Option voice answer
//  can never kill a research run and vice versa, because this engine shares NONE
//  of the warm session's process, queue, or lifecycle — it shells out through the
//  one-shot `CLIProcessRunner`, whose Task-cancellation already SIGTERMs only its
//  own child.
//
//  Two phases (see ResearchArguments for the exact command lines):
//   1. PLAN/CLARIFY — `--permission-mode plan`. The plan agent decides whether it
//      needs clarifying questions. We return either `.needsClarification(...)` (so
//      the UI can surface the questions) or `.readyToExecute`.
//   2. EXECUTE — `--resume <session_id> --permission-mode acceptEdits` with a
//      NARROW tool allowlist (WebSearch / WebFetch / Write), writing one
//      self-contained HTML page to a scoped per-run temp dir (never $HOME).
//
//  Billing: neither phase uses `--bare`, so both bill the user's subscription.
//

import Foundation

final class ClaudeResearchEngine: ResearchEngine {
    // MARK: - ResearchEngine capabilities

    /// Claude accepts a pre-minted `--session-id <uuid>` and echoes it back verbatim,
    /// so the caller owns the id before the run starts.
    var supportsPreMintedSessionID: Bool { true }

    /// Claude runs a distinct PLAN/clarify phase (`--permission-mode plan`) before
    /// executing.
    var supportsPlanPhase: Bool { true }

    // MARK: - ResearchEngine directory + transcript strategy (promoted to the protocol)

    /// The instance-level `ResearchEngine` conformance for the per-session output
    /// directory. Delegates verbatim to the existing static derivation so Claude's
    /// directory strategy is byte-for-byte unchanged — the protocol method exists so
    /// `ResearchSession` no longer reaches for `ClaudeResearchEngine` statically.
    func makeSessionOutputDirectory(sessionID: String, applicationSupportDirectory: URL) throws -> URL {
        try Self.makeSessionOutputDirectory(
            sessionID: sessionID,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    /// The instance-level `ResearchEngine` conformance for the transcript path. Claude
    /// derives it deterministically from the shared working directory + this engine's
    /// home directory (unchanged from the prior static call site), so it is always
    /// resolvable up front (never nil).
    func transcriptPath(sessionID: String, outputDirectory: URL) -> String? {
        Self.claudeTranscriptPath(
            sessionID: sessionID,
            workingDirectoryPath: outputDirectory.path,
            homeDirectoryPath: homeDirectoryPath
        )
    }

    enum ResearchError: LocalizedError {
        case noSessionID
        case noDeliverableProduced
        case phaseFailed(standardError: String)

        var errorDescription: String? {
            switch self {
            case .noSessionID:
                return "Couldn't start the research session."
            case .noDeliverableProduced:
                return "The research run finished without producing a page."
            case .phaseFailed(let standardError):
                let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "The research run failed."
                    : "The research run failed: \(trimmed)"
            }
        }
    }

    // Plan/follow-up phase result types moved to ResearchEngine.swift so every
    // conforming engine can return them (PlanPhaseResult, FollowUpPhaseResult).

    private let binaryPath: String
    private let homeDirectoryPath: String
    /// Wall-clock caps. The plan phase is quick; the execute phase can run for
    /// minutes, so it gets a much larger ceiling. Both are hard limits enforced by
    /// CLIProcessRunner (the child is terminated when they elapse).
    private let planPhaseTimeoutSeconds: TimeInterval
    private let executePhaseTimeoutSeconds: TimeInterval
    /// Hard cost ceiling passed to the CLI as `--max-budget-usd` for the execute
    /// phase, so a runaway tool-using run can't spend unbounded subscription quota.
    private let maxBudgetUSD: Double
    /// Mirrors the single app-wide "Use my Claude Code setup" setting (default true).
    /// true → the user's `claude` customizations (CLAUDE.md, skills, MCP, hooks) load
    /// on both research phases; false → `--safe-mode` is added to isolate the run.
    /// Read once per engine instance; a fresh engine is built for every run, so a
    /// toggle takes effect on the next research run with no respawn needed.
    private let useClaudeCustomizations: Bool
    /// Caps for the deterministic post-write image-validation pass (per-image
    /// timeout + overall budget + concurrency). Injectable so tests can shrink them.
    private let imageValidationConfig: ResearchImageValidationConfig
    /// Builds the image-validation fetch seam. Defaults to the real HTTP validator;
    /// tests inject a deterministic fake so the pass never touches the network.
    private let makeImageValidator: () -> ImageURLValidating

    init(
        binaryPath: String,
        homeDirectoryPath: String = NSHomeDirectory(),
        planPhaseTimeoutSeconds: TimeInterval = 120,
        executePhaseTimeoutSeconds: TimeInterval = 600,
        maxBudgetUSD: Double = 5,
        useClaudeCustomizations: Bool = true,
        imageValidationConfig: ResearchImageValidationConfig = .default,
        makeImageValidator: @escaping () -> ImageURLValidating = {
            URLSessionImageURLValidator()
        }
    ) {
        self.binaryPath = binaryPath
        self.homeDirectoryPath = homeDirectoryPath
        self.planPhaseTimeoutSeconds = planPhaseTimeoutSeconds
        self.executePhaseTimeoutSeconds = executePhaseTimeoutSeconds
        self.maxBudgetUSD = maxBudgetUSD
        self.useClaudeCustomizations = useClaudeCustomizations
        self.imageValidationConfig = imageValidationConfig
        self.makeImageValidator = makeImageValidator
    }

    // MARK: - System prompts

    static let planSystemPrompt = """
    you are clawdy's research agent, in its PLANNING phase. the user asked for something that needs deep, multi-source web research that ends in a single self-contained HTML page. you are in plan mode and cannot run tools yet.

    decide whether you genuinely need clarifying information to produce a great result. if and only if essential details are missing, ask at MOST 3 short, specific clarifying questions, then stop and end your turn. if the request is already clear enough, do NOT ask any questions — instead briefly state the plan you'll execute. never ask more than once. either way, END YOUR TURN NOW — do not wait on anything.

    CRITICAL EXECUTION MODEL: in the upcoming execution phase you will do ALL of the research YOURSELF, inline, in a single one-shot turn, using ONLY the WebSearch, WebFetch and Write tools. there is NO background job system here and NO notification will ever arrive. so DO NOT plan to invoke, launch, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin — those never resume in this mode and would hang forever. your plan must be to perform the searches directly and write the HTML yourself. do NOT end your turn saying you'll wait to be notified about a background job.
    """

    static let executeSystemPrompt = """
    you are clawdy's research agent, in its EXECUTION phase. research the task thoroughly using WebSearch and WebFetch, then produce ONE self-contained HTML page and Write it to a file named report.html in the working output directory you've been granted.

    DO ALL OF THIS YOURSELF, INLINE, IN THIS ONE TURN, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run with NO background job system and NO notification will ever arrive — anything you hand off never comes back. so DO NOT invoke, launch, spawn, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified that a background job finished. if you notice yourself about to launch a background workflow or skill, STOP and instead perform the WebSearch/WebFetch calls directly and Write the HTML now, in this turn.

    the HTML MUST keep all of its OWN code inline so it renders with no local dependencies: inline <style> only, no external stylesheet links, no external script src, no CDN references, no remote fonts. the ONE exception is images: when the task is about photos or images, you SHOULD embed the real images you found via <img src="https://..."> pointing at the actual remote image URLs you discovered while researching — that's how the user sees them. use genuine image URLs from your research, not placeholders, and NEVER fabricate or guess an image URL. prefer DIRECT image-file URLs (ones ending in .jpg/.jpeg/.png/.webp/.gif or that clearly serve the raw image file) taken straight from your search results or well-known sources. do NOT WebFetch, open, or otherwise verify image URLs before embedding them — WebFetch on a raw image binary just fails and wastes a tool call; embed the image URL directly. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. reserve WebFetch for reading actual page/article content, not images. everything else stays inline. make it clean, readable, and well organized with clear headings. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents like rules or key highlights, and optionally a very light red background tint — keep it tasteful and restrained, keep body text high-contrast and readable, and never tint photos/images or force red where it hurts legibility. do not write any file other than report.html. when you're done, briefly confirm in your final message.
    """

    static let followUpSystemPrompt = """
    you are clawdy's research agent, continuing a FINISHED research session by voice. the self-contained report.html you already produced is in your context. the user is asking a spoken follow-up. only modify the page if the user explicitly asks you to change it; otherwise just answer their question and write nothing. if you do edit, rewrite the SAME report.html in place (inline <style> only, no external script src, no CDN or remote font references; a remote <img src="https://…"> is allowed for image tasks). end your turn with a concise 1-2 sentence spoken answer or confirmation suitable to read aloud — never read long tool logs or file contents aloud.

    DO ALL OF THIS YOURSELF, INLINE, IN THIS ONE TURN, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run with NO background job system and NO notification will ever arrive — anything you hand off never comes back. so DO NOT invoke, launch, spawn, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified that a background job finished. if you notice yourself about to launch a background workflow or skill, STOP and instead perform the WebSearch/WebFetch calls directly and Write the HTML now, in this turn.
    """

    /// The deterministic deliverable filename the execute prompt instructs the
    /// model to write. Used to locate the produced page afterward.
    static let deliverableFileName = "report.html"

    // MARK: - Stable per-session output directory (durable, never $HOME)

    /// Resolves `~/Library/Application Support` on this machine, falling back to a
    /// path derived from HOME if the lookup ever fails. Injectable base for the
    /// research directory tree so tests can point it at a temp location.
    static func defaultApplicationSupportDirectory() -> URL {
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// The root of Clawdy's durable research storage:
    /// `<Application Support>/Clawdy/research`. Per-session directories and the
    /// manifest.json both live directly under here.
    static func researchSupportDirectory(
        applicationSupportDirectory: URL = defaultApplicationSupportDirectory()
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Clawdy", isDirectory: true)
            .appendingPathComponent("research", isDirectory: true)
    }

    /// Derives the STABLE per-session working directory for `sessionID`:
    /// `<Application Support>/Clawdy/research/<sessionId>/`. Pure (no filesystem
    /// side effects) so the derivation is unit-testable; use `makeSessionOutputDirectory`
    /// to also create it on disk. This directory is the CWD for BOTH the plan and
    /// execute phases so `--resume <sessionId>` resolves (Claude Code keys sessions
    /// by working directory), and — unlike the old throwaway temp dir — it persists
    /// so the session stays resumable for the future continue-conversation feature.
    static func sessionOutputDirectory(
        sessionID: String,
        applicationSupportDirectory: URL = defaultApplicationSupportDirectory()
    ) -> URL {
        researchSupportDirectory(applicationSupportDirectory: applicationSupportDirectory)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    /// Creates (if needed) and returns the stable per-session output directory. NOT
    /// deleted afterward — the deliverable and the resumable session both live here.
    static func makeSessionOutputDirectory(
        sessionID: String,
        applicationSupportDirectory: URL = defaultApplicationSupportDirectory()
    ) throws -> URL {
        let directory = sessionOutputDirectory(
            sessionID: sessionID,
            applicationSupportDirectory: applicationSupportDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Transcript path derivation (Claude Code's on-disk layout)

    /// Sanitizes a working-directory path into the folder name Claude Code uses
    /// under `~/.claude/projects/`. Empirically (claude 2.1.198) each `/`, `.`, and
    /// whitespace character in the CWD is replaced by `-`; everything else — letters,
    /// digits, and the hyphens in a UUID — is preserved verbatim. Example:
    /// `/Users/x/Library/Application Support/Clawdy/research/<id>` →
    /// `-Users-x-Library-Application-Support-Clawdy-research-<id>`.
    static func sanitizedProjectDirectoryName(forWorkingDirectoryPath workingDirectoryPath: String) -> String {
        var sanitized = ""
        for character in workingDirectoryPath {
            if character == "/" || character == "." || character.isWhitespace {
                sanitized.append("-")
            } else {
                sanitized.append(character)
            }
        }
        return sanitized
    }

    /// The absolute path Claude Code persists a session's transcript at:
    /// `<home>/.claude/projects/<sanitized working dir>/<sessionId>.jsonl`. Recorded
    /// in the manifest so the future History UI can read the transcript directly.
    static func claudeTranscriptPath(
        sessionID: String,
        workingDirectoryPath: String,
        homeDirectoryPath: String
    ) -> String {
        let projectDirectoryName = sanitizedProjectDirectoryName(forWorkingDirectoryPath: workingDirectoryPath)
        return URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
            .path
    }

    // MARK: - Phase 1: plan / clarify

    /// Runs the plan/clarify phase and returns the session id plus the decision of
    /// whether the user needs to answer clarifying questions first. Cancelling the
    /// awaiting Task SIGTERMs ONLY this research process.
    ///
    /// CRITICAL: this phase MUST run with the SAME working directory the execute
    /// phase resumes from (`outputDirectory`), NOT $HOME. Claude Code persists each
    /// session under a project keyed by the process's current directory, and
    /// `--resume <session_id>` only finds a session whose project matches the CWD it
    /// resumes in. When the plan phase ran in $HOME while execute ran in the temp
    /// output dir, `--resume` failed with "No conversation found with session ID"
    /// (exit 1 → `phaseFailed`) and no research ever completed. HOME stays set in the
    /// environment for subscription auth — only the CWD is scoped to the run dir.
    ///
    /// `sessionID` is PRE-MINTED by the caller and passed as `--session-id` so we own
    /// the id before the run starts (claude echoes it back verbatim — verified against
    /// the real CLI). The execute phase resumes this same id via `--resume`, and both
    /// phases append to the one `<sessionId>.jsonl` transcript.
    func runPlanPhase(
        task: String,
        sessionID: String,
        outputDirectory: URL,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> PlanPhaseResult {
        let arguments = ResearchArguments.makePlanArguments(
            task: task,
            sessionID: sessionID,
            systemPrompt: Self.planSystemPrompt,
            useClaudeCustomizations: useClaudeCustomizations
        )
        let accumulator = ResearchStreamAccumulator()

        let runResult = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            // Same CWD as the execute phase so the resumable session lands in the
            // project the execute phase's `--resume` will look it up under.
            workingDirectoryPath: outputDirectory.path,
            environment: CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath),
            standardInput: nil,
            timeoutSeconds: planPhaseTimeoutSeconds,
            onStandardOutputLine: { line in
                accumulator.ingest(line: line, onProgress: onProgress)
            }
        )

        guard runResult.exitCode == 0 else {
            throw ResearchError.phaseFailed(standardError: runResult.standardError)
        }
        guard let sessionID = accumulator.sessionID else {
            throw ResearchError.noSessionID
        }

        let outcome = ResearchPlanAnalyzer.analyze(
            planResultText: accumulator.lastResultText ?? "",
            toolUseCount: accumulator.toolUseCount
        )
        return PlanPhaseResult(sessionID: sessionID, outcome: outcome)
    }

    // MARK: - Phase 2: execute

    /// Resumes the plan session and runs the autonomous execute phase, returning
    /// the file URL of the produced HTML deliverable. `clarificationAnswers` is the
    /// user's typed reply when the plan phase asked questions (nil when it didn't).
    /// Cancelling the awaiting Task SIGTERMs ONLY this research process.
    func runExecutePhase(
        sessionID: String,
        outputDirectory: URL,
        clarificationAnswers: String?,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> URL {
        // The absolute deliverable path, so discovery is unambiguous regardless of
        // the model's working directory.
        let deliverableAbsolutePath = outputDirectory.appendingPathComponent(Self.deliverableFileName).path
        let userMessage = Self.composeExecuteUserMessage(
            outputFileAbsolutePath: deliverableAbsolutePath,
            clarificationAnswers: clarificationAnswers
        )
        let arguments = ResearchArguments.makeExecuteArguments(
            sessionID: sessionID,
            outputDirectoryPath: outputDirectory.path,
            maxBudgetUSD: maxBudgetUSD,
            userMessage: userMessage,
            systemPrompt: Self.executeSystemPrompt,
            useClaudeCustomizations: useClaudeCustomizations
        )
        let accumulator = ResearchStreamAccumulator()

        let runResult = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            // CWD is the per-run temp dir (NOT $HOME), so the file sandbox is scoped
            // to it and a relative `report.html` lands there. HOME stays set in the
            // environment for subscription auth — only the CWD changes.
            workingDirectoryPath: outputDirectory.path,
            environment: CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath),
            standardInput: nil,
            timeoutSeconds: executePhaseTimeoutSeconds,
            onStandardOutputLine: { line in
                accumulator.ingest(line: line, onProgress: onProgress)
            }
        )

        guard runResult.exitCode == 0 else {
            throw ResearchError.phaseFailed(standardError: runResult.standardError)
        }
        guard let deliverableURL = Self.locateDeliverable(in: outputDirectory) else {
            throw ResearchError.noDeliverableProduced
        }
        // DETERMINISTIC image-validation pass: before the page is ever shown, fetch
        // every embedded remote <img> and rewrite report.html so any broken image is
        // an OpenClaw-red "Image unavailable" placeholder instead of a browser
        // broken-image icon. Time-bounded (never hangs the run); skipped if the run
        // was cancelled while draining.
        if !Task.isCancelled {
            await validateDeliverableImages(fileURL: deliverableURL)
        }
        return deliverableURL
    }

    /// Runs the deterministic image-validation pass over a just-produced (or
    /// just-rewritten) deliverable. Time-bounded by `imageValidationConfig` so it can
    /// never hang the research run; a no-op when the page has no remote images.
    private func validateDeliverableImages(fileURL: URL) async {
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: fileURL,
            validator: makeImageValidator(),
            config: imageValidationConfig
        )
    }

    // MARK: - Phase 3: voice-native follow-up (continue the finished session)

    /// Resumes THIS finished session's own `claude` thread with the SPOKEN follow-up
    /// as the user message (NOT the fixed execute instruction), using the SAME
    /// execute-phase arg set (`--resume <id> --permission-mode acceptEdits
    /// --allowedTools WebSearch WebFetch Write --add-dir <dir> --max-budget-usd 5`).
    /// Because the finished page is already in the resumed transcript's context, a
    /// pure QUESTION is answered accurately with no file tools; an ITERATE request
    /// rewrites the same report.html in place. Billing stays subscription (no
    /// `--bare`). Cancelling the awaiting Task SIGTERMs ONLY this research process.
    ///
    /// Whether the page changed is detected purely from report.html's modification
    /// date across the turn (Write replaces the file, so its mtime advances) — a
    /// question that writes nothing leaves it untouched. The caller drives the
    /// results-window reload off this boolean (not a file-watcher), because the
    /// iteration replaces the inode.
    func runFollowUpPhase(
        sessionID: String,
        outputDirectory: URL,
        followUpPrompt: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> FollowUpPhaseResult {
        let deliverableAbsolutePath = outputDirectory.appendingPathComponent(Self.deliverableFileName).path
        let modificationDateBeforeTurn = Self.deliverableModificationDate(atPath: deliverableAbsolutePath)

        let userMessage = Self.composeFollowUpUserMessage(
            spokenFollowUp: followUpPrompt,
            outputFileAbsolutePath: deliverableAbsolutePath
        )
        // The SAME execute-phase arg vector — only the user message and system prompt
        // differ (the spoken follow-up instead of the fixed "proceed" instruction).
        let arguments = ResearchArguments.makeExecuteArguments(
            sessionID: sessionID,
            outputDirectoryPath: outputDirectory.path,
            maxBudgetUSD: maxBudgetUSD,
            userMessage: userMessage,
            systemPrompt: Self.followUpSystemPrompt,
            useClaudeCustomizations: useClaudeCustomizations
        )
        let accumulator = ResearchStreamAccumulator()

        let runResult = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            // Same stable per-session CWD both prior phases used, so `--resume`
            // resolves this session's project. HOME stays set for subscription auth.
            workingDirectoryPath: outputDirectory.path,
            environment: CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath),
            standardInput: nil,
            timeoutSeconds: executePhaseTimeoutSeconds,
            onStandardOutputLine: { line in
                accumulator.ingest(line: line, onProgress: onProgress)
            }
        )

        guard runResult.exitCode == 0 else {
            throw ResearchError.phaseFailed(standardError: runResult.standardError)
        }

        // Unlike execute, a follow-up need NOT produce a deliverable (a pure question
        // writes nothing) — so we do NOT throw `noDeliverableProduced`. We just report
        // whether the page changed this turn.
        let modificationDateAfterTurn = Self.deliverableModificationDate(atPath: deliverableAbsolutePath)
        let deliverableWasRewritten = Self.deliverableWasRewritten(
            modificationDateBeforeTurn: modificationDateBeforeTurn,
            modificationDateAfterTurn: modificationDateAfterTurn
        )
        // An ITERATE follow-up rewrote report.html — re-run the same deterministic
        // image-validation pass so a newly-embedded broken image can't slip through
        // on the iteration. (A pure QUESTION writes nothing, so there's nothing to
        // re-validate.) Runs before the caller reloads the WKWebView.
        if deliverableWasRewritten, !Task.isCancelled {
            await validateDeliverableImages(fileURL: URL(fileURLWithPath: deliverableAbsolutePath))
        }
        return FollowUpPhaseResult(
            spokenAnswer: accumulator.lastResultText,
            deliverableWasRewritten: deliverableWasRewritten,
            deliverableURL: Self.locateDeliverable(in: outputDirectory)
        )
    }

    /// Composes the follow-up-turn user message: the user's SPOKEN follow-up leads
    /// verbatim (so the model answers or iterates on exactly what was said), followed
    /// by the constraint that the page is only touched on an explicit change request
    /// and, if it is, rewritten in place at the absolute path. The trailing line asks
    /// for a short spoken answer/confirmation so TTS never reads long tool logs aloud.
    static func composeFollowUpUserMessage(
        spokenFollowUp: String,
        outputFileAbsolutePath: String
    ) -> String {
        let trimmedFollowUp = spokenFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = """
        the research page you produced is at \(outputFileAbsolutePath). only modify the page if I asked you to change it; otherwise just answer my question and write nothing. if you DO change it, rewrite that same report.html in place. keep it short: end with a 1-2 sentence spoken summary/answer suitable to read aloud, and don't read long tool output or file contents aloud.
        """
        if trimmedFollowUp.isEmpty {
            return instructions
        }
        return trimmedFollowUp + "\n\n" + instructions
    }

    /// The current modification date of report.html, or nil if it doesn't exist yet.
    static func deliverableModificationDate(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    /// Whether the deliverable changed across a follow-up turn, from its modification
    /// date before vs. after. Newly created (before nil, after present) or advanced
    /// mtime → rewritten; unchanged or absent → not rewritten (a pure question).
    static func deliverableWasRewritten(
        modificationDateBeforeTurn: Date?,
        modificationDateAfterTurn: Date?
    ) -> Bool {
        guard let modificationDateAfterTurn else { return false }
        guard let modificationDateBeforeTurn else { return true }
        return modificationDateAfterTurn > modificationDateBeforeTurn
    }

    /// Composes the resume-phase user message. CRITICAL: every execute-phase
    /// constraint is folded in HERE, because the `-p` user message is the channel
    /// that is guaranteed to be delivered on `--resume` — we do NOT depend on
    /// `--append-system-prompt` being applied to a resumed session (empirically it
    /// IS honored on the current CLI, but correctness must not hinge on it). So the
    /// message itself instructs the model to run its tools now, to produce ONE
    /// self-contained page (inline `<style>` only, no external CDN/JS/CSS), and to
    /// write it to the ABSOLUTE output path (so discovery is unambiguous regardless
    /// of the working directory). The user's clarifying answers (if any) lead.
    static func composeExecuteUserMessage(
        outputFileAbsolutePath: String,
        clarificationAnswers: String?
    ) -> String {
        let executeInstructions = """
        proceed with the research now, yourself, inline, in THIS one turn, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run: there is NO background job system and NO notification will ever arrive, so DO NOT invoke, launch, or delegate to any background task, skill, workflow, agent, sub-agent, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified about a background job — if you catch yourself about to launch one, instead run the searches directly and write the HTML now. use WebSearch and WebFetch to research the task thoroughly, then write ONE self-contained HTML page to the absolute path \(outputFileAbsolutePath). the page MUST keep all of its OWN code inline: inline <style> only, no external stylesheet links, no external script src, no CDN or remote font references. the ONE exception is images — when the task is about photos or images, embed the real images you found via <img src="https://..."> using the actual remote image URLs you discovered while researching (genuine URLs, not placeholders), so the user can actually see them. NEVER fabricate or guess an image URL: prefer DIRECT image-file URLs (ending in .jpg/.jpeg/.png/.webp/.gif or that clearly serve the raw image) taken straight from your search results or well-known sources. do NOT WebFetch, open, or otherwise verify image URLs before embedding them — WebFetch on a raw image binary just fails and wastes a tool call; embed the image URL directly. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. reserve WebFetch for reading actual page/article content, not images. everything else stays inline. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents, and optionally a very light red background tint — keep it tasteful, keep body text high-contrast and readable, and never tint photos/images or force red where it hurts legibility. do not write any file other than that one report.html. when you're done, briefly confirm.
        """
        if let answers = clarificationAnswers?.trimmingCharacters(in: .whitespacesAndNewlines), !answers.isEmpty {
            return answers + "\n\n" + executeInstructions
        }
        return executeInstructions
    }

    /// Finds the produced HTML deliverable in the output directory: the expected
    /// report.html if present, otherwise the most recently modified .html file.
    static func locateDeliverable(in outputDirectory: URL) -> URL? {
        let expected = outputDirectory.appendingPathComponent(deliverableFileName)
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let htmlFiles = contents.filter { $0.pathExtension.lowercased() == "html" }
        return htmlFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }.first
    }
}

/// Thread-safe accumulator that parses research stream-json lines on the
/// background reader thread, captures the session id / tool-use count / last
/// result text, and forwards coarse progress events to the main actor. `append`
/// runs on the reader thread; the captured fields are read after the run's drain
/// barrier, so a plain lock is sufficient.
private final class ResearchStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionID: String?
    private var _toolUseCount = 0
    private var _lastResultText: String?

    var sessionID: String? { lock.lock(); defer { lock.unlock() }; return _sessionID }
    var toolUseCount: Int { lock.lock(); defer { lock.unlock() }; return _toolUseCount }
    var lastResultText: String? { lock.lock(); defer { lock.unlock() }; return _lastResultText }

    func ingest(
        line: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) {
        switch ResearchStreamParser.parse(line: line) {
        case .sessionStarted(let sessionID):
            lock.lock(); _sessionID = sessionID; lock.unlock()
        case .progress(let progressEvent):
            lock.lock(); _toolUseCount += 1; lock.unlock()
            Task { @MainActor in onProgress(progressEvent) }
        case .result(let text, _):
            lock.lock(); _lastResultText = text; lock.unlock()
        case .assistantText, .ignored:
            break
        }
    }
}
