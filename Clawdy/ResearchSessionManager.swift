//
//  ResearchSessionManager.swift
//  Clawdy
//
//  The architectural spine of research mode: turns the old single-run subsystem into
//  a MANAGER of N concurrent, fully-isolated `ResearchSession`s. `CompanionManager`
//  routes a `[RESEARCH]` directive to `startSession(task:)`, which ALWAYS spawns a
//  NEW session — there is no "one at a time" guard anymore. Multiple runs proceed
//  simultaneously; each owns its own process / Task / directory / manifest entry /
//  clarify panel / results window / audio cues, so stopping or failing one NEVER
//  affects another, and none of them can touch the warm quick-answer session.
//
//  The manager owns the SHARED presentation surface the sessions do not: the STACKED
//  overlay (one pill per session, collapsing beyond 3) and the FOCUS concept — an
//  observable `focusedSessionID` a later slice will consume to route a spoken
//  follow-up to the focused run. Clicking a pill focuses that session and opens its
//  read-only detail panel; the detail's close control (or re-tapping) clears focus.
//
//  All state here is `@MainActor`; `focusedSessionID` is `@Published` so SwiftUI /
//  the next slice can observe it.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class ResearchSessionManager: ObservableObject {

    /// The live sessions, keyed by session id. A0's manifest store already indexes N
    /// sessions independently (keyed by the same id), so the manager just has to avoid
    /// clobbering — which the per-id dictionary guarantees.
    private var sessionsByID: [ResearchSessionID: ResearchSession] = [:]
    /// Insertion order, so the stacked overlay shows the pills oldest-first (stable)
    /// and the collapse "+N more" always hides the most recent ones consistently.
    private var sessionOrder: [ResearchSessionID] = []

    /// The currently focused session, or nil for no-focus. A later slice routes a
    /// spoken follow-up to this session; in this slice it drives the pill highlight
    /// and which read-only detail panel is shown. Observable on purpose.
    @Published private(set) var focusedSessionID: ResearchSessionID?

    /// Whether the stacked overlay is expanded to show every pill (vs. collapsed to
    /// the first few + a "+N more" row).
    @Published private(set) var isStackExpanded: Bool = false

    /// Fires a session's id every time its lifecycle phase changes (via
    /// `handleSessionLifecycleChanged`). The open History view model subscribes so a composer
    /// keyed to a selected LIVE session stays in sync with its true phase (never a stale
    /// enabled Send after an EXTERNAL transition). Main-actor only, matching this class.
    private let sessionLifecycleChangedSubject = PassthroughSubject<ResearchSessionID, Never>()

    /// A publisher of `sessionLifecycleChangedSubject` for observers (the History view model)
    /// to subscribe to. Exposed via the `ResearchHistoryFollowUpRouting` seam.
    var sessionLifecycleChangedPublisher: AnyPublisher<ResearchSessionID, Never> {
        sessionLifecycleChangedSubject.eraseToAnyPublisher()
    }

    /// Sessions whose pill the user DISMISSED (the × control) — hidden from the overlay
    /// stack while the run itself keeps going. Distinct from stopping: a dismissed
    /// session stays live and reachable via History; only its chrome is hidden.
    private var dismissedSessionIDs: Set<ResearchSessionID> = []

    private let stackedOverlay = ResearchStackedOverlayController()

    /// The ALWAYS-PRESENT minimal recents badge — the idle Clawdy presence shown in the
    /// upper-left whenever NO research toast is active. Exactly one of {recents badge |
    /// active toast stack} occupies the top-left at a time; `refreshOverlay` swaps them.
    private let recentsBadge = ResearchRecentsBadgeController()

    /// The History window opened by a done pill's "view history" affordance, focused on
    /// that session's transcript. Its own controller (the menu-bar panel owns a separate
    /// one) so opening from the toast never depends on the panel being on screen.
    private let historyWindowController = ResearchHistoryWindowController()

    /// A dedicated results-window controller for a recents-list row that opens a
    /// finished page — mirroring the History window's own results controller so opening
    /// a past page from recents never disturbs a live research run's results window.
    private let recentsResultsWindow = ResearchResultsWindowController()

    /// Set by `CompanionManager`: forwards a focused session's voice FOLLOW-UP reply
    /// (a question's answer or a short iterate confirmation) to the app's TTS provider
    /// selection, so it's spoken exactly like a quick answer. One shared closure for
    /// all sessions — the answer is always routed to the same voice output.
    var onFollowUpSpokenAnswer: ((String) -> Void)?

    /// Sessions in a terminal stopped/error state auto-hide after this linger, exactly
    /// as the old single overlay did (`done` persists so results stay reachable).
    private let terminalStateLingerSeconds: TimeInterval = 3
    /// Pending auto-hide removals keyed by session id, so a session isn't scheduled
    /// twice and so we can cancel if needed.
    private var pendingRemovalWorkItems: [ResearchSessionID: DispatchWorkItem] = [:]

    // MARK: - Injected dependencies (forwarded to each spawned session)

    /// Resolves the Claude binary specifically — used for the Claude-only paths (History
    /// "Resume in Terminal" and reconstructing a finished Claude session for follow-up).
    private let resolveClaudeBinaryPath: () -> String?
    /// Resolves the installed binary for a SPECIFIC engine kind — used when reconstructing a
    /// FINISHED session for follow-up, which must resume the engine that PRODUCED the run
    /// (from the manifest's `engineKind`), NOT the engine currently selected for new runs. A
    /// Codex run reconstructs via the codex binary even while Claude is selected, and vice
    /// versa. Defaults to a Claude-only mapping (codex → nil) so existing callers that only
    /// pass `resolveClaudeBinaryPath` keep Claude-only reconstruction; `CompanionManager`
    /// injects a real resolver that resolves either CLI from the startup-built registry.
    private let resolveResearchBinaryPath: (CoachEngineKind) -> String?
    /// Resolves WHICH research engine + binary a NEW run should use, from the user's
    /// selected coach engine (falling back to whichever CLI is installed). This is the
    /// engine-by-kind seam: Claude selected → claude + ClaudeResearchEngine; Codex
    /// selected → codex + CodexResearchEngine.
    private let resolveResearchEngineSelection: () -> ResearchEngineSelection?
    /// Builds the concrete `ResearchEngine` for a resolved (kind, binaryPath).
    private let makeEngine: (CoachEngineKind, String) -> ResearchEngine
    private let generateSessionID: () -> String
    private let applicationSupportDirectory: URL
    private let homeDirectoryPath: String
    private let manifestStore: ResearchManifestStore
    private let audioCuePlayer: ResearchAudioCuePlayer

    /// Test-only positioning offset (production default `.zero`, an identity) forwarded to
    /// EVERY overlay controller this manager owns — the stacked overlay, the recents badge,
    /// and the recents results window — plus each `ResearchSession` it spawns (which forwards
    /// it to its own private results window). Lets a manager/session real-path test anchor all
    /// the real panels/windows off-screen instead of flashing them at the top-left/center.
    private let testAnchorOriginOffset: CGVector

    /// Where persisted UI state (currently just the overlay drag offset) is read/written.
    /// Injectable so tests don't touch the real `.standard` defaults.
    private let userDefaults: UserDefaults

    /// The CANONICAL shared drag offset for the upper-left research overlay cluster — the
    /// toast stack AND the idle recents badge both honor it, so dragging either moves both.
    /// Owned here (the single source of truth), pushed into both controllers, and PERSISTED
    /// to UserDefaults on every change so a moved position survives relaunch.
    private var overlayColumnDragOffset: CGVector {
        didSet { userDefaults.set(overlayColumnDragOffset, forKey: .researchOverlayDragOffset) }
    }

    init(
        resolveClaudeBinaryPath: @escaping () -> String?,
        resolveResearchBinaryPath: ((CoachEngineKind) -> String?)? = nil,
        resolveResearchEngineSelection: (() -> ResearchEngineSelection?)? = nil,
        resolveUseClaudeCustomizations: @escaping () -> Bool = { true },
        makeEngine: ((CoachEngineKind, String) -> ResearchEngine)? = nil,
        generateSessionID: @escaping () -> String = { UUID().uuidString.lowercased() },
        applicationSupportDirectory: URL = ClaudeResearchEngine.defaultApplicationSupportDirectory(),
        homeDirectoryPath: String = NSHomeDirectory(),
        manifestStore: ResearchManifestStore = .shared,
        audioCuePlayer: ResearchAudioCuePlayer = SystemSoundResearchAudioCuePlayer(),
        testAnchorOriginOffset: CGVector = .zero,
        userDefaults: UserDefaults = .standard
    ) {
        self.testAnchorOriginOffset = testAnchorOriginOffset
        self.userDefaults = userDefaults
        // Restore the user's saved cluster drag offset (or `.zero` on first run). The initial
        // assignment does not fire `didSet`, so restoring never re-persists.
        self.overlayColumnDragOffset = userDefaults.vector(forKey: .researchOverlayDragOffset) ?? .zero
        self.resolveClaudeBinaryPath = resolveClaudeBinaryPath
        // Default the per-kind reconstruction binary resolver to Claude-only (codex → nil),
        // so a manager built with just `resolveClaudeBinaryPath` reconstructs Claude runs
        // exactly as before and treats Codex runs as non-reconstructable (no codex binary to
        // resume with). CompanionManager injects a resolver that resolves either CLI.
        self.resolveResearchBinaryPath = resolveResearchBinaryPath ?? { kind in
            switch kind {
            case .claudeCode: return resolveClaudeBinaryPath()
            case .codex: return nil
            }
        }
        // Default the engine-selection seam to the Claude binary (backward-compatible:
        // existing callers that only pass `resolveClaudeBinaryPath` keep getting a
        // Claude research engine). CompanionManager injects a real selection that follows
        // the user's chosen coach engine (Claude or Codex).
        self.resolveResearchEngineSelection = resolveResearchEngineSelection ?? {
            guard let claudeBinaryPath = resolveClaudeBinaryPath() else { return nil }
            return ResearchEngineSelection(kind: .claudeCode, binaryPath: claudeBinaryPath)
        }
        // The default real factory builds the engine matching the resolved KIND, reading
        // the app-wide "Use my Claude Code setup" setting FRESH each time a Claude session
        // is spawned (a fresh engine per run) so a toggle applies on the next run with no
        // respawn. Codex takes no such flag. Tests may inject their own `makeEngine`.
        self.makeEngine = makeEngine ?? { kind, binaryPath in
            switch kind {
            case .claudeCode:
                return ClaudeResearchEngine(
                    binaryPath: binaryPath,
                    useClaudeCustomizations: resolveUseClaudeCustomizations()
                )
            case .codex:
                return CodexResearchEngine(binaryPath: binaryPath)
            }
        }
        self.generateSessionID = generateSessionID
        self.applicationSupportDirectory = applicationSupportDirectory
        self.homeDirectoryPath = homeDirectoryPath
        self.manifestStore = manifestStore
        self.audioCuePlayer = audioCuePlayer
        // Forward the test-only positioning offset to every owned overlay controller BEFORE
        // the init-time `refreshOverlay()` below can show the badge — so under a real-path
        // test the badge/overlay/results windows anchor off-screen from their first frame.
        stackedOverlay.testAnchorOriginOffset = testAnchorOriginOffset
        recentsBadge.testAnchorOriginOffset = testAnchorOriginOffset
        recentsResultsWindow.testAnchorOriginOffset = testAnchorOriginOffset
        stackedOverlay.onToggleExpandRequested = { [weak self] in self?.toggleStackExpansion() }

        // Seed BOTH cluster surfaces with the restored drag offset (before the init-time
        // `refreshOverlay()` below lays them out), and wire each one's live-drag report to the
        // single central handler that persists + syncs the move to both.
        stackedOverlay.applyUserColumnDragOffset(overlayColumnDragOffset)
        recentsBadge.applyUserColumnDragOffset(overlayColumnDragOffset)
        stackedOverlay.onUserColumnDragged = { [weak self] newOffset in self?.handleOverlayColumnDragged(newOffset) }
        recentsBadge.onUserColumnDragged = { [weak self] newOffset in self?.handleOverlayColumnDragged(newOffset) }

        // Wire the always-present recents badge. Rows are pulled FRESH per list-open
        // from the SAME manifest source History reads (via `HistoryRowBuilder`), sliced
        // to the top-N — so the recents list can never drift from History's content or
        // order. Each row offers BOTH outputs (the results page + the transcript), opened
        // the SAME way a History-window row / a done pill's affordances do, and "Show all
        // history" opens the full window for the rest.
        recentsBadge.recentRowsProvider = { [manifestStore] in
            ResearchRecentsListBuilder.recentRows(from: manifestStore.loadSessions(), now: Date())
        }
        recentsBadge.liveDismissedSessionIDsProvider = { [weak self] in
            self?.dismissedSessionIDs ?? []
        }
        recentsBadge.onPerformRowAction = { [weak self] action in self?.performRecentsRowAction(action) }
        recentsBadge.onShowAllHistory = { [weak self] in self?.historyWindowController.show() }

        // The manager's OWN History window (opened by a done pill's "view history" / recents)
        // routes its detail-pane follow-up composer back through the manager — the same
        // reactivation path a spoken follow-up uses.
        historyWindowController.followUpRouter = self

        // Wire the History "Resume in Terminal" action to the app's ALREADY-RESOLVED binary path
        // for the PRODUCING engine (the same injected `resolveResearchBinaryPath` that reads the
        // startup-built registry — a cached lookup, never a fresh detection scan). Both engines
        // resolve: a finished Codex run resumes via the codex binary (`codex resume <thread_id>`)
        // even while Claude is the currently-selected engine, and vice versa.
        historyWindowController.resolveResumeBinaryPath = { [resolveResearchBinaryPath = self.resolveResearchBinaryPath] engine in
            switch engine {
            case .claudeCode: return resolveResearchBinaryPath(.claudeCode)
            case .codex: return resolveResearchBinaryPath(.codex)
            }
        }

        // Show the badge immediately as the idle presence (no toast is active yet).
        refreshOverlay()
    }

    // MARK: - Public entry points

    /// Spawns a NEW research session for `taskDescription` and starts it immediately.
    /// ALWAYS creates a new concurrent session — a second `[RESEARCH]` while one is
    /// running is NOT rejected. Returns the new session's id.
    @discardableResult
    func startSession(taskDescription: String) -> ResearchSessionID {
        let sessionID = mintUniqueSessionID()
        let session = ResearchSession(
            sessionID: sessionID,
            taskDescription: taskDescription,
            resolveEngineSelection: resolveResearchEngineSelection,
            makeEngine: makeEngine,
            applicationSupportDirectory: applicationSupportDirectory,
            homeDirectoryPath: homeDirectoryPath,
            manifestStore: manifestStore,
            audioCuePlayer: audioCuePlayer,
            testAnchorOriginOffset: testAnchorOriginOffset
        )
        wireSessionCallbacks(session)

        sessionsByID[sessionID] = session
        sessionOrder.append(sessionID)

        session.start()
        refreshOverlay()
        return sessionID
    }

    /// Stops one specific session (SIGTERM to its process). Never touches any other
    /// session or the warm session. If the stopped session was FOCUSED, focus is
    /// cleared (BLOCKING #2): Stop deselects, so the next utterance is a fresh
    /// quick-answer / new-research rather than a follow-up on a non-resumable session.
    func stopSession(id: ResearchSessionID) {
        sessionsByID[id]?.stop()
        if focusedSessionID == id {
            clearFocus()
        }
    }

    /// Routes a spoken utterance to the CURRENTLY FOCUSED research session as a
    /// voice-native follow-up (continuing that session's own `claude` thread),
    /// returning whether it routed. Returns false when no session is focused, so the
    /// caller falls back to the unchanged warm quick-answer / new-research path.
    @discardableResult
    func followUpOnFocusedSession(prompt: String) -> Bool {
        guard let focusedSessionID, let focusedSession = sessionsByID[focusedSessionID] else {
            return false
        }
        // Honor the session's honest acceptance: a focused-but-non-resumable session
        // (`.idle`/`.failed`/`.stopped`) refuses, and this must report that (false) rather
        // than claim it routed — so no caller silently drops the follow-up.
        return focusedSession.followUp(prompt: prompt)
    }

    /// Routes a spoken utterance to a SPECIFIC research session as a voice-native
    /// follow-up — the session bound to the frontmost results window the user is
    /// actually looking at. This is the robust routing signal (over the ephemeral
    /// `focusedSessionID`) the fix keys on. Returns whether it routed.
    ///
    /// If the session is still LIVE, the follow-up goes to it directly (per-session
    /// FIFO serialization applies). If it is NOT live — e.g. the page was opened from
    /// the History window and its session ended, or the app was relaunched — the
    /// session is RECONSTRUCTED from its manifest entry into a resumable `.completed`
    /// session and the follow-up resumes its existing claude thread. Returns false when
    /// the id is unknown and can't be reconstructed (no completed manifest entry, or
    /// Claude Code isn't installed), so the caller falls back to the unchanged warm
    /// quick-answer / new-research path.
    @discardableResult
    func followUpOnSession(id sessionID: ResearchSessionID, prompt: String) -> Bool {
        // Return TRUE only when the session genuinely ACCEPTED the follow-up. A live session
        // can refuse (a `.idle`/`.failed`/`.stopped` state that turned non-resumable after the
        // composer last reconciled), so honor its own acceptance signal rather than assuming
        // routing — otherwise a stale History composer would clear a draft that never routed.
        if let liveSession = sessionsByID[sessionID] {
            return liveSession.followUp(prompt: prompt)
        }
        guard let reconstructedSession = reconstructFinishedSession(forSessionID: sessionID) else {
            return false
        }
        return reconstructedSession.followUp(prompt: prompt)
    }

    /// The LIVE overlay phase of `sessionID` if it is a currently-live session, else nil
    /// (the session ended / was never live / was reconstructed-then-removed). The History
    /// window's follow-up composer reads this to morph its one button — STOP while the
    /// selected session is a live, actively-working run, SEND otherwise (a completed/
    /// terminal session whose follow-up will RECONSTRUCT + reactivate it).
    func liveOverlayPhase(forSessionID sessionID: ResearchSessionID) -> ResearchOverlayPhase? {
        guard let session = sessionsByID[sessionID] else { return nil }
        let phase = session.overlayPhase
        // A Send-implying phase (done / needsInput) is only reported when the session can
        // ACTUALLY resume a follow-up — a non-followable completed run (e.g. a Codex run
        // that captured no thread_id) reports no live phase, so the History composer offers
        // no Send it would only refuse. Every other phase is reported unchanged (running
        // shows Stop; terminal states are already `.hidden` upstream). The results page
        // stays reachable independently of this.
        switch phase {
        case .done, .needsInput:
            return session.isResumableForFollowUp ? phase : nil
        case .running, .idle, .error, .stopped:
            return phase
        }
    }

    /// Whether a NON-live session could actually be RECONSTRUCTED from the manifest for a
    /// follow-up right now — the exact precondition `reconstructFinishedSession` enforces
    /// (a `.completed` research entry with a deliverable, and a resolvable `claude`). The
    /// History composer reads this to decide whether a not-live selected session presents an
    /// ENABLED Send, so it never offers a Send that `followUpOnSession` would silently refuse.
    /// A LIVE session is handled separately (via `liveOverlayPhase`), so this deliberately
    /// only speaks to the not-live case.
    func canReconstructFinishedSession(forSessionID sessionID: ResearchSessionID) -> Bool {
        guard let entry = manifestStore.loadSessions().first(where: { $0.sessionId == sessionID }),
              entry.kind == .research,
              entry.status == .completed,
              entry.deliverablePath != nil,
              // The engine that produced the run must be one reconstruction supports (Claude,
              // Codex, or a legacy untagged entry treated as Claude). Anything else is out.
              Self.isReconstructableEngineKind(entry.engineKind) else {
            return false
        }
        // Reconstruction resumes the SAME engine that produced the run (from the manifest's
        // `engineKind`), so it needs BOTH that engine's binary installed AND a usable resume
        // handle. Claude resumes by its own session id (always present); Codex resumes by its
        // `thread_id` — the persisted `codexThreadId`, or the id recovered from the transcript
        // path for a run recorded before that field existed. A Codex run with neither is NOT
        // reconstructable (offering it would attempt a `codex exec resume` with no thread).
        let engineKind = Self.reconstructionEngineKind(for: entry)
        guard resolveResearchBinaryPath(engineKind) != nil,
              Self.resumeHandle(for: entry) != nil else {
            return false
        }
        return true
    }

    /// Whether a manifest entry's `engineKind` is one that finished-session reconstruction
    /// can handle: Claude Code, Codex, or a legacy untagged entry (nil, written before engine
    /// tagging existed — those predate Codex research, so they are treated as Claude). This is
    /// the ENGINE-LEVEL gate only; whether a specific run has a usable resume handle (a Codex
    /// run's `thread_id`) is enforced separately by `canReconstructFinishedSession`.
    static func isReconstructableEngineKind(_ engineKind: String?) -> Bool {
        switch engineKind {
        case nil, CoachEngineKind.claudeCode.rawValue, CoachEngineKind.codex.rawValue:
            return true
        default:
            return false
        }
    }

    /// The engine kind reconstruction should rebuild for a manifest entry: the tagged
    /// `engineKind`, or Claude Code for a legacy untagged entry (nil / unrecognized —
    /// those predate Codex research).
    static func reconstructionEngineKind(for entry: ResearchManifestEntry) -> CoachEngineKind {
        guard let rawEngineKind = entry.engineKind,
              let engineKind = CoachEngineKind(rawValue: rawEngineKind) else {
            return .claudeCode
        }
        return engineKind
    }

    /// The durable RESUME handle a finished run needs to continue its thread, or nil when
    /// none is available (→ NOT reconstructable). Claude resumes by its own session id
    /// (always present). Codex resumes by its `thread_id`: the persisted `codexThreadId`
    /// when present, else the id recovered from the transcript path
    /// (`rollout-<ts>-<thread_id>.jsonl`) for a run recorded before that field existed — a
    /// Codex run with neither has no resume handle. Pure (entry in, value out) so the gate
    /// is unit-testable with no manager.
    static func resumeHandle(for entry: ResearchManifestEntry) -> String? {
        switch reconstructionEngineKind(for: entry) {
        case .claudeCode:
            return entry.sessionId
        case .codex:
            if let persistedThreadID = entry.codexThreadId, !persistedThreadID.isEmpty {
                return persistedThreadID
            }
            return CodexResearchEngine.threadID(fromTranscriptPath: entry.transcriptPath)
        }
    }

    /// Rebuilds a NON-live research session from its manifest entry so a History-opened
    /// (or post-relaunch) page can still be followed up on. Only a COMPLETED research
    /// run with a usable working dir + on-disk deliverable is resumable; anything else
    /// (a root/warm entry, a failed/stopped/running run, a missing binary) returns nil.
    /// The rebuilt session is inserted into the live set so its follow-up serializes and
    /// its pill/results behave normally, and so a second follow-up reuses it rather than
    /// reconstructing twice.
    private func reconstructFinishedSession(forSessionID sessionID: ResearchSessionID) -> ResearchSession? {
        // Gate on the shared predicate so availability (the History composer) and the actual
        // reconstruct can never disagree about what counts as resumable.
        guard canReconstructFinishedSession(forSessionID: sessionID) else {
            return nil
        }
        let manifestEntries = manifestStore.loadSessions()
        guard let entry = manifestEntries.first(where: { $0.sessionId == sessionID }),
              let deliverablePath = entry.deliverablePath else {
            return nil
        }
        // Rebuild the SAME engine that produced this run (from the manifest's `engineKind`),
        // resolving THAT engine's binary — a finished Codex run reconstructs via the codex
        // binary even while Claude is the currently-selected engine, and vice versa.
        let engineKind = Self.reconstructionEngineKind(for: entry)
        guard let binaryPath = resolveResearchBinaryPath(engineKind),
              let resumeHandle = Self.resumeHandle(for: entry) else {
            return nil
        }

        let outputDirectory = URL(fileURLWithPath: entry.workingDir, isDirectory: true)
        let deliverableURL = URL(fileURLWithPath: (deliverablePath as NSString).expandingTildeInPath)

        let session = ResearchSession(
            sessionID: sessionID,
            taskDescription: entry.task,
            resolveEngineSelection: resolveResearchEngineSelection,
            makeEngine: makeEngine,
            applicationSupportDirectory: applicationSupportDirectory,
            homeDirectoryPath: homeDirectoryPath,
            manifestStore: manifestStore,
            audioCuePlayer: audioCuePlayer,
            testAnchorOriginOffset: testAnchorOriginOffset
        )
        wireSessionCallbacks(session)

        sessionsByID[sessionID] = session
        sessionOrder.append(sessionID)

        // Build the producing engine and seed its resume handle. `adoptResumeHandle` is a
        // no-op for engines that resume by the session id they already own (Claude) and
        // stores the `thread_id` for Codex (whose freshly-built engine never captured one),
        // so the follow-up turn resumes the ORIGINAL thread rather than starting anew.
        let engine = makeEngine(engineKind, binaryPath)
        engine.adoptResumeHandle(resumeHandle)

        session.adoptFinishedRunForFollowUp(
            engine: engine,
            outputDirectory: outputDirectory,
            deliverableURL: deliverableURL,
            transcriptPath: entry.transcriptPath
        )
        refreshOverlay()
        return session
    }

    /// FULL teardown — used on app quit / engine switch. Not merely "stop active runs":
    /// it disposes the ENTIRE subsystem so nothing is left dangling. It stops/tears down
    /// every session (SIGTERM to any live process, closing each session's clarify panel
    /// and results window — including COMPLETED sessions whose windows persist), cancels
    /// all pending auto-hide/removal work items, clears the session dictionary +
    /// insertion order, clears focus, resets expansion, and hides/clears the stacked
    /// overlay panels. After this there is no leaked NSPanel, Task, timer, or session.
    func stopAll() {
        // Tear down every session — active or completed — so no per-session process,
        // clarify panel, or results window survives. Each teardown is independent.
        for session in sessionsByID.values {
            session.teardown()
        }
        // Cancel every pending keyed auto-hide/removal timer so none fires post-teardown.
        for work in pendingRemovalWorkItems.values {
            work.cancel()
        }
        pendingRemovalWorkItems.removeAll()

        sessionsByID.removeAll()
        sessionOrder.removeAll()
        dismissedSessionIDs.removeAll()
        focusedSessionID = nil
        isStackExpanded = false

        // Hide and clear the shared overlay's own windows (never reached by per-session
        // teardown, so it must be closed explicitly).
        stackedOverlay.hide()
        // Tear down the always-present recents badge (and any open recents list) plus
        // the recents results window, so no overlay window leaks on full teardown.
        recentsBadge.hide()
        recentsResultsWindow.hide()
    }

    /// Marks a session focused: highlights its pill and opens its read-only detail
    /// panel. Re-focusing the already-focused session is a no-op (toggling is via
    /// `handleCompactTap`).
    func focus(id: ResearchSessionID) {
        guard sessionsByID[id] != nil else { return }
        focusedSessionID = id
        refreshOverlay()
    }

    /// Opens the History window focused on `focusSessionID`'s conversation transcript —
    /// the destination of a done pill's / recents row's default click. Read-only; never
    /// touches the run itself. Works whether or not the session is still live (History
    /// reads from the manifest, which was indexed when the run started/completed).
    func openHistory(focusSessionID: ResearchSessionID) {
        // The session most recently asked to open in History — observed by the real-path
        // tests to prove the done-click routes to History (and exactly once) rather than
        // the results page.
        openHistoryCallCountForTesting += 1
        lastOpenedHistorySessionIDForTesting = focusSessionID
        historyWindowController.show(selectSessionID: focusSessionID)
    }

    /// Clears focus back to no-focus (deselect): closes the detail panel and drops the
    /// pill highlight.
    func clearFocus() {
        guard focusedSessionID != nil else { return }
        focusedSessionID = nil
        refreshOverlay()
    }

    // MARK: - Session callback wiring

    private func wireSessionCallbacks(_ session: ResearchSession) {
        session.onLifecycleChanged = { [weak self] changedSession in
            self?.handleSessionLifecycleChanged(changedSession)
        }
        session.onCompactTapRequested = { [weak self] tappedSession in
            self?.handleCompactTap(tappedSession)
        }
        session.onCloseDetailRequested = { [weak self] _ in
            self?.clearFocus()
        }
        session.onViewHistoryRequested = { [weak self] historySession in
            self?.openHistory(focusSessionID: historySession.sessionID)
        }
        session.onDismissRequested = { [weak self] dismissedSession in
            guard let self else { return }
            // A FAILED (.error) pill's dismiss REMOVES the session entirely rather than
            // marking it "dismissed": the run is already dead, and `dismissSession` would
            // stamp `dismissed=true` in the manifest — hiding the "failed" status behind a
            // "dismissed" tag in History. `removeSession` clears it from the live overlay
            // while leaving its `.failed` manifest record intact. Every other terminal state
            // (a done pill) keeps the hide-chrome-only dismiss.
            if dismissedSession.overlayPhase == .error {
                self.removeSession(sessionID: dismissedSession.sessionID)
            } else {
                self.dismissSession(id: dismissedSession.sessionID)
            }
        }
        session.onFollowUpAnswerReady = { [weak self] spokenReply in
            self?.onFollowUpSpokenAnswer?(spokenReply)
        }
    }

    /// A session reached a phase-level transition: refresh the stack and handle the
    /// terminal states.
    ///
    ///   - `.stopped` (the user cancelled the run) still AUTO-HIDES after the linger, as
    ///     the old single-overlay behavior did.
    ///   - `.error` (the run FAILED) is now a PERSISTENT, actionable terminal state — like
    ///     `.done`, it is NOT scheduled for removal. It stays on screen, clearly red and
    ///     dismissible, until the user reads it (tap → detail) or dismisses it, so a failure
    ///     is never silently swept away after 3 seconds.
    ///   - `.done` also persists so the user can still open the results.
    ///
    /// Both terminal `.stopped` and `.error` clear focus if this was the focused session so
    /// the next utterance can't be voice-routed a follow-up onto a non-resumable run
    /// (BLOCKING #2). This is the central guard covering EVERY stop/fail path — including the
    /// pill's own Stop control, which calls `ResearchSession.stop()` directly and bypasses
    /// `stopSession(id:)`. (An `.error` tap RE-focuses to open its detail; see `handleCompactTap`.)
    private func handleSessionLifecycleChanged(_ session: ResearchSession) {
        refreshOverlay()
        // Notify open observers (the History window's view model) of the phase change so a
        // composer keyed to this session can reconcile — e.g. a live selected session moving
        // running → done/needsInput/error/stopped must not leave a stale enabled Send. Emitted
        // on the main actor (this method is @MainActor), after `refreshOverlay`.
        sessionLifecycleChangedSubject.send(session.sessionID)
        switch session.overlayPhase {
        case .stopped:
            if focusedSessionID == session.sessionID {
                clearFocus()
            }
            scheduleRemoval(sessionID: session.sessionID)
        case .error:
            // Persistent + actionable: clear focus (so it isn't voice-routed) but do NOT
            // schedule removal — the failed pill lingers until dismissed.
            if focusedSessionID == session.sessionID {
                clearFocus()
            }
        case .idle, .running, .needsInput, .done:
            break
        }
    }

    /// The pill's tap action, dispatched by the pure `ResearchToastClickAction` mapping
    /// so a SINGLE primary click does exactly ONE thing based on the run's state — the
    /// fix for the double-open (a done tap used to open BOTH the results page AND the
    /// detail/progress view). See `ResearchToastClickAction.action(forPhase:isFocused:)`.
    private func handleCompactTap(_ session: ResearchSession) {
        let action = ResearchToastClickAction.action(
            forPhase: session.overlayPhase,
            isFocused: focusedSessionID == session.sessionID
        )
        switch action {
        case .openClarify:
            session.openClarify()
        case .openHistory:
            // DONE default click → open ONLY the History window on this session's
            // transcript. We still focus for LINEAGE (so a spoken follow-up continues this
            // thread); the live results page stays reachable via the dedicated
            // "view results" button.
            openHistory(focusSessionID: session.sessionID)
            focus(id: session.sessionID)
        case .showDetail:
            focus(id: session.sessionID)
        case .hideDetail, .clearFocus:
            clearFocus()
        }
    }

    /// DISMISS a session's pill (the × control): removes it from the overlay stack
    /// WITHOUT stopping the run. This is deliberately NOT `stopSession` — a live run
    /// keeps going (and stays reachable via History); we only hide its chrome, like
    /// closing a native notification banner. If the dismissed session was focused, its
    /// detail panel is closed too.
    func dismissSession(id: ResearchSessionID) {
        guard sessionsByID[id] != nil else { return }
        dismissedSessionIDs.insert(id)
        // Persist the DISPLAY-only dismissed flag so the recents / History lists dim +
        // tag this session DURABLY across relaunch. Does not touch status/updatedAt —
        // dismiss is not stop, and it must not reorder the lists.
        manifestStore.recordSessionDismissed(sessionId: id, dismissed: true)
        if focusedSessionID == id {
            clearFocus() // clearFocus refreshes the overlay
        } else {
            refreshOverlay()
        }
    }

    // MARK: - Overlay refresh

    private func toggleStackExpansion() {
        isStackExpanded.toggle()
        refreshOverlay()
    }

    /// Rebuilds the stacked overlay from the current sessions, focus, and expansion.
    /// Uses the pure `ResearchOverlayStackLayout` for the collapse-beyond-3 decision.
    /// DISMISSED sessions are filtered out of the visible stack (their runs keep going).
    private func refreshOverlay() {
        let visibleOrder = sessionOrder.filter { !dismissedSessionIDs.contains($0) }
        let layoutPlan = ResearchOverlayStackLayout.plan(
            orderedSessionIDs: visibleOrder,
            isExpanded: isStackExpanded
        )
        let pills = layoutPlan.visibleSessionIDs.compactMap { sessionID -> ResearchStackPillModel? in
            guard let session = sessionsByID[sessionID] else { return nil }
            return ResearchStackPillModel(
                id: sessionID,
                viewModel: session.overlayViewModel,
                isFocused: sessionID == focusedSessionID
            )
        }

        // The detail/progress panel is shown for a focused, still-WORKING session — AND for
        // a focused FAILED (.error) session, so an error tap can open its detail/transcript
        // in place (the persistent-failure requirement). A DONE focused session (lineage-bound
        // after opening its results) must NOT also pop the detail panel — that pairing was the
        // click double-open; a stopped/dismissed session shows nothing either.
        let focusedDetailViewModel: ResearchProgressOverlayViewModel? = {
            guard let focusedSessionID,
                  !dismissedSessionIDs.contains(focusedSessionID),
                  let focusedSession = sessionsByID[focusedSessionID] else { return nil }
            switch focusedSession.overlayPhase {
            case .running, .needsInput, .error:
                return focusedSession.overlayViewModel
            case .idle, .done, .stopped:
                return nil
            }
        }()

        stackedOverlay.render(
            pills: pills,
            controlRow: layoutPlan.controlRow,
            detailViewModel: focusedDetailViewModel
        )

        // Swap between the always-present recents badge and the live toast stack: the
        // badge shows IFF there are zero active toasts, so exactly one of the two ever
        // occupies the top-left.
        updateRecentsBadgePresence(activeToastCount: pills.count)
    }

    /// The single central handler for a live drag reported by EITHER cluster surface (the
    /// toast stack or the idle badge): store the new offset (which persists it via `didSet`),
    /// then sync it to BOTH controllers so the whole cluster stays together and the hidden
    /// surface adopts it too (only one of the two is ever on screen at a time).
    private func handleOverlayColumnDragged(_ newOffset: CGVector) {
        overlayColumnDragOffset = newOffset
        stackedOverlay.applyUserColumnDragOffset(newOffset)
        recentsBadge.applyUserColumnDragOffset(newOffset)
    }

    /// Shows the idle recents badge when nothing is toasting, hiding it the moment a
    /// live toast takes over the top-left.
    private func updateRecentsBadgePresence(activeToastCount: Int) {
        if ResearchRecentsBadgeVisibility.shouldShowBadge(activeToastCount: activeToastCount) {
            recentsBadge.show()
        } else {
            recentsBadge.hide()
        }
    }

    /// Performs a recents-row action the SAME way its History-window / done-pill
    /// counterpart does: "View page" opens the fenced deliverable in the in-app results
    /// window (bound to its session id for follow-up lineage); "View conversation" opens
    /// its transcript in the History window. Reuses the existing results-window / History
    /// paths — no duplicated open logic. The row's ACTION already carries the fence
    /// decision (`ResearchRecentsRowActions.resolve`), so this only dispatches it.
    private func performRecentsRowAction(_ action: ResearchRecentsRowAction) {
        switch action {
        case .openResults(let sessionID, let deliverablePath, let title):
            let htmlFileURL = URL(fileURLWithPath: (deliverablePath as NSString).expandingTildeInPath)
            recentsResultsWindow.show(htmlFileURL: htmlFileURL, title: title, sessionID: sessionID)
        case .openHistory(let sessionID):
            openHistory(focusSessionID: sessionID)
        }
    }

    /// Shows the idle recents presence (the upper-left badge) if no toast is active.
    /// Called by `CompanionManager` at app start once onboarded, so the badge is the
    /// resting Clawdy presence even before the first research run.
    func activateIdlePresence() {
        refreshOverlay()
    }

    // MARK: - Collision-proof id minting

    /// Monotonic counter used only to disambiguate a degenerate id generator that keeps
    /// returning duplicates, guaranteeing the fallback below terminates.
    private var sessionIDDisambiguator = 0

    /// Mints a session id the manager is NOT already tracking. `startSession` overwrote
    /// `sessionsByID[id]` blindly before, so a colliding generator would orphan the
    /// prior session and break teardown/isolation. Here we re-mint on collision, with a
    /// guaranteed-unique suffix fallback if the generator is pathological (always dup).
    private func mintUniqueSessionID() -> ResearchSessionID {
        var candidate = generateSessionID()
        let maximumRemintAttempts = 100
        var remintAttempts = 0
        while sessionsByID[candidate] != nil {
            remintAttempts += 1
            if remintAttempts > maximumRemintAttempts {
                // Degenerate generator: append a strictly-increasing disambiguator until
                // the id is unique. This always terminates.
                repeat {
                    sessionIDDisambiguator += 1
                    candidate = "\(candidate)-\(sessionIDDisambiguator)"
                } while sessionsByID[candidate] != nil
                break
            }
            candidate = generateSessionID()
        }
        return candidate
    }

    // MARK: - Terminal auto-hide / removal

    private func scheduleRemoval(sessionID: ResearchSessionID) {
        guard pendingRemovalWorkItems[sessionID] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.removeSession(sessionID: sessionID)
        }
        pendingRemovalWorkItems[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + terminalStateLingerSeconds, execute: work)
    }

    private func removeSession(sessionID: ResearchSessionID) {
        pendingRemovalWorkItems[sessionID] = nil
        // Fully dispose the session BEFORE dropping it: `teardown()` hides its results
        // window (and clarify panel), which unregisters its `ResearchResultsWindowRegistry`
        // binding. Without this, a removed session's results window could stay visible and
        // bound — so `frontmostSessionID()` would surface an id that is no longer live and
        // (e.g. a failed follow-up → `.failed` in the manifest) not reconstructable, and a
        // later utterance would misroute to a new run. Tearing it down guarantees a removed
        // session's window can never remain frontmost-and-bound.
        sessionsByID[sessionID]?.teardown()
        sessionsByID[sessionID] = nil
        sessionOrder.removeAll { $0 == sessionID }
        dismissedSessionIDs.remove(sessionID)
        if focusedSessionID == sessionID {
            focusedSessionID = nil
        }
        // Collapsing back to <= 3 sessions naturally drops the expanded state.
        if sessionOrder.count <= ResearchOverlayStackLayout.maximumVisiblePills {
            isStackExpanded = false
        }
        refreshOverlay()
    }

    // MARK: - Test hooks

    /// How many times `openHistory(focusSessionID:)` has been called, and the last session
    /// it opened — observed by the real-path tests to prove a done pill's / recents row's
    /// default click routes to History exactly once (and not to the results page).
    private(set) var openHistoryCallCountForTesting = 0
    private(set) var lastOpenedHistorySessionIDForTesting: ResearchSessionID?

    var activeSessionCountForTesting: Int { sessionsByID.count }
    var sessionOrderForTesting: [ResearchSessionID] { sessionOrder }
    func sessionForTesting(id: ResearchSessionID) -> ResearchSession? { sessionsByID[id] }
    var stackedOverlayForTesting: ResearchStackedOverlayController { stackedOverlay }
    var isStackExpandedForTesting: Bool { isStackExpanded }
    var pendingRemovalCountForTesting: Int { pendingRemovalWorkItems.count }
    /// Drives the expand/collapse toggle the way the overlay's "+N more" / "show less"
    /// row does, so a test can exercise the real manager expand path.
    func toggleStackExpansionForTesting() { toggleStackExpansion() }
    /// Drives the real pill-tap dispatch (focus / open clarify / open results + focus)
    /// so a test can exercise the manager's actual tap path, including lineage bind.
    func handleCompactTapForTesting(id: ResearchSessionID) {
        guard let session = sessionsByID[id] else { return }
        handleCompactTap(session)
    }
    /// Drives the real terminal auto-hide REMOVAL synchronously (the DispatchWorkItem's
    /// body), so a test can prove removal tears the session down — hiding its results
    /// window and unregistering its registry binding — without waiting on the linger.
    func removeSessionForTesting(id: ResearchSessionID) { removeSession(sessionID: id) }
    /// Sets the focused session id directly, so a test can exercise the production
    /// follow-up-target precedence (a frontmost results window overriding an unrelated
    /// focused session) without spinning up a full live+focused session.
    func setFocusedSessionIDForTesting(_ id: ResearchSessionID?) { focusedSessionID = id }
    /// The set of currently-dismissed session ids (chrome hidden, run still live).
    var dismissedSessionIDsForTesting: Set<ResearchSessionID> { dismissedSessionIDs }
    /// The number of pills the overlay is currently rendering (post dismiss filter).
    var renderedPillCountForTesting: Int { stackedOverlay.renderedPillCountForTesting }
    /// Whether the overlay's detail/progress panel is currently on screen.
    var detailPanelVisibleForTesting: Bool { stackedOverlay.detailPanelVisibleForTesting }
    /// The recents badge controller, so a test can exercise the real badge/list windows.
    var recentsBadgeControllerForTesting: ResearchRecentsBadgeController { recentsBadge }
    /// Whether the idle recents badge is currently on screen (the visibility-swap gate).
    var recentsBadgeVisibleForTesting: Bool { recentsBadge.isBadgeVisibleForTesting }
    /// Drives the real recents row-action dispatch (results page vs History), so a test
    /// can exercise the manager's actual open path.
    func performRecentsRowActionForTesting(_ action: ResearchRecentsRowAction) {
        performRecentsRowAction(action)
    }
}

