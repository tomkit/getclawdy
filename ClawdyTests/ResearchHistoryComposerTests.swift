//
//  ResearchHistoryComposerTests.swift
//  ClawdyTests
//
//  Coverage for the History window's follow-up composer — the one WRITABLE affordance added
//  to the otherwise read-only History window. Four layers:
//    1. `HistoryComposerAvailability.disposition` — the pure gate on WHAT the composer
//       presents, from the TRUE resumability signals (live phase + reconstructability), NOT
//       the possibly-stale manifest status. The core invariant: never an enabled Send that a
//       follow-up would silently refuse (a stale/ended run, a just-stopped run, the warm root).
//    2. `ResearchHistoryViewModel` submit / stop / disposition — that it routes through the
//       injected router, targets the SELECTED session, preserves the draft on a refused
//       submit, and reconciles the composer after a Stop.
//    3. Draft isolation across sessions (the `.id(sessionId)` keying is a view concern; here
//       we assert the disposition/routing is per-selected-row).
//    4. A REAL-path check that `ResearchSessionManager` conforms to the routing seam and that
//       a History follow-up on a completed manifest session reconstructs + reactivates it.
//

import Testing
import Combine
import Foundation
@testable import Clawdy

// MARK: - Test double for the routing seam

@MainActor
private final class SpyFollowUpRouter: ResearchHistoryFollowUpRouting {
    var livePhaseBySession: [ResearchSessionID: ResearchOverlayPhase] = [:]
    var reconstructableSessions: Set<ResearchSessionID> = []
    /// When false, `followUpOnSession` reports a REFUSED submit (nothing routed) so tests can
    /// assert the draft is preserved.
    var followUpRoutes = true
    private(set) var followedUp: [(id: ResearchSessionID, prompt: String)] = []
    private(set) var stopped: [ResearchSessionID] = []

    /// Drives the lifecycle-change publisher so a test can simulate a live session transitioning
    /// phase WHILE selected in History.
    let lifecycleSubject = PassthroughSubject<ResearchSessionID, Never>()
    var sessionLifecycleChangedPublisher: AnyPublisher<ResearchSessionID, Never> {
        lifecycleSubject.eraseToAnyPublisher()
    }

    /// Simulates an external phase transition: updates the live phase and emits the change, the
    /// way the real manager's `handleSessionLifecycleChanged` does.
    func emitLifecycleChange(sessionID: ResearchSessionID, newPhase: ResearchOverlayPhase?) {
        livePhaseBySession[sessionID] = newPhase
        lifecycleSubject.send(sessionID)
    }

    @discardableResult
    func followUpOnSession(id sessionID: ResearchSessionID, prompt: String) -> Bool {
        followedUp.append((sessionID, prompt))
        // A stop can flip a session's live phase; model the manager's real post-stop truth by
        // leaving `livePhaseBySession` to the test. Routing success is controlled explicitly.
        return followUpRoutes
    }

    func stopSession(id sessionID: ResearchSessionID) {
        stopped.append(sessionID)
        // Mirror the manager: a stopped session's live phase becomes `.stopped`.
        livePhaseBySession[sessionID] = .stopped
    }

    func liveOverlayPhase(forSessionID sessionID: ResearchSessionID) -> ResearchOverlayPhase? {
        livePhaseBySession[sessionID]
    }

    func canReconstructFinishedSession(forSessionID sessionID: ResearchSessionID) -> Bool {
        reconstructableSessions.contains(sessionID)
    }
}

// MARK: - Pure disposition

@MainActor
struct HistoryComposerDispositionTests {

