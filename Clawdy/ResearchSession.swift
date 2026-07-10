//
//  ResearchSession.swift
//  Clawdy
//
//  Owns ONE autonomous research run end-to-end and keeps it fully isolated from
//  every OTHER research run AND from the warm quick-answer voice session. This is
//  the per-session unit the `ResearchSessionManager` spawns one of per `[RESEARCH]`
//  directive: a NEW directive ALWAYS makes a NEW `ResearchSession`, and stopping or
//  failing one session touches NOTHING else.
//
//  Everything a single run needs lives here and shares nothing with any other run:
//  its own dedicated `claude` process (`ClaudeResearchEngine`), its own run Task,
//  its pre-minted session id + stable per-session directory, its plan/execute
//  phases, its own clarify panel + results window, its manifest writes, and its
//  audio cues. The ONLY UI it does NOT own is the compact indicator "pill" — that
//  is drawn by the manager's shared STACKED overlay, which observes this session's
//  `overlayViewModel`. This session drives the pill purely by mutating its pure
//  `ResearchOverlayState` and pushing it into that view model; the window/stack
//  lifecycle (which pills are visible, which is focused, auto-hide) is the
//  manager's job.
//
//  A quick Ctrl+Option answer cancels `CompanionManager.currentResponseTask` and
//  the warm session; it never touches this session's `currentRunTask` or process.
//  Conversely, this session's Stop cancels only its `currentRunTask` (SIGTERM to
//  its research child) and leaves the warm session — and every sibling research
//  session — untouched.
//
//  Flow (unchanged from the old single-run coordinator): PLAN (plan mode) → either
//  ask clarifying questions (panel) or execute → EXECUTE (resume, narrow tool
//  allowlist) → results window. A single rotating status line drives the pill.
//

import CoreGraphics
import Foundation

/// Stable identifier for one research run — the pre-minted `--session-id` (lowercased
/// UUID) that also names the run's stable directory and keys its manifest entry.
typealias ResearchSessionID = String

@MainActor
final class ResearchSession {
    enum State: Equatable {
        case idle
        case planning
        case awaitingClarification
        case executing
        case completed
        case failed
        case stopped
    }

    /// The pre-minted session id (owned by the manager and passed in) — used as the
    /// `--session-id` on the plan phase, the name of the stable per-session directory
    /// both phases run in, this run's manifest key, and the manager's dictionary key.
    let sessionID: ResearchSessionID

    /// The task this run is researching, shown (truncated) as the pill title and used
    /// as the results-window title.
    let taskDescription: String

    private(set) var state: State = .idle

    /// True while this run is active (planning, awaiting input, or executing). Unlike
    /// the old single-run coordinator, this is NOT used to reject new runs — the
    /// manager always spawns a fresh session — it only reflects THIS run's liveness.
    var isActive: Bool {
        switch state {
        case .planning, .awaitingClarification, .executing:
            return true
        case .idle, .completed, .failed, .stopped:
            return false
        }
    }

    // MARK: - Overlay bridge (drives the manager's stacked pill)

    /// The pure state machine for THIS session's pill + detail view. Mutated only
    /// through its transitions, then pushed into `overlayViewModel`.
    private var overlayState = ResearchOverlayState()

    /// The observable bridge the manager's stacked overlay renders as this session's
    /// pill (and, when focused, its detail panel). Public so the manager can hand it
    /// to its SwiftUI stack.
    let overlayViewModel = ResearchProgressOverlayViewModel()

    /// The coarse overlay phase for THIS session (running / needsInput / done / …),
    /// read by the manager to decide the pill's tap action and terminal auto-hide.
    var overlayPhase: ResearchOverlayPhase { overlayState.phase }

    /// The absolute file URL of the finished deliverable (once completed), so a later
    /// "view results" tap can reopen it.
    private(set) var completedDeliverableURL: URL?

    // MARK: - Per-session UI the run owns directly

    /// This run's OWN clarify panel — a separate instance per session so two runs can
    /// each be awaiting an answer without clobbering each other.
    private let clarificationPanel = ResearchClarificationPanelManager()
    /// This run's OWN results window.
    private let resultsWindow = ResearchResultsWindowController()

    // MARK: - Manager callbacks

    /// Called after every phase-level transition (start / needs-input / resume / done
    /// / error / stopped) so the manager can refresh the stacked overlay and schedule
    /// terminal auto-hide. NOT called on plain progress events (those update the pill
    /// live through `overlayViewModel`).
    var onLifecycleChanged: ((ResearchSession) -> Void)?
    /// The manager's handler for a tap on this session's compact pill (focus / open
    /// clarify / open results, depending on phase).
    var onCompactTapRequested: ((ResearchSession) -> Void)?
    /// The manager's handler for the detail panel's close (X) control — clears focus.
    var onCloseDetailRequested: ((ResearchSession) -> Void)?
    /// The manager's handler for the done pill's "view history" affordance — opens the
    /// History window focused on THIS session's conversation transcript. Distinct from
    /// opening the results output page (`openResults`).
    var onViewHistoryRequested: ((ResearchSession) -> Void)?
    /// The manager's handler for the compact pill's dismiss (×) control. DISMISS hides
    /// this session's pill from the overlay stack; it does NOT stop the run (that is
    /// `onStop` → `stop()`). The run keeps going and stays reachable via History.
    var onDismissRequested: ((ResearchSession) -> Void)?
    /// The concise, read-aloud reply produced by a voice FOLLOW-UP turn (a question's
    /// answer, or a short "updated the page" confirmation for an iterate). The manager
    /// forwards it to `CompanionManager`'s TTS provider selection so it's spoken the
    /// same way a quick answer is. Nil is never sent — only non-empty text.
    var onFollowUpAnswerReady: ((String) -> Void)?