// MARK: - History follow-up routing conformance

/// The manager IS the History window's follow-up router: the History composer's submit /
/// stop / phase-morph all go through the manager's EXISTING reactivation path
/// (`followUpOnSession` reconstructs a finished session from the manifest and flips its
/// toast back to working; `stopSession` cancels a live run). No parallel continuation path.
extension ResearchSessionManager: ResearchHistoryFollowUpRouting {}

// MARK: - Pure toast click-action mapping

/// The SINGLE action a primary click on a research pill performs, decided purely from
/// the run's phase and whether it is already focused. Factored out so the "one click →
/// exactly one thing" contract (no double-open) is unit-testable with no manager:
///   - WORKING (running/idle) → toggle the in-progress detail/progress view,
///   - DONE                    → open ONLY the History window (results page via its own button),
///   - NEEDS INPUT             → open the clarify panel,
///   - ERROR (persistent)      → toggle the detail panel so the failure is readable in place,
///   - STOPPED                 → clear focus (the pill is about to auto-hide).
enum ResearchToastClickAction: Equatable {
    /// Open the clarifying-question panel (needs-input).
    case openClarify
    /// Open the History window focused on this session's conversation transcript (the
    /// DEFAULT click for a done pill; the live results page stays reachable via the
    /// dedicated "view results" button).
    case openHistory
    /// Show the in-progress detail/progress view (working, not yet focused).
    case showDetail
    /// Hide the in-progress detail/progress view (working, already focused → toggle off).
    case hideDetail
    /// Clear focus with no window (a terminal pill).
    case clearFocus

    /// The one action for a given phase + focus state. Note DONE maps to `openHistory`
    /// ONLY (never a compound history+detail), which is what eliminates the double-open —
    /// the live results page stays reachable via the dedicated "view results" button.
    static func action(forPhase phase: ResearchOverlayPhase, isFocused: Bool) -> ResearchToastClickAction {
        switch phase {
        case .needsInput:
            return .openClarify
        case .done:
            return .openHistory
        case .running, .idle:
            return isFocused ? .hideDetail : .showDetail
        case .error:
            // A FAILED run is persistent + actionable: tapping it OPENS its detail panel so
            // the user can read the error / transcript in place (toggle, like a running pill).
            return isFocused ? .hideDetail : .showDetail
        case .stopped:
            // A stopped pill is about to auto-hide — a tap just clears focus.
            return .clearFocus
        }
    }
}