    @Test func liveRunningSessionMorphsToStop() {
        #expect(HistoryComposerAvailability.disposition(
            kind: .research, liveOverlayPhase: .running, canReconstruct: false) == .stop)
    }

    @Test func liveAwaitingOrDoneSessionSends() {
        #expect(HistoryComposerAvailability.disposition(
            kind: .research, liveOverlayPhase: .needsInput, canReconstruct: false) == .send)
        #expect(HistoryComposerAvailability.disposition(
            kind: .research, liveOverlayPhase: .done, canReconstruct: false) == .send)
    }

    @Test func liveStoppedOrErrorOrIdleSessionHidesComposer() {
        // The key BLOCKING-2 case: a just-stopped (or errored/idle) LIVE session must NOT
        // present an enabled Send — `ResearchSession.followUp` would refuse it.
        for phase in [ResearchOverlayPhase.stopped, .error, .idle] {
            #expect(HistoryComposerAvailability.disposition(
                kind: .research, liveOverlayPhase: phase, canReconstruct: false) == .hidden)
        }
    }

    @Test func notLiveReconstructableSessionSends() {
        #expect(HistoryComposerAvailability.disposition(
            kind: .research, liveOverlayPhase: nil, canReconstruct: true) == .send)
    }

    @Test func notLiveNonReconstructableSessionHidesComposer() {
        // The key BLOCKING-1 case: a stale `.running`-with-no-live-session row (nil live phase,
        // not reconstructable because it isn't `.completed`) must NOT present an enabled Send.
        #expect(HistoryComposerAvailability.disposition(
            kind: .research, liveOverlayPhase: nil, canReconstruct: false) == .hidden)
    }

    @Test func rootWarmThreadNeverShowsComposer() {
        #expect(HistoryComposerAvailability.disposition(
            kind: .root, liveOverlayPhase: nil, canReconstruct: true) == .hidden)
        #expect(HistoryComposerAvailability.disposition(
            kind: .root, liveOverlayPhase: .running, canReconstruct: true) == .hidden)
    }
}

// MARK: - View model composer routing (with a temp manifest + spy router)

@MainActor
struct ResearchHistoryComposerViewModelTests {

    /// Builds a view model backed by a temp manifest holding a research entry with the given
    /// terminal status, selects it, and wires the spy router.
    private func makeSelectedViewModel(
        sessionId: String = "hist-1",
        manifestStatus: ResearchSessionStatus,
        router: SpyFollowUpRouter
    ) -> ResearchHistoryViewModel {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-history-composer-\(sessionId)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ResearchManifestStore(fileURL: manifestURL, dateProvider: { fixedDate })
        store.recordResearchSessionStarted(
            sessionId: sessionId,
            title: "Best winter photo spots",
            task: "Best winter photo spots",
            workingDir: tempDir.path,
            transcriptPath: tempDir.appendingPathComponent("\(sessionId).jsonl").path
        )
        if manifestStatus != .running {
            store.recordResearchSessionOutcome(
                sessionId: sessionId,
                status: manifestStatus,
                deliverablePath: manifestStatus == .completed
                    ? tempDir.appendingPathComponent("report.html").path
                    : nil
            )
        }

        let viewModel = ResearchHistoryViewModel(manifestStore: store)
        viewModel.followUpRouter = router
        viewModel.refresh()
        viewModel.select(rowID: sessionId)
        return viewModel
    }

    @Test func completedNotLiveSessionOffersEnabledSendAndRoutesTrimmedPrompt() {
        let router = SpyFollowUpRouter()
        router.reconstructableSessions = ["hist-1"] // a completed run the manager can reconstruct
        let viewModel = makeSelectedViewModel(manifestStatus: .completed, router: router)

        #expect(viewModel.showsComposer)
        #expect(viewModel.composerPrimaryAction == .send)

        let routed = viewModel.submitFollowUp("  add a budget section  ")

        #expect(routed)
        #expect(router.followedUp.count == 1)
        #expect(router.followedUp.first?.id == "hist-1")
        #expect(router.followedUp.first?.prompt == "add a budget section")
    }

    @Test func staleRunningRowWithNoLiveSessionIsNotAnEnabledSend() {
        // BLOCKING 1: manifest says `.running` but there is NO live session and it isn't
        // reconstructable (not `.completed`). The composer must be hidden — never an enabled Send.
        let router = SpyFollowUpRouter() // no live phase, not reconstructable
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)