    // MARK: - Injected dependencies (identical to the old coordinator's)

    /// Resolves WHICH research engine + binary this run should use (the user's selected
    /// coach engine, resolved by the manager). Called once in `start()`; a nil result
    /// means no CLI is installed → a soft preflight failure.
    private let resolveEngineSelection: () -> ResearchEngineSelection?
    /// Builds the concrete `ResearchEngine` for a resolved (kind, binaryPath) — a
    /// `ClaudeResearchEngine` for `.claudeCode`, a `CodexResearchEngine` for `.codex`.
    private let makeEngine: (CoachEngineKind, String) -> ResearchEngine
    private let applicationSupportDirectory: URL
    private let homeDirectoryPath: String
    private let manifestStore: ResearchManifestStore
    private let audioCuePlayer: ResearchAudioCuePlayer

    // MARK: - Per-run mutable context

    /// This session's single in-flight Task (plan or execute). Cancelling it SIGTERMs
    /// ONLY this session's process — never a sibling run, never the warm session.
    private var currentRunTask: Task<Void, Never>?

    private var activeEngine: ResearchEngine?
    private var activeOutputDirectory: URL?
    /// The clarifying question text captured when the plan phase paused, so a later
    /// pill tap can open the panel with it.
    private var pendingClarificationQuestions: String?

    /// The absolute path to Claude Code's OWN session transcript for this run
    /// (`~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl`), derived up front in
    /// `start()`. The detail panel reads it (read-only) to show the native session log.
    private var transcriptPath: String?
    /// A repeating, read-only poll that refreshes the detail panel from the transcript
    /// while the run is live. Never blocks or mutates the run (the run's own `claude`
    /// child writes the file; this only reads). Cancelled at every terminal state and
    /// on teardown, and restarted for each follow-up turn.
    private var transcriptPollTask: Task<Void, Never>?
    /// The ONE final read kicked at each terminal transition (`finalizeTranscriptFeed`).
    /// Tracked (not fire-and-forget) so `teardown()` can cancel a final read still in
    /// flight — otherwise a late publish could land on `overlayViewModel` after the
    /// subsystem was torn down. Read-only and off-main, exactly like the poll.
    private var transcriptFinalRefreshTask: Task<Void, Never>?

    // MARK: - Voice follow-up turn queue (per-session FIFO)

    /// Spoken follow-up prompts that arrived while THIS session was busy (planning,
    /// awaiting clarification, executing, or running an earlier follow-up). Drained
    /// one at a time so we NEVER run two concurrent `--resume` turns on the one
    /// `<sessionId>.jsonl` transcript. FIFO: `append` to the end, take from the front.
    private var queuedFollowUpPrompts: [String] = []
    /// True while a voice follow-up turn's own `--resume` process is in flight. Kept
    /// distinct from `currentRunTask` because the awaiting-clarification pause nils the
    /// task while the session is still logically busy.
    private var isFollowUpTurnRunning = false
    /// Count of follow-up turns this session has actually started — a test hook to
    /// prove a focused utterance routed here (and not into a brand-new session).
    private var followUpTurnsStartedCount = 0
    /// Count of times a completed follow-up turn asked the results window to reload
    /// (because it rewrote report.html) — a test hook for the view-refresh path.
    private var followUpViewRefreshCount = 0

    init(
        sessionID: ResearchSessionID,
        taskDescription: String,
        resolveEngineSelection: @escaping () -> ResearchEngineSelection?,
        makeEngine: @escaping (CoachEngineKind, String) -> ResearchEngine = { _, binaryPath in
            ClaudeResearchEngine(binaryPath: binaryPath)
        },
        applicationSupportDirectory: URL = ClaudeResearchEngine.defaultApplicationSupportDirectory(),
        homeDirectoryPath: String = NSHomeDirectory(),
        manifestStore: ResearchManifestStore = .shared,
        audioCuePlayer: ResearchAudioCuePlayer = SystemSoundResearchAudioCuePlayer(),
        testAnchorOriginOffset: CGVector = .zero
    ) {
        self.sessionID = sessionID
        self.taskDescription = taskDescription
        self.resolveEngineSelection = resolveEngineSelection
        self.makeEngine = makeEngine
        self.applicationSupportDirectory = applicationSupportDirectory
        self.homeDirectoryPath = homeDirectoryPath
        self.manifestStore = manifestStore
        self.audioCuePlayer = audioCuePlayer
        // Forward the test-only positioning offset (production default `.zero`, an identity)
        // to this session's private results window so a manager/session real-path test can
        // anchor its real window off-screen instead of flashing it at the screen center.
        resultsWindow.testAnchorOriginOffset = testAnchorOriginOffset
    }

    // MARK: - Public entry points

