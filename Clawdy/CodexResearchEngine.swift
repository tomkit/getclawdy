//
//  CodexResearchEngine.swift
//  Clawdy
//
//  The DEDICATED, SEPARATE Codex research subsystem: a stand-alone `codex exec`
//  process (its own process / task / state), fully isolated from the warm
//  quick-answer session and from every other research run. Selected when the user's
//  chosen coach engine is Codex; the Claude research path (`ClaudeResearchEngine`) is
//  entirely untouched by this file.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  v1 HARD LIMITS (single-turn Codex research parity — deliberately minimal):
//   • NO plan/clarify phase. `runPlanPhase` returns `.readyToExecute` IMMEDIATELY
//     without launching anything (`supportsPlanPhase == false`). Codex goes straight
//     to a single autonomous execute turn.
//   • The session id is the Codex `thread_id`, read POST-HOC from the `thread.started`
//     event — it CANNOT be pre-minted (`supportsPreMintedSessionID == false`). The
//     per-run directory is therefore keyed by a CLIENT-minted run id (the `sessionID`
//     the manager passes in), NOT by the thread id. The captured thread id is stored
//     as the RESUME handle for follow-ups.
//   • NO streaming TTS — `codex exec --json` carries no token deltas (not applicable to
//     research anyway; the final answer arrives whole in the `agent_message` item).
//   • Spend is bounded by the EXECUTE-PHASE TIMEOUT only — Codex has no
//     `--max-budget-usd` equivalent.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  The single execute turn runs (see CodexResearchArguments for the exact vector):
//
//    codex exec -s workspace-write -C <dir> --add-dir <dir> -c tools.web_search=true --json -
//
//  in a WORKSPACE-WRITE sandbox scoped to the per-run directory, so it can research
//  the web (the real `web_search` tool) AND write ONE self-contained `report.html`.
//  Codex `exec` has no system-prompt flag, so ALL research instructions are folded
//  into the stdin prompt. A follow-up continues the same thread via
//  `codex exec resume <thread_id> --json -` (which inherits the first turn's sandbox).
//

import Foundation

final class CodexResearchEngine: ResearchEngine {
    // MARK: - ResearchEngine capabilities

    /// Codex has NO `--session-id` flag: the thread id is discovered post-hoc from the
    /// run's `thread.started` event, so the caller cannot own it before the run.
    var supportsPreMintedSessionID: Bool { false }

    /// Codex v1 goes straight to a single execute turn — there is no distinct plan /
    /// clarify phase.
    var supportsPlanPhase: Bool { false }

    enum ResearchError: LocalizedError {
        case noThreadIDForFollowUp
        case noDeliverableProduced
        case phaseFailed(standardError: String)