        #expect(!viewModel.showsComposer)
        #expect(viewModel.composerDisposition == .hidden)
    }

    @Test func forcedSubmitOnRefusedSessionPreservesDraftAndStartsNoRun() {
        // BLOCKING 1: even if a submit is forced (e.g. a race where the session became
        // non-resumable), a refused route reports `false` so the composer keeps the draft, and
        // no run is started beyond the single refused call.
        let router = SpyFollowUpRouter()
        router.followUpRoutes = false // the manager refuses (e.g. reconstruct failed)
        let viewModel = makeSelectedViewModel(manifestStatus: .completed, router: router)

        let routed = viewModel.submitFollowUp("try to resume me")

        #expect(!routed) // caller learns it was refused → the composer keeps the draft
    }

    @Test func stopReconcilesComposerToStoppedSoNoSendIsOffered() {
        // BLOCKING 2: after Stop, the live phase becomes `.stopped`; the composer must reflect
        // that (hidden), not morph back to an enabled Send that would be silently refused.
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)

        #expect(viewModel.composerPrimaryAction == .stop) // live, working → Stop

        viewModel.stopSelectedSession()

        #expect(router.stopped == ["hist-1"])
        #expect(!viewModel.showsComposer) // reconciled to the stopped truth — no Send offered
        #expect(viewModel.composerDisposition == .hidden)
    }

    @Test func liveRunningSelectionMorphsToStop() {
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)

        #expect(viewModel.showsComposer)
        #expect(viewModel.composerPrimaryAction == .stop)
    }

    @Test func emptyOrWhitespaceSubmitIsIgnoredAndReportedNotRouted() {
        let router = SpyFollowUpRouter()
        router.reconstructableSessions = ["hist-1"]
        let viewModel = makeSelectedViewModel(manifestStatus: .completed, router: router)

        #expect(!viewModel.submitFollowUp("    "))
        #expect(router.followedUp.isEmpty)
    }

    // MARK: BLOCKING B — reactive to the selected live session's phase changes

    @Test func selectedLiveSessionTransitionToStoppedReconcilesToHidden() {
        // A live `.running` session is selected (composer is Stop). While it stays selected the
        // session transitions to `.stopped` externally — the composer must reconcile to hidden,
        // never leaving a stale Send/Stop that would route into a refused follow-up.
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)
        #expect(viewModel.composerPrimaryAction == .stop)

        router.emitLifecycleChange(sessionID: "hist-1", newPhase: .stopped)

        #expect(!viewModel.showsComposer)
        #expect(viewModel.composerDisposition == .hidden)
    }

    @Test func selectedLiveSessionTransitionRunningToDoneMorphsStopToSend() {
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)
        #expect(viewModel.composerPrimaryAction == .stop)

        router.emitLifecycleChange(sessionID: "hist-1", newPhase: .done)

        #expect(viewModel.showsComposer)
        #expect(viewModel.composerPrimaryAction == .send)
    }

    @Test func selectedLiveSessionTransitionToErrorReconcilesToHidden() {
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)

        router.emitLifecycleChange(sessionID: "hist-1", newPhase: .error)

        #expect(!viewModel.showsComposer)
    }

    @Test func lifecycleChangeForANonSelectedSessionDoesNotDisturbSelection() {
        // A transition for a DIFFERENT session must not recompute the selected row's composer.
        let router = SpyFollowUpRouter()
        router.livePhaseBySession["hist-1"] = .running
        let viewModel = makeSelectedViewModel(manifestStatus: .running, router: router)
        #expect(viewModel.composerPrimaryAction == .stop)

        router.emitLifecycleChange(sessionID: "some-other-session", newPhase: .stopped)

        #expect(viewModel.composerPrimaryAction == .stop) // unchanged
        #expect(viewModel.showsComposer)
    }
}

// MARK: - Warm results-window follow-up resolution (BLOCKING: refused follow-up not swallowed)

@MainActor
struct FocusedFollowUpResolutionTests {