    /// Begins this research run. Unlike the old coordinator there is NO "already
    /// running" guard — the manager owns concurrency and only ever calls `start()`
    /// once per freshly-created session. Fails softly (a dismissible failed pill) if
    /// Claude Code isn't installed or the output directory can't be created.
    func start() {
        // Resolve which research engine (Claude / Codex) + binary this run uses from the
        // user's selected coach engine. A nil selection means no CLI is installed.
        guard let engineSelection = resolveEngineSelection() else {
            presentPreflightFailure()
            print("🔬 Research: no research CLI installed — research requires claude or codex.")
            return
        }

        // Build the concrete engine FIRST, then ask it (through the `ResearchEngine`
        // protocol) for the per-session output directory + transcript path — each engine
        // owns its own directory/transcript strategy (Claude keys by the pre-minted
        // session id; Codex keys the dir by the client run id and has no transcript path
        // until its thread id is known).
        let engine = makeEngine(engineSelection.kind, engineSelection.binaryPath)

        let outputDirectory: URL
        do {
            outputDirectory = try engine.makeSessionOutputDirectory(
                sessionID: sessionID,
                applicationSupportDirectory: applicationSupportDirectory
            )
        } catch {
            presentPreflightFailure()
            print("🔬 Research: failed to create output dir: \(error)")
            return
        }

        activeEngine = engine
        activeOutputDirectory = outputDirectory
        completedDeliverableURL = nil

        // Index the run in the manifest the moment it starts (status .running). The
        // manifest is keyed by session id, so N sessions index independently without
        // clobbering each other. The transcript path may be nil for engines that only
        // learn it post-hoc (Codex) — the manifest records an empty string until then.
        let resolvedTranscriptPath = engine.transcriptPath(
            sessionID: sessionID,
            outputDirectory: outputDirectory
        )
        // Remember the transcript path so the detail panel can surface the CLI's OWN
        // session log for this run, and begin the read-only poll that feeds it (a nil
        // path skips the poll — nothing to read yet).
        self.transcriptPath = resolvedTranscriptPath
        startTranscriptPolling()
        manifestStore.recordResearchSessionStarted(
            sessionId: sessionID,
            title: Self.deriveTitle(fromTaskDescription: taskDescription),
            task: taskDescription,
            workingDir: outputDirectory.path,
            transcriptPath: resolvedTranscriptPath ?? "",
            engineKind: engineSelection.kind
        )

        // The directive was accepted and a run is committed — play the acknowledge
        // cue. Each session plays its OWN cues, so N concurrent runs each beep on
        // their own start/finish/fail without a shared gate swallowing them.
        audioCuePlayer.play(.acknowledge)

        state = .planning
        overlayState.startRun(taskDescription: taskDescription)
        pushOverlayStateToViewModel()
        notifyLifecycleChanged()

        currentRunTask = Task { [weak self] in
            await self?.runPlanPhase(
                engine: engine,
                sessionID: sessionID,
                outputDirectory: outputDirectory
            )
        }
    }

    /// A short, single-line title for the History index, derived from the task text.
    static func deriveTitle(fromTaskDescription taskDescription: String) -> String {
        let collapsed = taskDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumTitleLength = 80
        if collapsed.count <= maximumTitleLength {
            return collapsed
        }
        let truncated = collapsed.prefix(maximumTitleLength).trimmingCharacters(in: .whitespaces)
        return truncated + "…"
    }

    /// Cancels THIS research run via SIGTERM to its process. Never touches the warm
    /// voice session or any sibling research session.
    func stop() {
        currentRunTask?.cancel()
        currentRunTask = nil
        isFollowUpTurnRunning = false
        queuedFollowUpPrompts.removeAll()
        clarificationPanel.hide()
        state = .stopped
        // Record the stop in the manifest (only if the run had actually started).
        if activeOutputDirectory != nil {
            manifestStore.recordResearchSessionOutcome(
                sessionId: sessionID,
                status: .stopped,
                deliverablePath: nil
            )
        }
        overlayState.markStopped()
        pushOverlayStateToViewModel()
        finalizeTranscriptFeed()
        notifyLifecycleChanged()
    }

    /// FULLY disposes this session for a subsystem teardown (app quit / engine switch),
    /// as opposed to `stop()` which is a user Stop that records a `.stopped` outcome and
    /// drives the pill. Cancels the in-flight run's Task (SIGTERM to its process) and
    /// closes this session's OWN windows — the clarify panel AND the results window,
    /// which persists after completion and would otherwise leak. Deliberately does NOT
    /// write the manifest or notify the manager: the manager is discarding everything.
    func teardown() {
        currentRunTask?.cancel()
        currentRunTask = nil
        transcriptPollTask?.cancel()
        transcriptPollTask = nil
        // Also cancel a final transcript read still in flight, so no publish can land
        // on the view model after teardown.
        transcriptFinalRefreshTask?.cancel()
        transcriptFinalRefreshTask = nil
        isFollowUpTurnRunning = false
        queuedFollowUpPrompts.removeAll()
        clarificationPanel.hide()
        resultsWindow.hide()
    }