        var errorDescription: String? {
            switch self {
            case .noThreadIDForFollowUp:
                return "Couldn't continue the research session."
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

    private let binaryPath: String
    private let homeDirectoryPath: String
    /// Wall-clock cap for the single execute turn (and each follow-up turn). This is the
    /// ONLY spend bound Codex offers — there is no `--max-budget-usd`. Enforced by
    /// CLIProcessRunner, which terminates the child when it elapses.
    private let executePhaseTimeoutSeconds: TimeInterval
    /// The manifest index the captured Codex `thread_id` is PERSISTED to the moment the
    /// execute turn discovers it — so the resume handle survives app relaunch instead of
    /// living only in this engine's memory (the gap that blocked Codex reconstruction /
    /// resume). Defaults to `.shared`, the same store the research session/manager use in
    /// production, so both write the SAME `manifest.json`; tests inject a temp store.
    private let manifestStore: ResearchManifestStore
    /// Caps for the deterministic post-write image-validation pass (per-image
    /// timeout + overall budget + concurrency). Injectable so tests can shrink them.
    /// SAME pass the Claude engine runs — this is what makes the execute prompt's
    /// "broken images are handled automatically" promise TRUE for Codex too.
    private let imageValidationConfig: ResearchImageValidationConfig
    /// Builds the image-validation fetch seam. Defaults to the real HTTP validator;
    /// tests inject a deterministic fake so the pass never touches the network.
    private let makeImageValidator: () -> ImageURLValidating

    /// Per-run mutable state, lock-guarded because it is written across the (nonisolated,
    /// async) engine methods and read on the main-actor follow-up path:
    ///  - `researchTask`: the task text captured in the no-op `runPlanPhase` and folded
    ///    into the execute stdin prompt so Codex knows WHAT to research (Codex has no
    ///    system-prompt flag and `runExecutePhase` is not handed the task directly).
    ///  - `capturedThreadID`: the Codex `thread_id`, read POST-HOC from the execute turn's
    ///    `thread.started` event and used as the `--resume` handle for follow-ups.
    private let stateLock = NSLock()
    private var researchTaskStorage: String = ""
    private var capturedThreadIDStorage: String?

    private var researchTask: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return researchTaskStorage
    }

    private func rememberResearchTask(_ task: String) {
        stateLock.lock(); researchTaskStorage = task; stateLock.unlock()
    }

    private var capturedThreadID: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return capturedThreadIDStorage
    }

    private func rememberThreadID(_ threadID: String) {
        stateLock.lock(); capturedThreadIDStorage = threadID; stateLock.unlock()
    }

    /// Whether this engine can resume its session for a follow-up turn right now: only
    /// when the execute turn actually captured a `thread_id` from `thread.started`. If it
    /// didn't (a missing/drifted event), the run's deliverable still works but no
    /// follow-up can resume it — so the session is marked NON-FOLLOWABLE (the composer /
    /// Send is not offered) rather than offering a Send that would fail.
    var canResumeForFollowUp: Bool { capturedThreadID != nil }

    /// Seeds the Codex `thread_id` RESUME handle when a finished Codex run is RECONSTRUCTED
    /// from the manifest (a page followed up on from History, or after an app relaunch) into
    /// a freshly-built engine that never ran the original execute turn — so it never captured
    /// a thread id of its own. The manager passes the persisted `codexThreadId` (or the id it
    /// recovered from the transcript path). Once seeded, `canResumeForFollowUp` becomes true
    /// and `runFollowUpPhase` can `codex exec resume <thread_id>`. Ignores an empty handle so
    /// a bad manifest value can't mark a run followable with nothing to resume.
    func adoptResumeHandle(_ resumeHandle: String) {
        guard !resumeHandle.isEmpty else { return }
        rememberThreadID(resumeHandle)
    }

    init(
        binaryPath: String,
        homeDirectoryPath: String = NSHomeDirectory(),
        executePhaseTimeoutSeconds: TimeInterval = 600,
        manifestStore: ResearchManifestStore = .shared,
        imageValidationConfig: ResearchImageValidationConfig = .default,
        makeImageValidator: @escaping () -> ImageURLValidating = {
            URLSessionImageURLValidator()
        }
    ) {
        self.binaryPath = binaryPath
        self.homeDirectoryPath = homeDirectoryPath
        self.executePhaseTimeoutSeconds = executePhaseTimeoutSeconds
        self.manifestStore = manifestStore
        self.imageValidationConfig = imageValidationConfig
        self.makeImageValidator = makeImageValidator
    }

    /// The deterministic deliverable filename the execute prompt instructs Codex to
    /// write. Used to locate the produced page afterward.
    static let deliverableFileName = "report.html"

    // MARK: - Stable per-session output directory (durable, keyed by the client run id)