    /// A ROUTED follow-up records the quiet "continued" line and speaks nothing (the target's
    /// own thread produces the answer) — the unchanged success behavior.
    @Test func routedFollowUpContinuesSilently() {
        let resolution = CompanionManager.FocusedFollowUpResolution.resolve(routed: true)
        #expect(resolution.didContinue)
        #expect(resolution.spokenFallback == nil)
        #expect(resolution.conversationLine == "(continued the focused research page)")
    }

    /// A REFUSED follow-up (the honest `followUpOnSession == false` from a live
    /// `.stopped`/`.error`/`.idle` target, or a failed reconstruction) must NOT record a false
    /// "continued" success AND must NOT vanish silently — it carries a spoken fallback so the
    /// user's words are acknowledged out loud. This is the exact decision the warm-router
    /// `[FOLLOWUP]` branch acts on.
    @Test func refusedFollowUpDoesNotClaimSuccessAndSpeaksFallback() {
        let resolution = CompanionManager.FocusedFollowUpResolution.resolve(routed: false)
        #expect(!resolution.didContinue)
        // Not the false "continued" success line.
        #expect(resolution.conversationLine != "(continued the focused research page)")
        #expect(!resolution.conversationLine.isEmpty)
        // A non-empty spoken message so the spoken follow-up is never silently dropped.
        let spoken = resolution.spokenFallback
        #expect(spoken != nil)
        #expect(!(spoken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

// MARK: - Refused [FOLLOWUP] path drives real branch + settles voiceState (round-4 BLOCKING)

/// A fake Apple TTS whose "playback" drains INSTANTLY (`speakText` returns immediately and
/// `isPlaying` is always false) — modeling the TTS-suppressed/unavailable case deterministically
/// so the speak-then-settle path completes without real audio or the 60s playback poll ceiling.
@MainActor
private final class InstantDrainTTSClient: SpeechTTSProviding {
    private(set) var spokenTexts: [String] = []
    func speakText(_ text: String) async throws { spokenTexts.append(text) }
    var isPlaying: Bool { false }
    func stopPlayback() {}
}

/// A fake TTS whose "playback" STAYS playing until explicitly released (`stopPlayback`),
/// so a test can park a speak-then-settle call mid-playback and deterministically drive
/// the older/newer speaker takeover that exercises the `currentResponseSpeaker` guard.
@MainActor
private final class ControllableTTSClient: SpeechTTSProviding {
    private(set) var spokenTexts: [String] = []
    private var isCurrentlyPlaying = false
    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
        isCurrentlyPlaying = true
    }
    var isPlaying: Bool { isCurrentlyPlaying }
    func stopPlayback() { isCurrentlyPlaying = false }
}

@MainActor
struct RefusedFocusedFollowUpBranchTests {

    /// Drives the REAL refused `[FOLLOWUP]` handler (not just the pure mapping): asserts it
    /// records an HONEST "couldn't continue" line (never the false "continued" success), SPEAKS
    /// the fallback (so the words don't vanish), AND settles `voiceState` back to `.idle` after
    /// the fallback completes. The fake drains instantly, covering the TTS-suppressed case
    /// deterministically (no real audio, no wedge).
    @Test func refusedFollowUpRecordsHonestLineSpeaksFallbackAndSettlesVoiceStateToIdle() async {
        let fakeTTS = InstantDrainTTSClient()
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, localTTSClient: fakeTTS)
        // Anchor the lazily-created research manager's overlay off-screen before the follow-up
        // handler below reaches it (via stopAllTTS → researchSessionManager.focusedSessionID).
        manager.researchTestAnchorOriginOffset = offscreenResearchAnchorOffset
        // Pin to Apple so the fallback speaks through the injected fake (not a real ElevenLabs
        // network call the machine's saved preference might otherwise select).
        manager.setSelectedTTSEngineForTesting(.apple)

        await manager.handleFocusedFollowUpResult(routed: false, transcript: "make the background darker")