    /// Opens THIS session's clarify panel (invoked by the manager when the pill is
    /// tapped while awaiting input). Submitting resumes into the execute phase; cancel
    /// stops the run.
    func openClarify() {
        guard state == .awaitingClarification,
              let questions = pendingClarificationQuestions,
              let engine = activeEngine,
              let outputDirectory = activeOutputDirectory else { return }

        clarificationPanel.show(
            questions: questions,
            onSubmit: { [weak self] answer in
                self?.resumeWithClarification(
                    engine: engine,
                    outputDirectory: outputDirectory,
                    answer: answer
                )
            },
            onCancel: { [weak self] in
                self?.stop()
            }
        )
    }

    /// Reopens THIS session's finished deliverable (invoked by the manager when the
    /// pill is tapped while done).
    func openResults() {
        guard let deliverableURL = completedDeliverableURL else { return }
        // Test-only observability: count each actual open so a test can prove the
        // done-click path opens the results window EXACTLY once (the registry binding
        // alone can't — `show()` is idempotent per session window). Inert in production.
        openResultsCallCountForTesting += 1
        resultsWindow.show(htmlFileURL: deliverableURL, title: taskDescription, sessionID: sessionID)
    }

    /// Adopts an already-FINISHED research run — one loaded from the manifest, e.g. a
    /// page the user opened from the History window whose session is no longer live —
    /// into a resumable session WITHOUT re-running the plan/execute phases. Wires the
    /// engine, the stable per-session working directory, the finished deliverable, and
    /// the transcript path so a voice follow-up can `--resume <sessionID>` the existing
    /// claude thread (subscription billing, same stable CWD — the shared-CWD resume
    /// requirement). Sets the state to `.completed` and shows a done pill so the pill /
    /// results / follow-up all behave exactly as they do for a natively-live session.
    ///
    /// Deliberately does NOT write the manifest: this run is already indexed there (it
    /// came FROM the manifest), and a follow-up turn itself writes nothing new — so no
    /// duplicate or clobbered entry. Only ever called by the manager after confirming
    /// the session isn't already live, so it can't overwrite a running session.
    func adoptFinishedRunForFollowUp(
        engine: ResearchEngine,
        outputDirectory: URL,
        deliverableURL: URL,
        transcriptPath: String
    ) {
        activeEngine = engine
        activeOutputDirectory = outputDirectory
        completedDeliverableURL = deliverableURL
        self.transcriptPath = transcriptPath
        state = .completed
        // Seed the pill straight to a completed/done state (startRun establishes the
        // task + log baseline; markCompleted moves it to `.done`).
        overlayState.startRun(taskDescription: taskDescription)
        overlayState.markCompleted()
        pushOverlayStateToViewModel()
        notifyLifecycleChanged()
    }

    // MARK: - Voice-native follow-up (continue THIS session's own claude thread)

    /// Continues THIS session's own `claude` thread by voice: the spoken `prompt`
    /// resumes `--resume <sessionId>` from the session's stable dir with the
    /// execute-phase arg set, so the model answers a question (the finished page is
    /// already in transcript context — no file tools needed) or iterates on the page.
    ///
    /// PER-SESSION FIFO SERIALIZATION: if a turn is already in flight (the initial
    /// plan/execute, or an earlier follow-up), the prompt is ENQUEUED and drained one
    /// at a time — never a concurrent `--resume` on the single `<id>.jsonl`. A no-op
    /// if this session never actually started a run (no engine/output dir), so a
    /// preflight-failed pill can't be "followed up".
    ///
    /// SAFETY (BLOCKING #2): a follow-up is refused unless the session is in a clean,
    /// resumable state. A STOPPED or FAILED session is NOT resumable — its `claude`
    /// child was cancelled (SIGTERM) and may still be draining, so starting a fresh
    /// `--resume` on the same id could race the single `<id>.jsonl`. We deliberately
    /// block follow-up on such sessions outright and require a fresh run. An `.idle`
    /// session hasn't produced anything to resume. Only a busy session (enqueue) or a
    /// `.completed` one (run now) accepts a follow-up.
    /// Returns whether the follow-up was actually ACCEPTED — `true` only when it begins a
    /// follow-up turn now or is queued behind an in-flight one, `false` on every refusal (no
    /// engine/output dir yet, or a non-resumable `.idle`/`.failed`/`.stopped` state). Callers
    /// that show a composer rely on this to know whether the turn routed (so a refused submit
    /// never silently clears the user's draft); voice callers may ignore the result.
    @discardableResult
    func followUp(prompt: String) -> Bool {
        guard activeEngine != nil, activeOutputDirectory != nil else { return false }
        guard canAcceptFollowUp else {
            print("🔬 Research: ignoring follow-up on a non-resumable session (state: \(state)).")
            return false
        }

        // The directive/utterance was accepted for THIS session — acknowledge it the
        // same way an initial run does, whether it starts now or is queued.
        audioCuePlayer.play(.acknowledge)

        if isSessionBusy {
            queuedFollowUpPrompts.append(prompt)
            return true
        }
        startFollowUpTurn(prompt: prompt)
        return true
    }