    /// Resolves (if needed) and returns the STABLE per-run working directory under
    /// `~/Library/Application Support/Clawdy/research/<runID>/`, where `runID` is the
    /// CLIENT-minted `sessionID` the manager passes in (Codex's own thread id isn't
    /// known until the run starts, so it can't name the directory). Shares the same
    /// durable research tree as the Claude engine so History/recents index both the
    /// same way.
    func makeSessionOutputDirectory(sessionID: String, applicationSupportDirectory: URL) throws -> URL {
        let directory = ClaudeResearchEngine.sessionOutputDirectory(
            sessionID: sessionID,
            applicationSupportDirectory: applicationSupportDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Codex learns its `thread_id` only AFTER the execute turn starts, so at RUN-START
    /// this returns nil (the manifest records an empty transcript path until then). Once
    /// the execute turn has captured a thread id, a SECOND call resolves the transcript by
    /// globbing `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl` — the
    /// session re-calls this after execute completes to fill in the manifest so History can
    /// show the Codex transcript. Nil until the rollout file exists (the "or nil until
    /// resolvable" contract).
    func transcriptPath(sessionID: String, outputDirectory: URL) -> String? {
        guard let threadID = capturedThreadID else { return nil }
        return Self.codexTranscriptPath(
            forThreadID: threadID,
            sessionsDirectory: Self.codexSessionsDirectory(homeDirectoryPath: homeDirectoryPath)
        )
    }

    /// The root of Codex's on-disk session store: `~/.codex/sessions`. Injectable base
    /// so the transcript-glob is unit-testable against a temp tree.
    static func codexSessionsDirectory(homeDirectoryPath: String) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Locates the transcript for `threadID` by GLOBBING the Codex sessions tree for a
    /// `rollout-*-<threadID>.jsonl` file (the date-partitioned layout means we can't
    /// derive the exact path, only recognize it). Returns the first match's absolute
    /// path, or nil when no transcript exists yet — the "or nil until resolvable"
    /// contract. Pure (read-only filesystem walk) so it's unit-testable.
    static func codexTranscriptPath(forThreadID threadID: String, sessionsDirectory: URL) -> String? {
        let expectedSuffix = "-\(threadID).jsonl"
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasPrefix("rollout-") && name.hasSuffix(expectedSuffix) {
                return fileURL.path
            }
        }
        return nil
    }

    /// Recovers the Codex `thread_id` encoded in a stored rollout transcript PATH of the
    /// form `.../rollout-<timestamp>-<thread_id>.jsonl` (Codex's on-disk filename
    /// convention, where `<timestamp>` is `YYYY-MM-DDThh-mm-ss`). This is the FALLBACK
    /// recovery for Codex runs recorded BEFORE the thread id was persisted explicitly to
    /// the manifest (`ResearchManifestEntry.codexThreadId`) — those entries only carry the
    /// transcript path, and this extracts the id from it. Returns nil for any path whose
    /// filename doesn't match the rollout convention (e.g. an empty path, a Claude
    /// `<id>.jsonl`, or a non-transcript path). Pure (string in, value out) — the inverse
    /// of `codexTranscriptPath` — so it's unit-testable with no filesystem.
    static func threadID(fromTranscriptPath transcriptPath: String) -> String? {
        // Match on just the last path component so a leading directory can't fool the
        // convention check.
        let fileName = (transcriptPath as NSString).lastPathComponent
        // The thread id is everything AFTER the fixed-width `rollout-<timestamp>-` prefix
        // and before the `.jsonl` extension. The timestamp is a rigid numeric shape, so
        // anchoring on it lets the thread id itself contain hyphens (a UUID does).
        let pattern = "^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-(.+)\\.jsonl$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let match = regex.firstMatch(in: fileName, range: range),
              let threadIDRange = Range(match.range(at: 1), in: fileName) else {
            return nil
        }
        return String(fileName[threadIDRange])
    }

    // MARK: - Phase 1: plan (v1 = immediate proceed, no clarify)

    /// Codex v1 has NO plan/clarify phase — this returns `.readyToExecute` IMMEDIATELY
    /// without launching any process. It PERSISTS the `task` on the engine so the execute
    /// turn can fold it into the stdin prompt (Codex has no system-prompt flag, and
    /// `runExecutePhase` is not handed the task directly). The `sessionID` echoed back is
    /// the client run id the caller passed in (there is nothing to resume yet; the real
    /// Codex thread id is captured during the execute turn). `onProgress` is unused here.
    func runPlanPhase(
        task: String,
        sessionID: String,
        outputDirectory: URL,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> PlanPhaseResult {
        rememberResearchTask(task)
        return PlanPhaseResult(sessionID: sessionID, outcome: .readyToExecute)
    }

    // MARK: - Phase 2: execute (the single autonomous Codex turn)

    /// Runs the ONE autonomous Codex research turn: research the web and write one
    /// self-contained `report.html` into `outputDirectory`. Captures the `thread_id`
    /// from the `thread.started` event as the resume handle. Returns the file URL of the
    /// produced deliverable. `clarificationAnswers` is always nil in v1 (no clarify) but
    /// is honored (folded into the prompt) if ever supplied. Cancelling the awaiting
    /// Task SIGTERMs ONLY this research process.
    func runExecutePhase(
        sessionID: String,
        outputDirectory: URL,
        clarificationAnswers: String?,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> URL {
        let deliverableAbsolutePath = outputDirectory.appendingPathComponent(Self.deliverableFileName).path
        let prompt = Self.composeExecutePrompt(
            task: researchTask,
            outputFileAbsolutePath: deliverableAbsolutePath,
            clarificationAnswers: clarificationAnswers
        )
        let arguments = CodexResearchArguments.makeExecuteArguments(outputDirectoryPath: outputDirectory.path)
        // Capture + PERSIST the thread id (the resume handle) the INSTANT it is ingested
        // from `thread.started`, NOT after the run returns. A run that emits thread.started
        // and then TIMES OUT or is CANCELLED makes `CLIProcessRunner.run` THROW — so any
        // persist placed after the await would be skipped precisely in the partial-run case
        // this stage exists to cover. Firing from the ingestion callback (which runs while
        // stdout is still draining, before the throw) means a started-then-killed run still
        // leaves a persisted, resumable thread id. Keyed by the client run id, which IS this
        // run's manifest `sessionId`. The callback fires at most once (first capture only,
        // so no double-write); `recordCodexThreadID` ignores an empty id and is a no-op if
        // the run's entry isn't indexed yet, so it never races the session's own writes.
        let accumulator = CodexResearchStreamAccumulator(onThreadIDCaptured: { [weak self] threadID in
            guard let self else { return }
            self.rememberThreadID(threadID)
            self.manifestStore.recordCodexThreadID(sessionId: sessionID, threadID: threadID)
        })

        let runResult = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            // CWD is the per-run dir (matches `-C`), so a relative write lands there and
            // the file sandbox is scoped to it. HOME stays set for subscription auth.
            workingDirectoryPath: outputDirectory.path,
            environment: CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath),
            standardInput: prompt,
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
        // DETERMINISTIC image-validation pass (same as the Claude engine): before the
        // page is ever shown, fetch every embedded remote <img> and rewrite report.html
        // so any broken image becomes an inline "Image unavailable" placeholder. This is
        // what makes the execute prompt's "broken images are handled automatically"
        // promise true for Codex. Time-bounded (never hangs the run); skipped if the run
        // was cancelled while draining.
        if !Task.isCancelled {
            await validateDeliverableImages(fileURL: deliverableURL)
        }
        return deliverableURL
    }

    /// Runs the deterministic image-validation pass over a just-produced (or
    /// just-rewritten) deliverable. Time-bounded by `imageValidationConfig` so it can
    /// never hang the research run; a no-op when the page has no remote images; never
    /// throws. Mirrors `ClaudeResearchEngine.validateDeliverableImages`.
    private func validateDeliverableImages(fileURL: URL) async {
        await ResearchImageValidator.validateAndRewriteDeliverable(
            fileURL: fileURL,
            validator: makeImageValidator(),
            config: imageValidationConfig
        )
    }

    // MARK: - Phase 3: voice-native follow-up (continue THIS thread)

    /// Continues THIS run's Codex thread with a spoken/typed follow-up:
    /// `codex exec resume <thread_id> --json -` with the follow-up prompt on stdin. The
    /// resumed turn inherits the first turn's workspace-write sandbox + directory, so it
    /// can answer a question (writing nothing) or iterate on the page (rewriting the same
    /// report.html). Whether the page changed is detected from report.html's modification
    /// date across the turn (same signal the Claude engine uses). Throws if no thread id
    /// was captured (the execute turn never produced one to resume).
    func runFollowUpPhase(
        sessionID: String,
        outputDirectory: URL,
        followUpPrompt: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> FollowUpPhaseResult {
        guard let threadID = capturedThreadID else {
            throw ResearchError.noThreadIDForFollowUp
        }
        let deliverableAbsolutePath = outputDirectory.appendingPathComponent(Self.deliverableFileName).path
        let modificationDateBeforeTurn = Self.deliverableModificationDate(atPath: deliverableAbsolutePath)

        let prompt = Self.composeFollowUpPrompt(
            spokenFollowUp: followUpPrompt,
            outputFileAbsolutePath: deliverableAbsolutePath
        )
        let arguments = CodexResearchArguments.makeResumeFollowUpArguments(threadID: threadID)
        let accumulator = CodexResearchStreamAccumulator()

        let runResult = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            workingDirectoryPath: outputDirectory.path,
            environment: CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath),
            standardInput: prompt,
            timeoutSeconds: executePhaseTimeoutSeconds,
            onStandardOutputLine: { line in
                accumulator.ingest(line: line, onProgress: onProgress)
            }
        )

        guard runResult.exitCode == 0 else {
            throw ResearchError.phaseFailed(standardError: runResult.standardError)
        }

        let modificationDateAfterTurn = Self.deliverableModificationDate(atPath: deliverableAbsolutePath)
        let deliverableWasRewritten = ClaudeResearchEngine.deliverableWasRewritten(
            modificationDateBeforeTurn: modificationDateBeforeTurn,
            modificationDateAfterTurn: modificationDateAfterTurn
        )
        // An ITERATE follow-up rewrote report.html — re-run the same deterministic
        // image-validation pass so a newly-embedded broken image can't slip through on
        // the iteration. (A pure QUESTION writes nothing, so there's nothing to
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

    // MARK: - Prompt composition (Codex has no system-prompt flag → fold into stdin)

    /// Composes the single execute turn's stdin prompt. Because Codex `exec` has no
    /// system-prompt flag, the `task` AND all research constraints are folded in here:
    /// the requested `task` leads (so Codex knows exactly WHAT to research), then do the
    /// web research NOW (inline, this turn), then write ONE self-contained `report.html`
    /// (inline `<style>` only, no CDN/JS/remote fonts; remote `<img>` allowed for image
    /// tasks) to the ABSOLUTE output path so discovery is unambiguous. The user's
    /// clarifying answers (if any) follow the task.
    static func composeExecutePrompt(
        task: String,
        outputFileAbsolutePath: String,
        clarificationAnswers: String?
    ) -> String {
        let instructions = """
        you are clawdy's research agent. research the task thoroughly using web search NOW, in THIS one turn, yourself — do the searches and reading directly, do not defer or wait to be notified about any background job. then write ONE self-contained HTML page to the absolute path \(outputFileAbsolutePath). the page MUST keep all of its OWN code inline so it renders with no local dependencies: inline <style> only, no external stylesheet links, no external script src, no CDN or remote font references. the ONE exception is images — when the task is about photos or images, embed the real images you found via <img src="https://..."> using the actual remote image URLs you discovered while researching (genuine URLs, not placeholders), so the user can actually see them. NEVER fabricate or guess an image URL. do NOT open, fetch, or otherwise verify image URLs before embedding them — that just wastes a tool call; embed the image URL directly from your search results. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents, and optionally a very light red background tint — keep it tasteful, keep body text high-contrast and readable, and never tint photos/images. do not write any file other than that one report.html. when you're done, briefly confirm in your final message.
        """
        // The TASK leads so Codex knows what to research; then the clarifying answers (if
        // any); then the fixed research/output constraints.
        var sections: [String] = []
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTask.isEmpty {
            sections.append("research task: \(trimmedTask)")
        }
        if let answers = clarificationAnswers?.trimmingCharacters(in: .whitespacesAndNewlines), !answers.isEmpty {
            sections.append(answers)
        }
        sections.append(instructions)
        return sections.joined(separator: "\n\n")
    }

    /// Composes a follow-up turn's stdin prompt: the user's spoken/typed follow-up leads
    /// verbatim, followed by the constraint that the page is touched ONLY on an explicit
    /// change request and, if it is, rewritten in place at the absolute path. The trailing
    /// line asks for a short spoken answer so TTS never reads long tool logs aloud.
    static func composeFollowUpPrompt(
        spokenFollowUp: String,
        outputFileAbsolutePath: String
    ) -> String {
        let trimmedFollowUp = spokenFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = """
        the research page you produced is at \(outputFileAbsolutePath). only modify the page if I asked you to change it; otherwise just answer my question and write nothing. if you DO change it, rewrite that same report.html in place (inline <style> only, no external script src, no CDN or remote font references; a remote <img src="https://…"> is allowed for image tasks). do the work inline in THIS turn — do not defer to any background job. keep it short: end with a 1-2 sentence spoken summary/answer suitable to read aloud, and don't read long tool output or file contents aloud.
        """
        if trimmedFollowUp.isEmpty {
            return instructions
        }
        return trimmedFollowUp + "\n\n" + instructions
    }

    // MARK: - Deliverable location + mtime helpers

    /// The current modification date of report.html, or nil if it doesn't exist yet.
    static func deliverableModificationDate(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
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

/// Thread-safe accumulator that parses Codex research stream lines on the background
/// reader thread, captures the thread id / tool-use count / last result text, and
/// forwards coarse progress events to the main actor. `ingest` runs on the reader
/// thread; the captured fields are read after the run's drain barrier, so a plain lock
/// is sufficient. Mirrors the Claude engine's private accumulator.
private final class CodexResearchStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _threadID: String?
    private var _toolUseCount = 0
    private var _lastResultText: String?
    /// Fired EXACTLY ONCE, the instant the FIRST `thread.started` is ingested — so the
    /// captured thread id can be persisted immediately, before a later timeout/cancel makes
    /// the run throw. Runs on the reader thread; the callback itself is thread-safe.
    private let onThreadIDCaptured: ((String) -> Void)?

    init(onThreadIDCaptured: ((String) -> Void)? = nil) {
        self.onThreadIDCaptured = onThreadIDCaptured
    }

    var threadID: String? { lock.lock(); defer { lock.unlock() }; return _threadID }
    var toolUseCount: Int { lock.lock(); defer { lock.unlock() }; return _toolUseCount }
    var lastResultText: String? { lock.lock(); defer { lock.unlock() }; return _lastResultText }

    func ingest(
        line: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) {
        switch CodexResearchStreamParser.parse(line: line) {
        case .sessionStarted(let threadID):
            // Record the id and detect whether THIS ingestion is the first capture, all
            // under the lock, so the callback fires at most once even if `thread.started`
            // appears more than once (no double-write).
            lock.lock()
            let isFirstCapture = _threadID == nil
            _threadID = threadID
            lock.unlock()
            if isFirstCapture {
                onThreadIDCaptured?(threadID)
            }
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