        let recordedLine = manager.lastConversationAssistantLineForTesting
        #expect(recordedLine != "(continued the focused research page)") // no false success
        #expect(recordedLine?.contains("couldn't continue") == true)     // honest line
        #expect(!fakeTTS.spokenTexts.isEmpty)                            // spoken, not swallowed
        #expect(manager.voiceState == .idle)                            // never wedged on Responding
    }

    /// The SUCCESS path is unchanged: it records the quiet "continued" line, stays silent (no
    /// fallback spoken), and settles to idle synchronously.
    @Test func continuedFollowUpRecordsQuietLineStaysSilentAndSettlesIdle() async {
        let fakeTTS = InstantDrainTTSClient()
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, localTTSClient: fakeTTS)
        // Anchor the lazily-created research manager's overlay off-screen before the follow-up
        // handler below can reach it, so no badge flashes on-screen under test.
        manager.researchTestAnchorOriginOffset = offscreenResearchAnchorOffset
        manager.setSelectedTTSEngineForTesting(.apple)

        await manager.handleFocusedFollowUpResult(routed: true, transcript: "make the background darker")

        #expect(manager.lastConversationAssistantLineForTesting == "(continued the focused research page)")
        #expect(fakeTTS.spokenTexts.isEmpty) // success path speaks nothing here
        #expect(manager.voiceState == .idle)
    }

    /// A spoken research follow-up ANSWER (a question's answer or an iterate confirmation, routed
    /// through `speakResearchFollowUpAnswer`) must SETTLE `voiceState` back to `.idle` after
    /// playback finishes — not just hide the overlay. The fake drains instantly (covering the
    /// TTS-suppressed case) yet still fires onPlaybackStarted (flipping to `.responding`), so this
    /// proves the wedge is cleared: before the fix the answer path left `voiceState` on
    /// `.responding` forever; after it, the panel returns to `.idle`.
    @Test func spokenFollowUpAnswerSettlesVoiceStateToIdleAfterPlayback() async {
        let fakeTTS = InstantDrainTTSClient()
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, localTTSClient: fakeTTS)
        // Keep the lazily-created research overlay off-screen (stopAllTTS reaches it) under test.
        manager.researchTestAnchorOriginOffset = offscreenResearchAnchorOffset
        manager.setSelectedTTSEngineForTesting(.apple)

        await manager.speakResearchFollowUpAnswerAndSettleForTesting("Here's the answer to your question.")

        #expect(fakeTTS.spokenTexts == ["Here's the answer to your question."]) // spoken, not swallowed
        #expect(manager.voiceState == .idle)                                    // never wedged on Responding
    }

    /// The `currentResponseSpeaker === responseSpeaker` guard: when a NEWER spoken
    /// follow-up takes over while an OLDER settle is still awaiting playback, the stale
    /// settle must NOT clobber the newer turn's `voiceState` back to `.idle`. The
    /// controllable fake parks the older call mid-playback; the newer call's
    /// `stopAllTTS()` supersedes it (becoming the current speaker and staying
    /// `.responding`); once released, ONLY the newer (current) speaker settles to idle.
    @Test func staleFollowUpSettleDoesNotClobberNewerTurnVoiceState() async {
        let controllableTTS = ControllableTTSClient()
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, localTTSClient: controllableTTS)
        manager.researchTestAnchorOriginOffset = offscreenResearchAnchorOffset
        manager.setSelectedTTSEngineForTesting(.apple)

        // Older turn: starts speaking and stays "playing", so its settle parks awaiting
        // playback (voiceState flips to .responding).
        let olderTurn = Task { await manager.speakResearchFollowUpAnswerAndSettleForTesting("old answer") }
        await pollUntilTrue("older turn to reach .responding mid-playback") {
            manager.voiceState == .responding && controllableTTS.spokenTexts.contains("old answer")
        }

        // Newer turn takes over: its stopAllTTS() cancels the older speaker (freeing the
        // older settle's await) and makes THIS the current speaker, staying .responding.
        let newerTurn = Task { await manager.speakResearchFollowUpAnswerAndSettleForTesting("new answer") }
        await pollUntilTrue("newer turn to take over and start playing") {
            controllableTTS.spokenTexts.contains("new answer")
        }

        // Give the older, now-unblocked stale settle time to run. With the identity
        // guard it must NOT settle to idle (the newer turn is the current speaker);
        // without the guard it would clobber the newer turn's .responding.
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(manager.voiceState == .responding, "a stale settle must not clobber the newer turn's voiceState")

        // Release playback; the newer (current) speaker settles to idle.
        controllableTTS.stopPlayback()
        await newerTurn.value
        _ = await olderTurn.value
        #expect(manager.voiceState == .idle)
    }
}