    /// Whether this session may accept a voice follow-up right now. Busy states
    /// enqueue behind the in-flight turn; `.completed` runs one immediately. Terminal
    /// `.stopped`/`.failed` (a cancelled/errored child that must not be resumed) and
    /// `.idle` (nothing produced yet) refuse it — the safe choice that makes a second
    /// concurrent `--resume` on the same session id impossible.
    private var canAcceptFollowUp: Bool {
        switch state {
        case .planning, .awaitingClarification, .executing:
            // Busy → enqueue behind the in-flight turn; the engine may still capture its
            // resume handle before the queued turn drains.
            return true
        case .completed:
            // A completed run is followable only if its engine can actually RESUME it —
            // Claude always can (`canResumeForFollowUp` defaults true), Codex only if its
            // execute turn captured a thread_id. A no-thread_id Codex run is non-followable
            // (the deliverable/results still work); we refuse rather than start a resume
            // that would fail with `noThreadIDForFollowUp`.
            return activeEngine?.canResumeForFollowUp ?? false
        case .idle, .failed, .stopped:
            return false
        }
    }

    /// Whether a follow-up composer's Send should be offered for THIS session right now —
    /// the same gate `canAcceptFollowUp` applies. Exposed so the manager's `liveOverlayPhase`
    /// can hide a Send that the session would only refuse (a non-followable Codex run that
    /// captured no thread_id), while keeping the results page reachable.
    var isResumableForFollowUp: Bool { canAcceptFollowUp }

    /// True while THIS session has work in flight that a follow-up must NOT run
    /// concurrently with: the initial plan/execute (including the awaiting-input
    /// pause) or an in-flight follow-up turn.
    private var isSessionBusy: Bool {
        if isFollowUpTurnRunning { return true }
        switch state {
        case .planning, .awaitingClarification, .executing:
            return true
        case .idle, .completed, .failed, .stopped:
            return false
        }
    }

    /// Starts one follow-up `--resume` turn immediately (the caller has already
    /// ensured the session isn't busy). Flips the pill back to running for the turn.
    private func startFollowUpTurn(prompt: String) {
        guard let engine = activeEngine, let outputDirectory = activeOutputDirectory else { return }
        isFollowUpTurnRunning = true
        followUpTurnsStartedCount += 1
        state = .executing
        overlayState.beginFollowUp()
        pushOverlayStateToViewModel()
        // A follow-up appends to the same transcript — resume the read-only poll so the
        // detail panel reflects the new activity.
        startTranscriptPolling()
        notifyLifecycleChanged()

        currentRunTask = Task { [weak self] in
            guard let self else { return }
            await self.runFollowUpTurn(
                engine: engine,
                outputDirectory: outputDirectory,
                prompt: prompt
            )
        }
    }

    private func runFollowUpTurn(
        engine: ResearchEngine,
        outputDirectory: URL,
        prompt: String
    ) async {
        do {
            let followUpResult = try await engine.runFollowUpPhase(
                sessionID: sessionID,
                outputDirectory: outputDirectory,
                followUpPrompt: prompt,
                onProgress: { [weak self] progressEvent in
                    self?.applyProgress(progressEvent)
                }
            )
            guard !Task.isCancelled else {
                isFollowUpTurnRunning = false
                return
            }
            currentRunTask = nil
            isFollowUpTurnRunning = false

            // An ITERATE turn replaced report.html — adopt the (same-path) deliverable
            // and reload the open results window. A pure QUESTION wrote nothing.
            if followUpResult.deliverableWasRewritten, let deliverableURL = followUpResult.deliverableURL {
                completedDeliverableURL = deliverableURL
            }

            // Back to the done pill; the session stays around for further follow-ups.
            // Deliberately NO manifest write here: an in-place iterate keeps the same
            // title/task/deliverablePath a parallel slice already indexed, and a
            // question changes nothing — so we don't touch the manifest write lines.
            state = .completed
            audioCuePlayer.play(.done)
            overlayState.markCompleted()
            pushOverlayStateToViewModel()
            finalizeTranscriptFeed()
            notifyLifecycleChanged()

            // Speak a concise reply through CompanionManager's TTS: the model's answer
            // for a question, a short confirmation for an iterate (never long logs).
            let spokenReply = Self.followUpSpokenReply(
                modelAnswer: followUpResult.spokenAnswer,
                deliverableWasRewritten: followUpResult.deliverableWasRewritten
            )
            if !spokenReply.isEmpty {
                onFollowUpAnswerReady?(spokenReply)
            }

            // Reload the WKWebView off THIS turn's completion (not a file-watcher —
            // iteration replaces the inode), and only when the window is open. Gated
            // through the pure `shouldAnimateRefresh` decision so ONLY a rewrite refreshes
            // (and hot-reloads with the "Updated" affordance) — a pure question never does.
            let followUpKind: ResearchResultsFollowUpKind =
                followUpResult.deliverableWasRewritten ? .rewrite : .question
            if ResearchResultsRefreshAnimation.shouldAnimateRefresh(followUpKind: followUpKind) {
                refreshResultsWindowIfOpen()
            }

            drainNextFollowUpIfAny()
        } catch is CancellationError {
            isFollowUpTurnRunning = false
        } catch {
            isFollowUpTurnRunning = false
            // A FOLLOW-UP-turn failure must NOT be routed through the shared
            // `handleRunFailure` — that records `.failed` and would downgrade an
            // already-completed run (clobbering its good deliverable + refusing all
            // future follow-ups). Use the follow-up-specific handler that protects a
            // completed session's durable state.
            handleFollowUpTurnFailure(error)
        }
    }