/// Polls `condition` on the main actor until true or a short timeout elapses, recording
/// an issue on timeout. Used to await async voiceState transitions deterministically.
@MainActor
private func pollUntilTrue(_ description: String, _ condition: () -> Bool) async {
    for _ in 0..<200 { // ~10s ceiling at 50ms
        if condition() { return }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    Issue.record("timed out waiting for: \(description)")
}

// MARK: - Composer clear-on-route decision (BLOCKING A: draft preserved on refusal)

@MainActor
struct ResearchComposerClearDraftTests {

    /// The REAL decision the composer's `submit()` uses to clear its draft — clears ONLY when
    /// the submit was permitted AND the follow-up routed. A refused route keeps the draft.
    @Test func clearsOnlyWhenPermittedSubmitActuallyRouted() {
        // Permitted Send that routed → clear.
        #expect(ResearchComposerPrimaryAction.shouldClearDraft(action: .send, trimmedDraft: "hi", routed: true))
        // Permitted Send that was REFUSED → keep the draft (the BLOCKING-A hole).
        #expect(!ResearchComposerPrimaryAction.shouldClearDraft(action: .send, trimmedDraft: "hi", routed: false))
    }

    @Test func neverClearsInStopModeEvenIfRouteReportsTrue() {
        // Preserve the Send-in-Stop guard: a STOP-mode submit never clears (it never sends).
        #expect(!ResearchComposerPrimaryAction.shouldClearDraft(action: .stop, trimmedDraft: "hi", routed: true))
    }

    @Test func neverClearsOnEmptyDraft() {
        #expect(!ResearchComposerPrimaryAction.shouldClearDraft(action: .send, trimmedDraft: "", routed: true))
    }
}

// MARK: - Real-path reactivation reuse + reconstruct-predicate consistency

@MainActor
struct ResearchHistoryComposerReactivationTests {

    /// The manager conforms to the History routing seam AND a History follow-up on a COMPLETED
    /// manifest session reconstructs it into the live set and flips its toast back to a working
    /// state — proving the composer reuses the REAL reactivation path (`followUpOnSession`), not
    /// a parallel one. Also asserts `canReconstructFinishedSession` agrees with what the
    /// composer's availability gate reads (true for the completed session).
    @Test func historyFollowUpReconstructsAndReactivatesCompletedSession() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-history-reactivate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let sessionId = "reactivate-1"
        let workingDir = temp.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let deliverable = workingDir.appendingPathComponent("report.html")
        try? "<html></html>".write(to: deliverable, atomically: true, encoding: .utf8)
        let manifestURL = temp.appendingPathComponent("manifest.json")
        let store = ResearchManifestStore(fileURL: manifestURL,
                                          dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) })
        store.recordResearchSessionStarted(
            sessionId: sessionId,
            title: "Reactivate me",
            task: "Reactivate me",
            workingDir: workingDir.path,
            transcriptPath: workingDir.appendingPathComponent("\(sessionId).jsonl").path
        )
        store.recordResearchSessionOutcome(sessionId: sessionId, status: .completed,
                                           deliverablePath: deliverable.path)

        let fakeBinary = try ResearchTestSupport.makeFakeExecutable(scriptBody: "#!/bin/sh\nexit 0\n")

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { fakeBinary },
            applicationSupportDirectory: temp,
            homeDirectoryPath: temp.path,
            manifestStore: store,
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        let router: ResearchHistoryFollowUpRouting = manager

        // The completed session is not live yet, but IS reconstructable — so the composer's
        // gate would present an enabled Send.
        #expect(router.liveOverlayPhase(forSessionID: sessionId) == nil)
        #expect(router.canReconstructFinishedSession(forSessionID: sessionId))

        let routed = router.followUpOnSession(id: sessionId, prompt: "add a budget section")

        #expect(routed)
        #expect(manager.sessionForTesting(id: sessionId) != nil)
        let phase = manager.liveOverlayPhase(forSessionID: sessionId)
        #expect(phase == .running || phase == .done)

        manager.stopAll()
    }

    /// A stale `.running` manifest entry with no live session is NOT reconstructable — the
    /// manager's predicate agrees with the composer hiding the Send (BLOCKING 1, real path).
    @Test func staleRunningManifestEntryIsNotReconstructable() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-history-stale-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let manifestURL = temp.appendingPathComponent("manifest.json")
        let store = ResearchManifestStore(fileURL: manifestURL,
                                          dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) })
        // Recorded as started (status `.running`) but never completed, and no live session.
        store.recordResearchSessionStarted(
            sessionId: "stale-1", title: "Stale", task: "Stale",
            workingDir: temp.path, transcriptPath: temp.appendingPathComponent("stale-1.jsonl").path
        )
        let fakeBinary = try ResearchTestSupport.makeFakeExecutable(scriptBody: "#!/bin/sh\nexit 0\n")

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { fakeBinary },
            applicationSupportDirectory: temp,
            homeDirectoryPath: temp.path,
            manifestStore: store,
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )

        #expect(manager.liveOverlayPhase(forSessionID: "stale-1") == nil)
        #expect(!manager.canReconstructFinishedSession(forSessionID: "stale-1"))
        // And a follow-up genuinely can't route it.
        #expect(!manager.followUpOnSession(id: "stale-1", prompt: "resume"))

        manager.stopAll()
    }

    /// BLOCKING A (real path): a LIVE session that has been STOPPED refuses a follow-up, and
    /// `followUpOnSession` must now report that HONESTLY (false) — not the old unconditional
    /// true — so a stale composer would keep the draft instead of clearing it into nothing.
    @Test func followUpOnSessionReturnsFalseWhenLiveSessionRefuses() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-history-refuse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let sessionId = "refuse-1"
        let workingDir = temp.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let deliverable = workingDir.appendingPathComponent("report.html")
        try? "<html></html>".write(to: deliverable, atomically: true, encoding: .utf8)
        let manifestURL = temp.appendingPathComponent("manifest.json")
        let store = ResearchManifestStore(fileURL: manifestURL,
                                          dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) })
        store.recordResearchSessionStarted(
            sessionId: sessionId, title: "Refuse me", task: "Refuse me",
            workingDir: workingDir.path,
            transcriptPath: workingDir.appendingPathComponent("\(sessionId).jsonl").path
        )
        store.recordResearchSessionOutcome(sessionId: sessionId, status: .completed,
                                           deliverablePath: deliverable.path)
        let fakeBinary = try ResearchTestSupport.makeFakeExecutable(scriptBody: "#!/bin/sh\nexit 0\n")

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { fakeBinary },
            applicationSupportDirectory: temp,
            homeDirectoryPath: temp.path,
            manifestStore: store,
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )

        // Reconstruct it into the live set (a real live session), then STOP it so it becomes a
        // non-resumable `.stopped` live session.
        #expect(manager.followUpOnSession(id: sessionId, prompt: "first, routes"))
        #expect(manager.sessionForTesting(id: sessionId) != nil)
        manager.stopSession(id: sessionId)
        #expect(manager.liveOverlayPhase(forSessionID: sessionId) == .stopped)

        // The now-stopped LIVE session refuses — and the manager reports it honestly as false.
        #expect(!manager.followUpOnSession(id: sessionId, prompt: "second, refused"))

        manager.stopAll()
    }
}