    /// Chooses the concise line to read aloud after a follow-up turn: a short fixed
    /// confirmation when the page was rewritten (don't read the edit narration), or
    /// the model's own answer for a pure question.
    nonisolated static func followUpSpokenReply(modelAnswer: String?, deliverableWasRewritten: Bool) -> String {
        if deliverableWasRewritten {
            return "Updated the page."
        }
        return (modelAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reloads the results window's WKWebView if it's currently open, so an iterate's
    /// new report.html replaces the stale one the user is viewing — hot-reloading with a
    /// subtle "Updated" affordance (Reduce-Motion-aware, decided inside the controller)
    /// so the change is visible instead of a silent swap.
    private func refreshResultsWindowIfOpen() {
        followUpViewRefreshCount += 1
        guard resultsWindow.isVisible, let deliverableURL = completedDeliverableURL else { return }
        resultsWindow.refreshWithUpdate(htmlFileURL: deliverableURL, title: taskDescription, sessionID: sessionID)
    }

    /// Starts the next queued follow-up (if any), preserving FIFO order. Called after a
    /// successful turn so the queue drains one at a time with no concurrent `--resume`.
    private func drainNextFollowUpIfAny() {
        guard !queuedFollowUpPrompts.isEmpty else { return }

        // A queued follow-up was ACCEPTED (`followUp` returned true, the cue played)
        // while the session was still busy — but the session may have SETTLED into a
        // non-followable state since then. The concrete edge: a Codex run that accepts a
        // follow-up while executing, then completes WITHOUT capturing a thread_id — a
        // `.completed` run whose engine `canResumeForFollowUp` is now false. Starting the
        // drained turn anyway would just fail with `noThreadIDForFollowUp`. Re-check the
        // SAME gate `followUp` applied on accept and, if the session can no longer accept
        // it, discard the doomed queue cleanly instead of starting a resume that must fail.
        guard canAcceptFollowUp else {
            queuedFollowUpPrompts.removeAll()
            print("🔬 Research: discarding queued follow-up(s) — session is no longer resumable (state: \(state)).")
            return
        }

        let nextPrompt = queuedFollowUpPrompts.removeFirst()
        startFollowUpTurn(prompt: nextPrompt)
    }

    // MARK: - Phase 1: plan / clarify

    private func runPlanPhase(
        engine: ResearchEngine,
        sessionID: String,
        outputDirectory: URL
    ) async {
        do {
            let planResult = try await engine.runPlanPhase(
                task: taskDescription,
                sessionID: sessionID,
                outputDirectory: outputDirectory,
                onProgress: { [weak self] progressEvent in
                    self?.applyProgress(progressEvent)
                }
            )
            guard !Task.isCancelled else { return }

            switch planResult.outcome {
            case .needsClarification(let questions):
                state = .awaitingClarification
                currentRunTask = nil
                pendingClarificationQuestions = questions
                overlayState.markNeedsInput()
                pushOverlayStateToViewModel()
                notifyLifecycleChanged()
            case .readyToExecute:
                // Resume the SAME pre-minted id (claude echoed it back verbatim) from
                // the SAME stable directory.
                await runExecutePhase(
                    engine: engine,
                    sessionID: sessionID,
                    outputDirectory: outputDirectory,
                    clarificationAnswers: nil
                )
            }
        } catch is CancellationError {
            // Stopped by the user — stop() already updated the overlay.
        } catch {
            handleRunFailure(error)
        }
    }

    private func resumeWithClarification(
        engine: ResearchEngine,
        outputDirectory: URL,
        answer: String
    ) {
        state = .executing
        overlayState.resumeExecuting()
        pushOverlayStateToViewModel()
        notifyLifecycleChanged()
        currentRunTask = Task { [weak self] in
            guard let self else { return }
            await self.runExecutePhase(
                engine: engine,
                sessionID: self.sessionID,
                outputDirectory: outputDirectory,
                clarificationAnswers: answer
            )
        }
    }

    // MARK: - Phase 2: execute

    private func runExecutePhase(
        engine: ResearchEngine,
        sessionID: String,
        outputDirectory: URL,
        clarificationAnswers: String?
    ) async {
        state = .executing
        do {
            let deliverableURL = try await engine.runExecutePhase(
                sessionID: sessionID,
                outputDirectory: outputDirectory,
                clarificationAnswers: clarificationAnswers,
                onProgress: { [weak self] progressEvent in
                    self?.applyProgress(progressEvent)
                }
            )
            guard !Task.isCancelled else { return }
            completedDeliverableURL = deliverableURL
            state = .completed
            currentRunTask = nil
            manifestStore.recordResearchSessionOutcome(
                sessionId: sessionID,
                status: .completed,
                deliverablePath: deliverableURL.path
            )
            // For an engine that learns its transcript path only POST-HOC (Codex, once its
            // execute turn captured a thread id), fill it into the manifest now so History
            // can surface the transcript. A no-op for Claude (already resolved at start).
            resolveLateTranscriptPathIfNeeded(engine: engine, outputDirectory: outputDirectory)
            audioCuePlayer.play(.done)
            overlayState.markCompleted()
            pushOverlayStateToViewModel()
            finalizeTranscriptFeed()
            notifyLifecycleChanged()
            // Any voice follow-up spoken while this run was still working now drains
            // (serialized, one at a time — never a concurrent resume).
            drainNextFollowUpIfAny()
        } catch is CancellationError {
            // Stopped by the user.
        } catch {
            handleRunFailure(error)
        }
    }

    // MARK: - Helpers

    private func applyProgress(_ progressEvent: ResearchProgressEvent) {
        // Only the running phases own the live status line; ignore late events that
        // land after a stop/completion. `recordProgress` itself also guards on the
        // overlay's `.running` phase.
        guard state == .planning || state == .executing else { return }
        overlayState.recordProgress(progressEvent)
        // A plain progress tick updates the pill live via the view model but is NOT a
        // lifecycle transition, so the manager isn't asked to re-plan the stack.
        pushOverlayStateToViewModel()
    }

    private func handleRunFailure(_ error: Error) {
        currentRunTask = nil
        state = .failed
        if activeOutputDirectory != nil {
            manifestStore.recordResearchSessionOutcome(
                sessionId: sessionID,
                status: .failed,
                deliverablePath: nil
            )
        }
        audioCuePlayer.play(.error)
        print("🔬 Research run failed: \(error)")
        overlayState.markFailed()
        pushOverlayStateToViewModel()
        finalizeTranscriptFeed()
        notifyLifecycleChanged()
    }

    /// The short line spoken when a FOLLOW-UP turn fails transiently on an
    /// already-completed session, so the user knows the follow-up didn't go through —
    /// WITHOUT downgrading the good deliverable. Surfaced via the same TTS channel a
    /// follow-up answer uses (`onFollowUpAnswerReady`).
    nonisolated static let followUpTransientFailureSpokenMessage =
        "Sorry, that follow-up didn't go through. Please try again."

    /// Handles a FOLLOW-UP-turn failure. This is DELIBERATELY separate from the initial
    /// run's `handleRunFailure`: an initial execute/plan failure produced NO deliverable
    /// and is genuinely `.failed` (unchanged). But a transient failure of a follow-up
    /// turn on an ALREADY-COMPLETED session (a network blip, a budget/timeout, a CLI
    /// non-zero exit) must NOT downgrade the durable `.completed` run — a good
    /// report.html is on disk and must stay openable AND followable. So for a completed
    /// session we RESTORE the done state, write NO manifest downgrade (the existing
    /// `.completed` + `deliverablePath` stay intact), keep the run followable, and
    /// surface the transient failure to the user via speech. Only the edge case of a
    /// follow-up on a session that was never completed falls back to today's behavior.
    private func handleFollowUpTurnFailure(_ error: Error) {
        currentRunTask = nil
        isFollowUpTurnRunning = false

        // A session with a real completed deliverable is protected. Anything else
        // (an edge-case follow-up on a never-completed session) keeps today's genuine
        // `.failed` behavior.
        guard completedDeliverableURL != nil else {
            handleRunFailure(error)
            return
        }

        print("🔬 Research follow-up turn failed — keeping the completed deliverable: \(error)")
        // Restore the terminal done state in memory; leave the manifest's `.completed`
        // status + `deliverablePath` untouched (no `recordResearchSessionOutcome` call).
        state = .completed
        audioCuePlayer.play(.error)
        overlayState.markCompleted()
        pushOverlayStateToViewModel()
        finalizeTranscriptFeed()
        notifyLifecycleChanged()

        // Surface the transient failure so the user knows the follow-up didn't go
        // through, without corrupting durable state (do not silently swallow it).
        onFollowUpAnswerReady?(Self.followUpTransientFailureSpokenMessage)

        // The session is `.completed` and resumable again — drain any queued follow-up
        // so a transient failure doesn't strand later prompts.
        drainNextFollowUpIfAny()
    }

    /// Shows a dismissible failed pill for a run that never got off the ground (no
    /// claude, or the output dir couldn't be created), so the user still sees an error
    /// instead of a silent no-op. No cue and no manifest write (the run never
    /// committed — mirrors the old coordinator's pre-start failure path).
    private func presentPreflightFailure() {
        state = .failed
        overlayState.startRun(taskDescription: taskDescription)
        overlayState.markFailed()
        pushOverlayStateToViewModel()
        notifyLifecycleChanged()
    }

    /// Pushes the pure overlay state into the observable view model and re-wires the
    /// pill's callbacks to this session. Idempotent; called after every state change.
    private func pushOverlayStateToViewModel() {
        overlayViewModel.phase = overlayState.phase
        overlayViewModel.taskDescription = overlayState.taskDescription
        overlayViewModel.statusLine = overlayState.statusLine
        overlayViewModel.stepLog = overlayState.stepLog
        overlayViewModel.isCancellable = overlayState.isCancellable

        overlayViewModel.onStop = { [weak self] in self?.stop() }
        overlayViewModel.onDismiss = { [weak self] in
            guard let self else { return }
            // DISMISS is hide-chrome only — forward to the manager to remove this pill
            // from the overlay stack. It must NOT call `stop()`: the run keeps going.
            self.onDismissRequested?(self)
        }
        overlayViewModel.onViewResults = { [weak self] in self?.openResults() }
        overlayViewModel.onViewHistory = { [weak self] in
            guard let self else { return }
            self.onViewHistoryRequested?(self)
        }
        overlayViewModel.onCloseDetail = { [weak self] in
            guard let self else { return }
            self.onCloseDetailRequested?(self)
        }
        overlayViewModel.onCompactTap = { [weak self] in
            guard let self else { return }
            self.onCompactTapRequested?(self)
        }
        overlayViewModel.onSubmitFollowUp = { [weak self] typedPrompt in
            guard let self else { return }
            // A TYPED follow-up takes the SAME per-session FIFO path as a spoken one — it
            // enqueues behind any in-flight turn and never runs a concurrent `--resume`.
            let trimmedPrompt = typedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPrompt.isEmpty else { return }
            self.followUp(prompt: trimmedPrompt)
        }
    }

    private func notifyLifecycleChanged() {
        onLifecycleChanged?(self)
    }

    // MARK: - Detail-panel transcript feed (read-only, thin-wrapper over claude's log)

    /// Starts (or restarts) the read-only poll that refreshes the detail panel from
    /// Claude Code's OWN session transcript while the run is live. Idempotent — cancels
    /// any prior poll first. It reads the `.jsonl` on a detached task (never on the run's
    /// path) and pushes the parsed turns into the observable view model. Stops itself
    /// once the run is no longer active; `finalizeTranscriptFeed` guarantees one last
    /// read at each terminal transition so the finished log is fully shown.
    private func startTranscriptPolling() {
        transcriptPollTask?.cancel()
        guard transcriptPath != nil else { return }
        transcriptPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshTranscriptFeed()
                guard self.isActive else { break }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    /// Reads the transcript off the main actor and publishes the parsed turns to the
    /// detail view model. Read-only; a missing/unwritten/out-of-fence file yields [] so
    /// the detail view falls back to the synthetic status steps.
    private func refreshTranscriptFeed() async {
        guard let transcriptPath else { return }
        let turns = await Task.detached(priority: .utility) {
            ResearchTranscriptFeed.loadTurns(transcriptPath: transcriptPath)
        }.value
        // If this task was cancelled while the read was in flight (e.g. teardown), do
        // NOT publish — no transcript update may land after the subsystem is torn down.
        guard !Task.isCancelled else { return }
        overlayViewModel.transcriptTurns = turns
    }

    /// For an engine whose transcript path is only resolvable POST-HOC (Codex — it needs
    /// the `thread_id` its execute turn captures), resolve it now and fill it into the
    /// manifest so the History transcript works. A no-op when the transcript path was
    /// already resolved up front (Claude: `transcriptPath` is non-empty from `start()`),
    /// so the Claude manifest/transcript path stays byte-for-byte unchanged. The next
    /// `finalizeTranscriptFeed()` reads the now-known path.
    private func resolveLateTranscriptPathIfNeeded(engine: ResearchEngine, outputDirectory: URL) {
        // Already have a transcript path (Claude) → nothing to backfill.
        guard transcriptPath?.isEmpty ?? true else { return }
        guard let resolvedTranscriptPath = engine.transcriptPath(sessionID: sessionID, outputDirectory: outputDirectory),
              !resolvedTranscriptPath.isEmpty else { return }
        transcriptPath = resolvedTranscriptPath
        manifestStore.recordResearchSessionTranscriptPath(
            sessionId: sessionID,
            transcriptPath: resolvedTranscriptPath
        )
    }

    /// Ends the poll at a terminal transition (completed / failed / stopped) and kicks
    /// ONE final read so the finished transcript is fully reflected without waiting for
    /// the next poll tick.
    private func finalizeTranscriptFeed() {
        transcriptPollTask?.cancel()
        transcriptPollTask = nil
        // Track the final read so teardown can cancel it if it's still in flight —
        // cancel any prior final read first so we never leak/overlap two.
        transcriptFinalRefreshTask?.cancel()
        transcriptFinalRefreshTask = Task { [weak self] in await self?.refreshTranscriptFeed() }
    }

    // MARK: - Test hooks

    var overlayStateForTesting: ResearchOverlayState { overlayState }
    /// Number of times `openResults()` actually opened the results window (past the
    /// completed-deliverable guard), so a test can assert the done-click path opens it
    /// EXACTLY once — count 0 if the open is dropped, 2 on a double-call.
    private(set) var openResultsCallCountForTesting = 0
    /// Number of follow-up turns this session has started (initial run excluded), so a
    /// test can prove a focused utterance routed into THIS session's own thread.
    var followUpTurnsStartedCountForTesting: Int { followUpTurnsStartedCount }
    /// Number of spoken follow-up prompts currently queued behind an in-flight turn.
    var queuedFollowUpCountForTesting: Int { queuedFollowUpPrompts.count }
    /// Whether a follow-up `--resume` turn is in flight right now.
    var isFollowUpTurnRunningForTesting: Bool { isFollowUpTurnRunning }
    /// Number of times a completed follow-up asked the results window to reload.
    var followUpViewRefreshCountForTesting: Int { followUpViewRefreshCount }

    /// Sets the transcript path and kicks the ONE final read WITHOUT running a full
    /// plan/execute, so the "teardown cancels a pending final refresh" path is testable
    /// headlessly (no live `claude` process).
    func primeAndFinalizeTranscriptFeedForTesting(transcriptPath: String) {
        self.transcriptPath = transcriptPath
        finalizeTranscriptFeed()
    }
    /// The in-flight final transcript read, so a test can await its completion and
    /// confirm it did not publish after teardown cancelled it.
    var transcriptFinalRefreshTaskForTesting: Task<Void, Never>? { transcriptFinalRefreshTask }
}
