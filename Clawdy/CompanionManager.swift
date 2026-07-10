//
//  CompanionManager.swift
//  Clawdy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Pure mapping for the menu-bar panel's warm quick-answer control: whether a STOP
/// (cancel) control should be shown for a given voice state. Stop is offered while the
/// turn is WORKING (processing the model's answer) or SPEAKING (responding — TTS is
/// playing) so the user can cancel it; when idle or merely listening there is nothing
/// to stop and the panel shows its normal chrome instead. Factored out so the mapping
/// is unit-testable with no view.
enum CompanionQuickAnswerControl {
    static func shouldShowStop(forVoiceState voiceState: CompanionVoiceState) -> Bool {
        switch voiceState {
        case .processing, .responding:
            return true
        case .idle, .listening:
            return false
        }
    }
}

/// Pure decision for the capture-overlap optimization: a screenshot capture is
/// kicked off at push-to-talk PRESS so it overlaps the user speaking. When the
/// transcript lands we either reuse that in-flight capture (if it finished
/// successfully) or capture fresh (if there was none, or it failed). Pulled out
/// as a pure function so the ordering is unit-testable.
enum ScreenCaptureOverlapPlan {
    enum Source: Equatable {
        /// Reuse the capture started at press — it overlapped the recording.
        case reusePendingCapture
        /// No usable pending capture; capture now.
        case captureFresh
    }

    static func source(hasPendingCapture: Bool, pendingCaptureSucceeded: Bool) -> Source {
        return (hasPendingCapture && pendingCaptureSucceeded) ? .reusePendingCapture : .captureFresh
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    /// The LIVE Screen Recording reading (raw preflight, no sticky fallback).
    /// Distinct from `hasScreenRecordingPermission`, which stays sticky to avoid
    /// re-presenting the whole permissions panel on a transient mid-session false
    /// negative. The panel's Screen Recording row keys its "Grant" affordance off
    /// THIS value so the request that registers the app in the Screen Recording
    /// list stays reachable whenever the permission is genuinely revoked.
    @Published private(set) var hasLiveScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// One target in an ordered pointing SEQUENCE: where on screen the blue cursor
    /// should fly to and point (global AppKit coords, bottom-left origin), which
    /// display it lives on, and a short label for the element. The model may now
    /// name several locations in one reply, so pointing walks these in order.
    struct DetectedElementTarget: Equatable {
        /// Global AppKit screen location (bottom-left origin) the buddy flies to.
        let screenLocation: CGPoint
        /// The display frame (global AppKit coords) of the screen this target is on,
        /// so BlueCursorView knows which screen overlay should animate it.
        let displayFrame: CGRect
        /// Short label describing the element (e.g. "run button"), for analytics.
        let elementLabel: String?
    }

    /// The ordered list of on-screen targets the blue cursor should visit, in the
    /// order the model mentioned them. Parsed from the response; the overlay walks
    /// it (fly to target 0 → dwell → fly to target 1 → … → fly back to the cursor).
    /// Empty when there is nothing to point at.
    @Published var detectedElementTargets: [DetectedElementTarget] = []
    /// Index of the target the buddy is currently pointing at within
    /// `detectedElementTargets`. `nil` means no pointing sequence is active — this
    /// is the signal the transient-hide timing and the single-buddy visibility rule
    /// key off (it replaces the old scalar `detectedElementScreenLocation != nil`).
    /// It stays non-nil until the buddy has flown back to the cursor.
    @Published var currentPointingTargetIndex: Int?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Whether the CURRENT pointing sequence's advances are driven by the ElevenLabs
    /// audio clock (Stage 4) rather than the fixed per-point dwell. When true, the overlay
    /// must NOT auto-advance on its dwell timer for non-final targets — the manager's
    /// audio-sync scheduler calls `advanceToNextPointingTarget` at each element's spoken
    /// word time (minus a lead). When false (Apple TTS, ElevenLabs failed/empty alignment,
    /// or no timing) the overlay keeps its Stage 1–3 fixed-dwell walk (graceful degradation).
    @Published var pointingAdvanceIsAudioSynced = false

    /// Whether a pointing sequence is currently active (targets are being visited or
    /// the buddy is flying back). Used by the transient-cursor hide timing so the
    /// overlay never fades out mid-flight.
    var isPointingSequenceActive: Bool { currentPointingTargetIndex != nil }

    /// The target the buddy is currently pointing at, or `nil` if none is active.
    var currentPointingTarget: DetectedElementTarget? {
        guard let index = currentPointingTargetIndex,
              detectedElementTargets.indices.contains(index) else { return nil }
        return detectedElementTargets[index]
    }

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the welcome bubble.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Stores the freehand annotation strokes the user draws on the cursor display
    /// while holding PTT. Reset at the start of each PTT press so stale strokes from
    /// the previous turn never accidentally appear in the next screenshot composite.
    let annotationStrokeStore = AnnotationStrokeStore()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Registry of locally-installed coaching CLIs (`claude` / `codex`), detected
    /// once at startup. Drives the engine picker and builds the active engine.
    /// Responses are billed to the user's own CLI subscription — no proxy, no keys.
    let coachEngineRegistry = CoachEngineRegistry()

    /// Local, free text-to-speech (AVSpeechSynthesizer). The DEFAULT provider and
    /// the automatic fallback whenever the optional ElevenLabs path is
    /// unavailable or fails. Held as the protocol + injectable (default the real
    /// `LocalSpeechTTSClient`) so a test can substitute a fake whose playback drains
    /// instantly — the speak methods only use protocol members.
    private let localTTSClient: SpeechTTSProviding

    /// Optional higher-quality TTS that calls the ElevenLabs API directly with
    /// the user's own key. Only used when the user selects it AND has saved a
    /// key; otherwise we speak through `localTTSClient`.
    private let elevenLabsTTSClient = ElevenLabsTTSClient()

    /// Cached active engine instance for the currently selected kind. Rebuilt
    /// lazily whenever the user switches engines.
    private var activeCoachEngineCache: CoachEngine?

    /// Resolves (and caches) the CoachEngine for the selected kind, or nil when
    /// no engine is installed / selected.
    private func resolveActiveCoachEngine() -> CoachEngine? {
        guard let selectedEngineKind else { return nil }
        if let cachedEngine = activeCoachEngineCache { return cachedEngine }
        let engine = coachEngineRegistry.makeEngine(
            for: selectedEngineKind,
            useClaudeCustomizations: useClaudeCustomizations
        )
        activeCoachEngineCache = engine
        return engine
    }

    /// Spawns the warm process for the currently-selected engine ahead of the first
    /// push-to-talk so it doesn't pay the cold-start. Resolving the engine already
    /// returns nil unless an engine is both selected AND installed, so this stays
    /// data-driven — it never spawns anything for an uninstalled or unselected
    /// engine. Codex resolves to its engine but inherits the no-op `prewarm`, so
    /// this is harmless there. Launches with the same companion voice system prompt
    /// the first real turn uses so that turn reuses the warm process.
    private func prewarmSelectedEngineIfInstalled() {
        guard let coachEngine = resolveActiveCoachEngine() else { return }
        coachEngine.prewarm(systemPrompt: Self.companionVoiceResponseSystemPrompt)
    }

    /// Manages autonomous research runs handed off by the warm router agent (each a
    /// `[RESEARCH]` directive). Owns N concurrent, fully-isolated `ResearchSession`s —
    /// each its OWN separate `claude` process, Task, and stacked-overlay pill — all
    /// isolated from the warm voice session: a quick answer can't cancel any research
    /// run, and stopping/failing one run can't affect another. Research is Claude-only
    /// for now.
    /// Test-only positioning offset (production default `.zero`, an identity) forwarded into
    /// the lazily-created `researchSessionManager` below — which in turn forwards it to every
    /// overlay controller it and its sessions own. A real-path test that builds a
    /// `CompanionManager` and reaches the research overlay sets this BEFORE first touching the
    /// lazy manager, so its badge/toasts/results windows anchor off-screen instead of flashing
    /// at the top-left. The real app never sets it, so it stays `.zero` and positioning is
    /// byte-for-byte unchanged (no XCTest autodetect).
    var researchTestAnchorOriginOffset: CGVector = .zero

    private lazy var researchSessionManager: ResearchSessionManager = {
        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { [coachEngineRegistry] in
                coachEngineRegistry.detectedBinaryPath(for: .claudeCode)
            },
            // Resolve the binary for a SPECIFIC engine kind, used when RECONSTRUCTING a
            // finished session for follow-up: it must resume the engine that PRODUCED the
            // run (Claude or Codex), independent of whichever engine is currently selected
            // for new runs.
            resolveResearchBinaryPath: { [coachEngineRegistry] engineKind in
                coachEngineRegistry.detectedBinaryPath(for: engineKind)
            },
            // Resolve WHICH research engine + binary a new run uses from the user's
            // SELECTED coach engine (Claude → claude/ClaudeResearchEngine; Codex →
            // codex/CodexResearchEngine), falling back to whichever CLI is installed.
            resolveResearchEngineSelection: { [weak self] in
                self?.resolveResearchEngineSelection()
            },
            // Read the single "Use my Claude Code setup" setting FRESH per research run
            // (a fresh engine is built each run), so a toggle applies on the next run
            // with no respawn — unlike the warm path, which rebuilds its process.
            resolveUseClaudeCustomizations: { [weak self] in self?.useClaudeCustomizations ?? true },
            // Research audio cues are always on (no user toggle). The player's
            // isMuted defaults to `{ false }`, so passing no closure = always plays.
            audioCuePlayer: SystemSoundResearchAudioCuePlayer(),
            testAnchorOriginOffset: researchTestAnchorOriginOffset
        )
        // Route a focused session's voice follow-up reply through THIS manager's TTS
        // provider selection, so it's spoken the same way a quick answer is (Apple /
        // ElevenLabs, with fallback). Wired here (not at app launch) so the research
        // subsystem stays lazily created on first use.
        manager.onFollowUpSpokenAnswer = { [weak self] spokenReply in
            self?.speakResearchFollowUpAnswer(spokenReply)
        }
        return manager
    }()

    /// Resolves WHICH research engine + binary a new research run should use. Prefers the
    /// user's SELECTED coach engine (so a Codex user gets Codex research, a Claude user
    /// gets Claude research); if that kind isn't installed (or none is selected yet),
    /// falls back to whichever single CLI IS installed. Returns nil when no research CLI
    /// is available at all. This is the engine-by-kind seam the research manager consumes.
    private func resolveResearchEngineSelection() -> ResearchEngineSelection? {
        if let selectedEngineKind,
           let binaryPath = coachEngineRegistry.detectedBinaryPath(for: selectedEngineKind) {
            return ResearchEngineSelection(kind: selectedEngineKind, binaryPath: binaryPath)
        }
        // Fallback: whichever engine is installed (deterministic order — Claude first).
        for candidateKind in CoachEngineKind.allCases {
            if let binaryPath = coachEngineRegistry.detectedBinaryPath(for: candidateKind) {
                return ResearchEngineSelection(kind: candidateKind, binaryPath: binaryPath)
            }
        }
        return nil
    }

    /// The research follow-up router the menu-bar History window's detail-pane composer
    /// submits through, so continuing a conversation from History reactivates its toast via
    /// the SAME path a spoken follow-up uses. Exposing the manager (rather than a bespoke
    /// closure) keeps the one reactivation path authoritative.
    var researchFollowUpRouter: ResearchHistoryFollowUpRouting { researchSessionManager }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// Screen capture kicked off at push-to-talk PRESS so it overlaps the user
    /// still speaking, instead of starting only after the transcript finalizes.
    /// Awaited when the transcript lands; re-captured only if it failed.
    private var pendingScreenCaptureTask: Task<[CompanionScreenCapture], Error>?

    /// Drives the visual "thinking" cue: a delayed Task that, after
    /// `ThinkingCueState.appearanceDelaySeconds` of a request running with no
    /// audio/answer yet, flips `isShowingThinkingCue` on. Cancelled the instant the
    /// first audio/answer arrives or the request ends/cancels. NOT a timeout — the
    /// request keeps running regardless.
    private var thinkingCueTask: Task<Void, Never>?
    /// Whether any audio/answer has begun for the current in-flight request. Used
    /// to suppress the thinking cue once the user has something to hear/see.
    private var hasAnswerOrAudioStartedForCurrentRequest = false

    /// Buffers streamed response text into complete sentences for early TTS, and
    /// the speaker that plays them in order. Live only for the duration of one
    /// response; the speaker is kept until the next response so the transient
    /// fade-out can see that audio is still playing.
    private var currentSentenceBuffer: SentenceStreamBuffer?
    private var currentResponseSpeaker: StreamingResponseSpeaker?

    // MARK: - Audio-synced pointing (Stage 4)

    /// Each ElevenLabs clip's timing report, keyed by clip ordinal (0 = first sentence,
    /// 1 = batched remainder), collected via the speaker's `onClipSpoken` as clips start.
    /// The audio-sync scheduler reads these to find each point's clip + playhead. Reset at
    /// the start of every turn (in `stopAllTTS`).
    private var audioSyncClipReports: [Int: SpokenClipReport] = [:]
    /// The running scheduler that walks the ordered points and calls
    /// `advanceToNextPointingTarget` at each one's spoken word time. Cancelled on a new
    /// turn / stop so a stale schedule can never advance after the audio moved on.
    private var audioSyncPointingScheduler: Task<Void, Never>?

    /// Bounded-wait budget (30ms polls) for the audio-sync ELIGIBILITY decision — how long we
    /// wait for clip 0's report after `finish()` before deciding (BLOCKER 1). ~5s covers a
    /// one-sentence clip's `/with-timestamps` round trip; a rare timeout degrades to the
    /// untimed walk. Only taken when ElevenLabs is the resolved provider.
    private static let audioSyncDecisionMaxPolls = 170 // ~5s
    /// Bounded-wait budget (30ms polls) for a clip report DURING scheduling. This is longer
    /// because clip 1 only starts after clip 0 finishes playing, so its report legitimately
    /// arrives seconds later (the buddy dwells on the prior target meanwhile).
    private static let audioSyncClipReportMaxPolls = 400 // ~12s
    /// The fixed pointing dwell (seconds) the scheduler uses when a clip lacks per-word timing
    /// — the Stage 1–3 untimed cadence, mirrored from `BlueCursorView.perPointDwellSeconds`
    /// so timed and untimed advances feel identical (BLOCKER 3 graceful degradation).
    static let untimedPointingDwellSeconds: Double = 1.3

    private var shortcutTransitionCancellable: AnyCancellable?
    /// Subscription to the monitor's Escape key-down signal, routed to the
    /// annotation-mode escape-hatch (inert unless annotation mode is armed).
    private var escapeKeyPressedCancellable: AnyCancellable?
    /// Final backstop timer for the annotation-mode wedge: if annotation mode
    /// stays armed past `AnnotationModeWatchdog.maximumActiveDurationSeconds`
    /// (because the release never fired), force teardown. Cancelled on every
    /// normal teardown so it never interrupts a real interaction.
    private var annotationModeWatchdogTask: Task<Void, Never>?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    /// Guards the proactive interactive Screen Recording request so it fires at
    /// most ONCE per launch — never from the ~1.5s permission poll. Without this
    /// the poll would re-issue the interactive request every tick and spam the
    /// user; with it, a cold-reset install pops the real prompt exactly once and
    /// then relies on the poll to observe the eventual grant.
    private var hasProactivelyRequestedScreenRecordingThisLaunch = false
    /// Observers that re-check permissions the moment the system signals an
    /// accessibility-trust change or the user switches back to the app (e.g. from
    /// System Settings). These cover the case the 1.5s poll alone misses, because
    /// `AXIsProcessTrusted()` caches its value within the process.
    private var accessibilityTrustChangeObserver: NSObjectProtocol?
    private var appBecameActiveObserver: NSObjectProtocol?
    /// Backstop observer for the annotation-mode wedge: if the app resigns active
    /// while annotation mode is still armed (e.g. a window-manager shortcut grabbed
    /// ctrl+option and the key-UP `flagsChanged` never reached our tap), tear
    /// annotation mode down so the overlay can't stay stuck. Not a permission
    /// monitor, so intentionally NOT counted in
    /// `livePermissionMonitorRegistrationCount`.
    private var appWillResignActiveObserver: NSObjectProtocol?
    /// Number of permission-monitor registrations (poll timer + the two
    /// re-check observers) currently live. Mirrors the stored handles exactly:
    /// incremented when each is created, decremented when each is torn down.
    /// Exposed for tests to assert the start/stop lifecycle leaves nothing
    /// registered even when start() runs more than once.
    private(set) var livePermissionMonitorRegistrationCount = 0
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// What a push-to-talk press should do, decided purely from the current
    /// permission state. Pulled out as a pure function so the gating is unit-testable.
    enum PushToTalkStartDecision: Equatable {
        /// Every required permission is already granted — go straight to recording
        /// with no permission request and no onboarding re-trigger.
        case proceedToRecording
        /// At least one required permission is genuinely missing — surface the
        /// permissions panel so the user can grant it, and do not start recording.
        case routeToPermissionOnboarding
    }

    /// Pure decision used by the push-to-talk handler. Returns `.proceedToRecording`
    /// only when all four permissions are granted; otherwise routes to onboarding.
    /// Critically, the granted case performs NO permission request — a transient
    /// false reading must never re-run the grant flow for an already-permitted user.
    static func pushToTalkStartDecision(
        hasAccessibilityPermission: Bool,
        hasScreenRecordingPermission: Bool,
        hasMicrophonePermission: Bool,
        hasScreenContentPermission: Bool
    ) -> PushToTalkStartDecision {
        let everyRequiredPermissionGranted = hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
        return everyRequiredPermissionGranted ? .proceedToRecording : .routeToPermissionOnboarding
    }

    /// Pure decision for the Escape escape-hatch: Escape cancels annotation mode
    /// ONLY when annotation mode is currently armed. When it's off, Escape is
    /// completely inert here so it never interferes with any other Escape usage in
    /// the OS. Pulled out so the "armed → cancel / off → inert" rule is unit-testable.
    static func escapeShouldCancelAnnotation(isAnnotationModeActive: Bool) -> Bool {
        isAnnotationModeActive
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Whether the non-intrusive visual "thinking" cue should be shown on the
    /// overlay. Set true only when a turn has run past
    /// `ThinkingCueState.appearanceDelaySeconds` with no audio/answer yet; cleared
    /// the moment the first audio/answer arrives or the request ends/cancels.
    /// Observed by BlueCursorView. Never affects whether the request runs.
    @Published private(set) var isShowingThinkingCue: Bool = false

    /// Whether the user is currently in annotation mode — holding PTT and able to
    /// draw freehand strokes on the cursor display. True from PTT press until the
    /// strokes are composited into the screenshot after PTT release; false afterward.
    /// Observed by BlueCursorView to show the annotation overlay and the affordance pill.
    @Published private(set) var isAnnotationModeActive: Bool = false

    /// Opacity of the annotation strokes rendered by `AnnotationOverlayView`. Starts
    /// at 1.0 on each PTT press and animates to 0 over 0.7s once the strokes are
    /// composited into the screenshot, so they visually "sink in" and disappear.
    /// Reset to 1.0 before the next press.
    @Published private(set) var annotationStrokeOpacity: Double = 1.0

    /// Drawable strokes (≥ 2 points) captured synchronously at PTT release — BEFORE
    /// teardownAnnotationMode's 0.7s clearAll timer can wipe annotationStrokeStore.
    /// The dictation fallback path can delay submitDraftText by up to ~2.4s, so reading
    /// the store inside the response Task (which starts only after the transcript fires)
    /// would race the 0.7s clear timer. Storing the snapshot here at release time
    /// guarantees the composite step sees the strokes the user drew, regardless of how
    /// long the dictation system takes to finalize.
    ///
    /// Lifecycle:
    ///   - Cleared at PTT press start (prevents stale strokes from a prior silent tap).
    ///   - Populated at PTT release (synchronous, before teardown).
    ///   - Consumed and cleared in sendTranscriptToClaudeWithScreenshot after compositing.
    ///   - Left empty on a silent-tap or cancelled turn (nothing to composite).
    private var pendingAnnotationStrokes: [AnnotationStroke] = []

    /// The coaching engine the user has selected. Persisted to UserDefaults.
    /// nil only when no engine (`claude` / `codex`) is installed at all.
    @Published private(set) var selectedEngineKind: CoachEngineKind?

    /// Engines actually installed on this machine, for the picker UI.
    var availableEngineKinds: [CoachEngineKind] { coachEngineRegistry.availableEngineKinds }

    /// True when at least one coaching CLI is installed.
    var hasAnyCoachEngineInstalled: Bool { coachEngineRegistry.hasAnyEngineInstalled }

    /// Reads the ElevenLabs API secret from the Keychain. Injectable ONLY so tests
    /// can substitute a spy and prove the secret is read strictly ON-DEMAND — never
    /// at launch and never under Apple TTS. Every real read fires a macOS
    /// Keychain-access prompt, so this must be invoked ONLY when ElevenLabs is the
    /// active provider about to synthesize (or the user is explicitly managing the
    /// key in settings). Defaults to the real Keychain-backed store.
    private let loadElevenLabsAPIKeyFromKeychain: () -> String?

    init(
        loadElevenLabsAPIKeyFromKeychain: @escaping () -> String? = TTSKeychainStore.loadAPIKey,
        localTTSClient injectedLocalTTSClient: SpeechTTSProviding? = nil,
        dictationManager injectedDictationManager: BuddyDictationManager? = nil
    ) {
        // Default to a real dictation manager; tests inject a spy to assert the
        // abort paths cancel WITHOUT submitting (never the normal release path).
        self.buddyDictationManager = injectedDictationManager ?? BuddyDictationManager()
        self.loadElevenLabsAPIKeyFromKeychain = loadElevenLabsAPIKeyFromKeychain
        // Default to the real on-device client (constructed here, on the main actor); tests
        // inject a fake whose playback drains instantly so the speak-then-settle path is fast.
        self.localTTSClient = injectedLocalTTSClient ?? LocalSpeechTTSClient()

        // Restore the persisted engine choice when it's still installed; otherwise
        // default to the first detected engine. CoachEngineKind.allCases is ordered
        // Claude Code first, so when BOTH are installed Claude Code wins by default.
        restoreOrValidateSelectedEngineAgainstAvailableEngines()
    }

    /// Restores the persisted engine choice when it's still installed; otherwise
    /// falls back to the first detected engine (nil only when none is installed).
    /// Shared by init AND `rescanInstalledEnginesAndRevalidateSelection()` so a
    /// now-uninstalled engine can't stay selected and a newly-available one can be
    /// picked — using the exact same rule in both places.
    private func restoreOrValidateSelectedEngineAgainstAvailableEngines() {
        let availableEngineKinds = coachEngineRegistry.availableEngineKinds
        let persistedEngineRawValue = UserDefaults.standard.string(forKey: .selectedCoachEngine)
        let persistedEngineKind = persistedEngineRawValue.flatMap(CoachEngineKind.init(rawValue:))
        if let persistedEngineKind, availableEngineKinds.contains(persistedEngineKind) {
            selectedEngineKind = persistedEngineKind
        } else {
            selectedEngineKind = availableEngineKinds.first
        }
    }

    /// Monotonic token identifying the most recently STARTED engine rescan. Bumped on
    /// the main actor at the start of each rescan; a detached scan captures its token
    /// and its result is applied ONLY if it's still the latest — so a slow older scan
    /// can never clobber a newer scan's availability. @MainActor-isolated (the whole
    /// manager is), so the increment/compare is race-free.
    private var latestEngineRescanGeneration = 0

    /// Bumps and returns the next rescan generation token. Called on the main actor at
    /// the start of a rescan; the matching apply passes the same token back so a
    /// superseded scan is dropped. Exposed for the generation-guard test.
    func beginNextEngineRescanGeneration() -> Int {
        latestEngineRescanGeneration += 1
        return latestEngineRescanGeneration
    }

    /// Re-detects installed engines so a CLI the user installs WHILE Clawdy is
    /// running becomes selectable without a relaunch, then re-validates the current
    /// selection against the new set. Safe to call on every menu-bar panel open.
    ///
    /// The DETECTION runs OFF the main actor: it can spawn a login-shell PATH probe
    /// (up to ~2s) when an engine isn't found on the fast path, and that must never
    /// freeze the menu. Only the apply — which touches published state — hops back to
    /// the main actor, and it is generation-guarded so overlapping panel opens can't
    /// apply an out-of-order (stale) result.
    func rescanInstalledEnginesAndRevalidateSelection() {
        let rescanGeneration = beginNextEngineRescanGeneration()
        Task.detached(priority: .userInitiated) { [weak self] in
            let freshlyDetectedEngines = CoachEngineRegistry.detectInstalledEngines()
            await self?.applyRescannedEngines(freshlyDetectedEngines, forRescanGeneration: rescanGeneration)
        }
    }

    /// Generation-guarded apply: drops the result of a rescan that a newer rescan has
    /// already superseded, so only the most recent scan's engines are ever applied.
    func applyRescannedEngines(_ freshlyDetectedEngines: [DetectedCoachEngine], forRescanGeneration rescanGeneration: Int) {
        guard rescanGeneration == latestEngineRescanGeneration else {
            // A newer rescan started after this one was dispatched — its (fresher)
            // result wins. Dropping this stale one prevents reverting to old
            // availability and mis-moving the selected engine.
            return
        }
        applyRescannedEngines(freshlyDetectedEngines)
    }

    /// Applies a freshly-probed engine set on the main actor. No-ops unless the set of
    /// available engine KINDS actually changed; when it did, publishes the change so
    /// the SwiftUI picker re-renders even if the SELECTED engine is unchanged (the
    /// picker reads the computed `availableEngineKinds`, not a `@Published`), then
    /// re-validates the selection with the shared startup restore rule.
    func applyRescannedEngines(_ freshlyDetectedEngines: [DetectedCoachEngine]) {
        guard coachEngineRegistry.detectedEngineKindsWouldChange(with: freshlyDetectedEngines) else {
            return
        }

        // Publish BEFORE mutating so a view observing this manager invalidates and
        // re-reads the now-larger/smaller availableEngineKinds on the next render.
        objectWillChange.send()
        coachEngineRegistry.applyDetectedEngines(freshlyDetectedEngines)

        let previousSelectedEngineKind = selectedEngineKind
        restoreOrValidateSelectedEngineAgainstAvailableEngines()

        // Only when re-validation actually moved the selection (a now-uninstalled
        // engine dropped, or a freshly-installed one was restored from the persisted
        // choice) do we tear down the stale cached engine and prewarm the new one —
        // the same order setSelectedEngine uses.
        if selectedEngineKind != previousSelectedEngineKind {
            cancelInFlightTurnAndShutDownActiveEngineSession()
            activeCoachEngineCache = nil
            prewarmSelectedEngineIfInstalled()
        }
    }

    func setSelectedEngine(_ engineKind: CoachEngineKind) {
        guard availableEngineKinds.contains(engineKind) else { return }

        // No-op when the selection didn't actually change — never tear down and
        // respawn an already-warm session needlessly.
        guard CoachEngineSwitchPlan.shouldTearDownPreviousAndStartNew(
            previousKind: selectedEngineKind,
            newKind: engineKind
        ) else { return }

        // Cancel any in-flight turn BEFORE tearing down the old session (otherwise
        // `shutdown()` kills the shared process out from under a streaming request,
        // leaking/hanging its continuation), then shut the old engine down — the
        // exact same order the app-quit path uses.
        cancelInFlightTurnAndShutDownActiveEngineSession()

        selectedEngineKind = engineKind
        UserDefaults.standard.set(engineKind.rawValue, forKey: .selectedCoachEngine)

        // Start the newly-selected engine's persistent session right away so the
        // first push-to-talk on it doesn't pay the cold start (no-op for Codex,
        // which holds no long-lived process).
        prewarmSelectedEngineIfInstalled()
    }

    // MARK: - Claude Code customizations setting

    /// Whether the user's own `claude` customizations (CLAUDE.md, skills, MCP, hooks)
    /// load on BOTH the warm quick-answer path AND research runs. DEFAULT TRUE — the
    /// app runs in the user's configured environment out of the box; when false, both
    /// paths pass `--safe-mode` to isolate the run. Persisted to UserDefaults (same
    /// default-true idiom as `isClawdyCursorEnabled`).
    @Published private(set) var useClaudeCustomizations: Bool =
        UserDefaults.standard.object(forKey: .useClaudeCustomizations) == nil
            ? true
            : UserDefaults.standard.bool(forKey: .useClaudeCustomizations)

    /// Persists the "Use my Claude Code setup" setting and makes it take effect on the
    /// NEXT turn/run. The warm process's args are fixed at spawn, so we REBUILD the warm
    /// engine exactly like an engine switch (cancel the in-flight turn BEFORE shutting
    /// the old session down, drop the cached engine, re-prewarm) — the fresh process
    /// spawns with the new `--safe-mode` arg. Research needs no respawn: a fresh
    /// research engine is built per run and reads the new value then.
    func setUseClaudeCustomizations(_ enabled: Bool) {
        guard enabled != useClaudeCustomizations else { return }
        useClaudeCustomizations = enabled
        UserDefaults.standard.set(enabled, forKey: .useClaudeCustomizations)

        cancelInFlightTurnAndShutDownActiveEngineSession()
        activeCoachEngineCache = nil
        prewarmSelectedEngineIfInstalled()
    }

    // MARK: - Text-to-Speech Settings

    /// The (non-secret) TTS preferences are keyed by `DefaultsKey`. The API key
    /// itself is NEVER stored here — it lives in the Keychain (`TTSKeychainStore`).
    /// The NON-SECRET `hasElevenLabsAPIKey` flag mirrors whether a usable ElevenLabs
    /// key is saved, so provider resolution and the settings UI can answer "is a key
    /// configured?" WITHOUT reading the Keychain (which would fire the macOS access
    /// prompt on every launch, even for Apple-TTS users who never need the key). The
    /// secret itself stays in the Keychain and is read only on-demand.

    /// Which TTS engine the user has chosen. Defaults to Apple (free, on-device)
    /// so the app speaks out of the box with no key. Persisted to UserDefaults.
    @Published private(set) var selectedTTSEngineKind: TTSEngineKind = {
        let persistedRawValue = UserDefaults.standard.string(forKey: .selectedTTSEngine)
        return persistedRawValue.flatMap(TTSEngineKind.init(rawValue:)) ?? .apple
    }()

    /// The ElevenLabs voice id the user picked (or typed manually). Defaults to
    /// the stock "Rachel" voice. Persisted to UserDefaults.
    @Published private(set) var elevenLabsVoiceID: String =
        UserDefaults.standard.string(forKey: .elevenLabsVoiceID) ?? ElevenLabsAPI.defaultVoiceID

    /// Mirrors whether a usable ElevenLabs key is currently saved. Published so the
    /// settings UI updates the moment a key is saved or cleared. Seeded from the
    /// NON-SECRET UserDefaults flag — NOT from the Keychain — so constructing the
    /// manager at launch never reads the secret and never triggers the macOS
    /// Keychain-access prompt. The key string itself is never published or held.
    @Published private(set) var hasElevenLabsAPIKey: Bool =
        UserDefaults.standard.bool(forKey: .hasElevenLabsAPIKey)

    func setSelectedTTSEngine(_ engineKind: TTSEngineKind) {
        selectedTTSEngineKind = engineKind
        UserDefaults.standard.set(engineKind.rawValue, forKey: .selectedTTSEngine)
    }

    /// Saves the user's ElevenLabs API key to the Keychain. An empty key clears
    /// the stored value. Updates the NON-SECRET `hasElevenLabsAPIKey` flag (derived
    /// from the value just saved — no Keychain read-back) so the UI reflects it.
    func saveElevenLabsAPIKey(_ apiKey: String) {
        TTSKeychainStore.saveAPIKey(apiKey)
        setHasElevenLabsAPIKeyFlag(TTSProviderSelection.isUsableElevenLabsKey(apiKey))
    }

    /// Removes the stored ElevenLabs API key from the Keychain.
    func clearElevenLabsAPIKey() {
        TTSKeychainStore.deleteAPIKey()
        setHasElevenLabsAPIKeyFlag(false)
    }

    /// Persists the non-secret "a key is configured" flag and mirrors it into the
    /// published state, so both survive relaunch without ever reading the secret.
    private func setHasElevenLabsAPIKeyFlag(_ isConfigured: Bool) {
        UserDefaults.standard.set(isConfigured, forKey: .hasElevenLabsAPIKey)
        hasElevenLabsAPIKey = isConfigured
    }

    /// One-time migration for users who saved an ElevenLabs key BEFORE the
    /// non-secret flag existed: their Keychain has a key but the flag was never
    /// written. Seed the flag from the Keychain ONCE so their selection keeps
    /// working without re-entering the key. Gated on ElevenLabs being the ACTIVE
    /// provider, so an Apple-TTS user's launch never touches the Keychain — that
    /// gate is the whole point (no per-launch access prompt for Apple-TTS users).
    private func reconcileElevenLabsAPIKeyFlagIfNeeded() {
        let defaults = UserDefaults.standard
        // Already reconciled (flag has been written at least once) → nothing to do.
        guard defaults.object(forKey: .hasElevenLabsAPIKey) == nil else { return }
        // Only ElevenLabs users have a reason to read the secret at launch.
        guard selectedTTSEngineKind == .elevenLabs else { return }
        setHasElevenLabsAPIKeyFlag(TTSProviderSelection.isUsableElevenLabsKey(loadElevenLabsAPIKeyFromKeychain()))
    }

    func setElevenLabsVoiceID(_ voiceID: String) {
        let trimmedVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceID.isEmpty else { return }
        elevenLabsVoiceID = trimmedVoiceID
        UserDefaults.standard.set(trimmedVoiceID, forKey: .elevenLabsVoiceID)
    }

    /// Fetches the voices on the user's ElevenLabs account for the settings
    /// picker. Uses the currently saved key. Throws if no key is saved or the
    /// fetch fails, so the UI can fall back to a manual voice-id field.
    func fetchElevenLabsVoices() async throws -> [ElevenLabsVoice] {
        // On-demand read: the user is explicitly managing ElevenLabs in settings.
        elevenLabsTTSClient.apiKey = loadElevenLabsAPIKeyFromKeychain()
        return try await elevenLabsTTSClient.fetchAvailableVoices()
    }

    /// User preference for whether the Clawdy cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults under "isClawdyCursorEnabled" so the choice
    /// survives app restarts.
    @Published var isClawdyCursorEnabled: Bool = CompanionManager.loadClawdyCursorEnabled()

    /// Reads the "isClawdyCursorEnabled" UserDefaults key. If it has been
    /// written, returns its stored value directly. Defaults to true (cursor
    /// shown) when the key has never been written.
    private static func loadClawdyCursorEnabled() -> Bool {
        loadClawdyCursorEnabled(from: .standard)
    }

    /// The load body, parameterized over the `UserDefaults` store so it can be
    /// exercised against an isolated suite in tests. The production caller above
    /// always passes `.standard`, so runtime behavior is unchanged.
    static func loadClawdyCursorEnabled(from defaults: UserDefaults) -> Bool {
        let key = DefaultsKey.clawdyCursorEnabled
        // Key already written — use its stored value directly.
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        // Key has never been written — default to true (cursor shown).
        return true
    }

    func setClawdyCursorEnabled(_ enabled: Bool) {
        isClawdyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: .clawdyCursorEnabled)
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// "Show Clawdy in screen recordings" (Recording Mode). When true, Clawdy's
    /// on-screen overlays — the cursor, annotation strokes, and research chrome —
    /// are visible to EXTERNAL screen recorders (for demos); when false (the
    /// default) they stay invisible to capture. This ONLY flips the overlay
    /// windows' `sharingType`; it NEVER affects Clawdy's own model screenshots,
    /// which always exclude Clawdy's windows at the application level. Persisted to
    /// UserDefaults; `didSet` reassigns `sharingType` on already-on-screen overlays
    /// so the toggle applies without a relaunch (new windows read it at
    /// construction). Not `private(set)` so the panel's Toggle can bind to it.
    @Published var isRecordingModeEnabled: Bool =
        UserDefaults.standard.bool(forKey: .recordingModeEnabled) {
        didSet {
            UserDefaults.standard.set(isRecordingModeEnabled, forKey: .recordingModeEnabled)
            overlayWindowManager.applyRecordingModeSharingType(recordingEnabled: isRecordingModeEnabled)
            ResearchToastPanel.applyRecordingModeToLivePanels(recordingEnabled: isRecordingModeEnabled)
        }
    }

    /// Sets Recording Mode. Provided as a method (mirroring the other setting
    /// setters) so call sites read consistently; the live reassignment happens in
    /// `isRecordingModeEnabled`'s `didSet`.
    func setRecordingModeEnabled(_ enabled: Bool) {
        isRecordingModeEnabled = enabled
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: .hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: .hasCompletedOnboarding) }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: .hasSubmittedEmail)

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: .hasSubmittedEmail)

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/bDBm4fODD")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clawdy start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")

        // Install the app's richer SCShareableContent-backed screen-recording
        // registration as the SINGLE prompt trigger, replacing WindowPositionManager's
        // minimal default. It both raises the TCC prompt / lists the app AND persists
        // the grant + reveals the overlay. Both the proactive at-launch registration
        // and the panel "Grant" button fire through this one seam.
        WindowPositionManager.screenRecordingRegistrationTrigger = { [weak self] in
            self?.requestScreenContentPermission()
        }

        // Self-register with TCC: if Screen Recording is genuinely ungranted, fire
        // the SINGLE SCShareableContent registration ONCE now so a cold-reset install
        // appears in the Screen Recording list and raises the real system prompt on
        // its own. This is deliberately NOT in the poll — the guard fires it once and
        // the poll only reads preflight thereafter.
        proactivelyRequestScreenRecordingAccessIfNeeded()

        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Seed the non-secret ElevenLabs-key flag for users who saved a key before
        // this flag existed. No-op (and no Keychain read) for Apple-TTS users.
        reconcileElevenLabsAPIKeyFlagIfNeeded()

        // Eliminate first-utterance/first-turn warmup latency: prime the local
        // speech synthesizer and spawn the warm coaching process now, so the
        // user's FIRST push-to-talk doesn't pay either cold start.
        localTTSClient.prewarm()
        prewarmSelectedEngineIfInstalled()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClawdyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Show the always-present recents badge (idle Clawdy presence) once onboarded,
        // so the upper-left has the minimal recents affordance even before the first
        // research run. Lazily spins up the research subsystem (no processes started).
        if hasCompletedOnboarding {
            researchSessionManager.activateIdlePresence()
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation plays.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClawdyAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation.
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementTargets = []
        currentPointingTargetIndex = nil
        detectedElementBubbleText = nil
        // Any audio-synced schedule is tied to this sequence — tear it down with it so a
        // stale advance can't fire after pointing was cleared (Stage 4).
        cancelAudioSyncedPointing()
    }

    /// Begins an ordered pointing sequence: the blue cursor will fly to each target
    /// in turn (target 0 first). Replaces any in-flight sequence cleanly. Empty
    /// input clears pointing instead. The overlay observes `currentPointingTargetIndex`
    /// and drives the visible flight/dwell/advance.
    func beginPointingSequence(_ targets: [DetectedElementTarget]) {
        guard !targets.isEmpty else {
            clearDetectedElementLocation()
            return
        }

        let wasAlreadyPointing = currentPointingTargetIndex != nil
        detectedElementTargets = targets

        if wasAlreadyPointing {
            // A sequence is already running. Reset the index to nil first so the
            // overlay always observes a fresh nil→0 transition even when the
            // previous sequence was also on its first target (a synchronous 0→0
            // set would be coalesced and the overlay would never restart). The new
            // sequence starts on the next runloop tick.
            currentPointingTargetIndex = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Only start if a newer sequence hasn't superseded this one.
                guard self.detectedElementTargets == targets else { return }
                self.currentPointingTargetIndex = 0
            }
        } else {
            currentPointingTargetIndex = 0
        }
    }

    /// Advances the pointing sequence to the next target. This is the CALLABLE STEP
    /// the overlay invokes when it finishes dwelling on the current target.
    ///
    /// FORWARD-COMPAT (do not design this out): the advance is deliberately a
    /// standalone step, NOT welded to a fixed dwell timer. Today the overlay calls
    /// it from a short per-point dwell; the upcoming audio-sync stage (0.0.2) will
    /// instead call it at a scheduled time (each element's spoken word start, minus
    /// a small lead offset) so the cursor arrives just as the word is spoken.
    /// A no-op when there is no next target (the overlay flies back to the cursor
    /// instead — see `nextPointingSequenceStep`).
    func advanceToNextPointingTarget() {
        guard let currentIndex = currentPointingTargetIndex else { return }
        let nextIndex = currentIndex + 1
        guard detectedElementTargets.indices.contains(nextIndex) else { return }
        currentPointingTargetIndex = nextIndex
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        stopPermissionMonitoring()

        // Cancel any in-flight turn, then cleanly terminate the long-lived coaching
        // process on app quit so the warm `claude` process doesn't outlive Clawdy
        // (no-op for Codex). Same order the engine-switch path uses.
        cancelInFlightTurnAndShutDownActiveEngineSession()

        // Independently stop every active research run (SIGTERM to each separate
        // process). This touches ONLY the research subsystem, never the warm session.
        researchSessionManager.stopAll()
    }

    /// Cancels any in-flight turn and tears down the active engine's long-lived
    /// session, IN THIS ORDER: cancel first so the in-flight continuation resumes
    /// exactly once (with CancellationError) via the engine's cancel path, THEN
    /// `shutdown()` the process — never the reverse, which would kill the shared
    /// process out from under an unresolved request and leak/hang its continuation.
    /// Safe no-op when nothing is in flight and no engine is built. Shared by the
    /// engine-switch and app-quit paths so the ordering can never drift between them.
    private func cancelInFlightTurnAndShutDownActiveEngineSession() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        cancelThinkingCue()
        activeCoachEngineCache?.shutdown()
        activeCoachEngineCache = nil
    }

    /// Test-only seam for the engine-switch teardown ordering regression. Installs
    /// `engine` as the active cached engine and `inFlightTurn` as the live turn,
    /// then runs the SAME teardown `setSelectedEngine` performs. Lets the test
    /// exercise the real cancel-before-shutdown ordering end-to-end without the
    /// non-deterministic, filesystem-probed engine registry / voice pipeline.
    func testRunEngineSwitchTeardown(injectingEngine engine: CoachEngine, inFlightTurn: Task<Void, Never>) {
        activeCoachEngineCache = engine
        currentResponseTask = inFlightTurn
        cancelInFlightTurnAndShutDownActiveEngineSession()
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if WindowPositionManager.shouldRunPushToTalkMonitor(forAccessibilityTrusted: currentlyHasAccessibility) {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        // Use the sticky fallback, not the raw preflight: CGPreflightScreenCaptureAccess()
        // returns transient false negatives (the reason hasPreviouslyConfirmedScreenRecordingPermission
        // exists). Reading the raw value here let a momentary miss — e.g. right as the
        // user pressed push-to-talk and the app reactivated — flip allPermissionsGranted
        // to false and re-present the whole permissions panel mid-session. Once the
        // permission has been confirmed granted, keep treating it as granted for the
        // session (macOS requires a relaunch to revoke screen recording anyway).
        hasScreenRecordingPermission = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()

        // The LIVE reading drives the panel's "Grant" affordance so a stale sticky
        // flag (e.g. left over after a TCC reset) can never hide the button that
        // fires the SCShareableContent registration and lists the app.
        hasLiveScreenRecordingPermission = WindowPositionManager.hasLiveScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if WindowPositionManager.accessibilityPermissionWasJustGranted(
            previousIsTrusted: previouslyHadAccessibility,
            currentIsTrusted: hasAccessibilityPermission
        ) {
            ClawdyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClawdyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClawdyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: .hasScreenContentPermission)
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClawdyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Proactively issues the ONE interactive Screen Recording request when the
    /// permission is genuinely ungranted, so a cold-reset install self-registers
    /// in the Screen Recording list and pops the real system prompt without the
    /// user having to hunt for the Grant button. Guarded (via
    /// `hasProactivelyRequestedScreenRecordingThisLaunch`) to fire at most once
    /// per launch. The ~1.5s poll calls `refreshAllPermissions()`, which does NOT
    /// call this, so the interactive request is never looped.
    ///
    /// Under XCTest this real system-prompting side effect is SUPPRESSED: the test
    /// bundle uses the real Clawdy app as its host, so this launch path runs on
    /// every `xcodebuild test`, and the interactive `SCShareableContent`
    /// enumeration/capture would pop the Screen Recording TCC prompt on each run.
    /// Production is unchanged (outside tests `isRunningUnderTests` is false, so
    /// the registration fires exactly as before), and the SILENT preflight status
    /// read below is left untouched so tests can still read permission status.
    func proactivelyRequestScreenRecordingAccessIfNeeded() {
        _ = proactivelyRequestScreenRecordingAccessIfNeeded(
            isRunningUnderTests: TestEnvironment.isRunningUnderTests,
            hasLivePermission: WindowPositionManager.hasLiveScreenRecordingPermission()
        )
    }

    /// Testable core of the proactive registration: takes the "are we under tests"
    /// decision and the live-permission reading as parameters so the suppression
    /// gate is deterministically unit-testable with an injected registration spy
    /// (the ambient `TestEnvironment.isRunningUnderTests` is always true inside the
    /// test process, so it can't be exercised both ways without injection). Returns
    /// whether the interactive registration request was actually issued: `false`
    /// under tests (the side effect is skipped), otherwise it defers to the
    /// once-per-launch `requestScreenRecordingRegistrationIfUngranted`.
    @discardableResult
    func proactivelyRequestScreenRecordingAccessIfNeeded(
        isRunningUnderTests: Bool,
        hasLivePermission: Bool
    ) -> Bool {
        guard !isRunningUnderTests else { return false }
        return requestScreenRecordingRegistrationIfUngranted(hasLivePermission: hasLivePermission)
    }

    /// Pure-ish orchestration seam behind `proactivelyRequestScreenRecordingAccessIfNeeded()`,
    /// taking the live-permission reading as a parameter so the once-per-launch
    /// guard is unit-testable with an injected registration spy. Returns whether the
    /// registration request was actually issued. Fires the SINGLE SCShareableContent
    /// registration (via `triggerScreenRecordingRegistration()`) at most once: the
    /// first ungranted call flips the guard, so any later call (e.g. a subsequent
    /// poll-driven attempt) is a no-op. This routes through the SAME shared trigger
    /// the panel "Grant" button uses, and sets the shared once-per-launch
    /// "prompt already shown" flag, so only one screen-recording prompt fires.
    @discardableResult
    func requestScreenRecordingRegistrationIfUngranted(hasLivePermission: Bool) -> Bool {
        guard WindowPositionManager.shouldProactivelyRequestScreenRecordingAtLaunch(
            hasLivePermission: hasLivePermission,
            hasAlreadyRequestedThisLaunch: hasProactivelyRequestedScreenRecordingThisLaunch
        ) else {
            return false
        }
        hasProactivelyRequestedScreenRecordingThisLaunch = true
        WindowPositionManager.triggerScreenRecordingRegistration()
        return true
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: .hasScreenContentPermission)
                    ClawdyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClawdyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    ///
    /// Polling alone is unreliable for Accessibility: `AXIsProcessTrusted()` caches
    /// its result within the process, so repeatedly reading it can keep returning a
    /// stale `false` after the user grants the permission. To catch the change
    /// promptly we also re-check on two system signals:
    ///   1. The `com.apple.accessibility.api` distributed notification that the
    ///      accessibility subsystem posts when the trust state changes.
    ///   2. The app becoming active again (e.g. the user returning from the
    ///      System Settings > Accessibility pane).
    func startPermissionPolling() {
        // Tear down any existing registrations first so a second start() never
        // leaks the previous timer / observers. Without this, re-registering would
        // overwrite the stored handles and the earlier ones would stay live forever
        // (stop() can only release the handles it can still see).
        stopPermissionMonitoring()

        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
        livePermissionMonitorRegistrationCount += 1

        accessibilityTrustChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
        livePermissionMonitorRegistrationCount += 1

        appBecameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
        livePermissionMonitorRegistrationCount += 1

        // App-resign backstop for the annotation-mode wedge. Registered here
        // alongside the become-active observer, but deliberately NOT counted in
        // livePermissionMonitorRegistrationCount — it guards annotation teardown,
        // not permissions.
        appWillResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tearDownAnnotationModeOnAppResignIfNeeded()
            }
        }
    }

    /// Invalidates the poll timer and removes both re-check observers if present.
    /// Safe to call repeatedly — each handle is only released once.
    func stopPermissionMonitoring() {
        if accessibilityCheckTimer != nil {
            accessibilityCheckTimer?.invalidate()
            accessibilityCheckTimer = nil
            livePermissionMonitorRegistrationCount -= 1
        }
        if let accessibilityTrustChangeObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityTrustChangeObserver)
            self.accessibilityTrustChangeObserver = nil
            livePermissionMonitorRegistrationCount -= 1
        }
        if let appBecameActiveObserver {
            NotificationCenter.default.removeObserver(appBecameActiveObserver)
            self.appBecameActiveObserver = nil
            livePermissionMonitorRegistrationCount -= 1
        }
        // Symmetric teardown of the resign backstop. Uncounted (see registration).
        if let appWillResignActiveObserver {
            NotificationCenter.default.removeObserver(appWillResignActiveObserver)
            self.appWillResignActiveObserver = nil
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        escapeKeyPressedCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // When everything is granted, fall straight through to recording — no
            // permission request, no onboarding. Only when a permission is genuinely
            // missing do we surface the panel so the user can grant the missing one.
            switch Self.pushToTalkStartDecision(
                hasAccessibilityPermission: hasAccessibilityPermission,
                hasScreenRecordingPermission: hasScreenRecordingPermission,
                hasMicrophonePermission: hasMicrophonePermission,
                hasScreenContentPermission: hasScreenContentPermission
            ) {
            case .proceedToRecording:
                break
            case .routeToPermissionOnboarding:
                NotificationCenter.default.post(name: .clawdyShowPanel, object: nil)
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClawdyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clawdyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            stopAllTTS()
            clearDetectedElementLocation()

            // Kick off the screenshot capture NOW, while the user is still
            // speaking, so it overlaps the recording instead of adding its latency
            // serially after the transcript lands. The result is awaited in
            // sendTranscriptToClaudeWithScreenshot. Self-exclusion (sharingType
            // .none) and silent capture are unchanged — they live in the utility.
            pendingScreenCaptureTask?.cancel()
            pendingScreenCaptureTask = Task {
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }

            // Enter annotation mode: clear any leftover strokes from the previous turn
            // (including any stale pendingAnnotationStrokes from a prior silent tap),
            // reset the stroke opacity, and tell the overlay window to start accepting
            // left-click-drag events so the user can draw while speaking.
            pendingAnnotationStrokes = []
            annotationStrokeStore.clearAll()
            annotationStrokeOpacity = 1.0
            isAnnotationModeActive = true
            overlayWindowManager.setAnnotationMode(true, annotationStrokeStore: annotationStrokeStore)

            // Arm the wedge watchdog. If a window-manager shortcut later eats the
            // modifier release so `.released` never fires, this forces teardown
            // after a generous cap. Cancelled by teardownAnnotationMode on every
            // normal exit, so it never interrupts a real interaction.
            startAnnotationModeWatchdog()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClawdyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClawdyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClawdyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

            // Capture drawable strokes synchronously NOW, before teardownAnnotationMode
            // starts the 0.7s clearAll timer. The dictation fallback path can delay
            // submitDraftText by up to ~2.4s, so reading the store inside the response
            // Task races the 0.7s clear. Storing the snapshot here at release time
            // guarantees the composite step sees the strokes regardless of how long
            // dictation takes to finalize.
            pendingAnnotationStrokes = AnnotationStrokeStore.drawableStrokes(
                from: annotationStrokeStore.strokes(forDisplayIndex: 0)
            )

            // Tear down annotation mode immediately on key release — covers BOTH the
            // empty/no-transcript path (submitDraftText never called on silence) and
            // the success path (idempotent; strokes are preserved in pendingAnnotationStrokes).
            teardownAnnotationMode()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Guidance that makes the model OPEN with a very short first sentence so
    /// streaming TTS can begin speaking audio at the first token instead of
    /// waiting ~0.9s for a long opening sentence to finish generating. The short
    /// opener (a quick reaction or lead-in) is then followed by the substance in
    /// the next sentence, keeping the overall reply within the 1-2 sentence spoken
    /// style. One or more inline [POINT:...] tags may still appear in the reply.
    private static let companionFirstSentenceGuidance = "make your FIRST sentence very short and fast — just a few words, like a quick reaction or lead-in (\"ah, gotcha.\" / \"okay, so.\" / \"yep.\"). then give the actual answer in your next sentence. the short opener lets me start speaking instantly, so never lead with a long opening sentence."

    private static let companionVoiceResponseSystemPrompt = """
    you're clawdy, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - \(CompanionManager.companionFirstSentenceGuidance)
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    research mode (routing):
    you double as the router for a separate research subsystem. decide between answering inline versus routing the SAME way a coding agent decides between just DOING a task and stopping to PLAN one first. you PLAN — route to research — when the request needs gathering information from across the web or multiple sources, is multi-step or open-ended, or asks you to produce a compiled artifact (a page, gallery, list, comparison, or report). you just ACT — answer inline as a quick voice reply — when the request is simple, single-step, and immediately answerable right now from what's on the screen or from your own general knowledge.

    so these ROUTE, because each needs web gathering and/or a compiled result: "find photos of aomori", "find the best noise-cancelling headphones", "gather everything on the tohoku earthquake", "put together a page of ramen spots in tokyo", "compare the top three standing desks and build a page". and these you ANSWER yourself, because each is immediately answerable in a sentence or two: "what's the capital of japan", "what does this error mean", "how do i center a div", "where do i click to submit". notice "find/gather/compile X" that lives out on the web is research even when the user never literally says "build a page" — the deliverable is implied.

    when (and only when) the request is one of the plan-worthy, go-gather-and-build ones, do NOT answer it yourself and do NOT speak. instead your ENTIRE reply must be exactly one line: the marker [RESEARCH] followed by a single clear sentence describing the task to research. nothing before it, nothing after it, no spoken text, no point tag.

    examples:
    - user says "find photos of aomori": [RESEARCH] find photos of aomori and build a gallery page of them.
    - user says "research the three best standing desks under a thousand dollars and build me a page comparing them": [RESEARCH] research the three best standing desks under $1000 and build a self-contained comparison page.

    any request that is NOT a go-gather-and-build task — a normal question you can answer well in a sentence or two, or any on-screen pointing question — you answer yourself and never use the marker. an on-screen POINTING question ("where do i click…", "which button…") is ALWAYS a quick answer with a POINT tag, NEVER a research route.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    you can point at MORE THAN ONE thing in a single reply, and you SHOULD point at each distinct named place. whenever your answer names several specific places or landmarks — say the user circled a map and you mention a few spots, or you walk them through a few steps — emit an ORDERED point tag for EACH one, so the cursor visits every place you actually name rather than just the first one or two. place a coordinate tag INLINE, immediately AFTER the clause that names each location, IN THE ORDER you mention them. the blue cursor will then fly to each one in that same order as you speak. don't dump all the tags at the end — each tag goes right after the words it points at. only point at REAL named locations, landmarks, or ui elements the user could look for on screen — not every noun, and not vague areas. keep it to at most \(PointingTuning.maxPointsSoftCap) points in one reply; if you'd naturally name more, point at the most important \(PointingTuning.maxPointsSoftCap).

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is the concise NAME of the thing you're pointing at — the place, landmark, or ui element itself (like "shibuya crossing", "the met", "search bar", or "save button"), 1-3 words. this label is shown on screen next to the cursor as it arrives, so make it the actual name the user would recognize, not a generic phrase. if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help at all, append [POINT:none].

    examples:
    - single point — user asks how to color grade in final cut: "you'll want to open the color inspector [POINT:1100,42:color inspector] — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves."
    - two points, in order — user asks how to commit in xcode: "see that source control menu up top? [POINT:285,11:source control] click that, then hit the commit button down here [POINT:180,540:commit button] to save your changes."
    - three points across a flow — user asks how to run and share their build: "hit the run button first [POINT:40,11:run button], then once it builds open the product menu [POINT:210,11:product menu], and you'll archive it from there to share [POINT:230,180:archive]."
    - several named places — user circles a map region and asks what's interesting around here: "oh nice area. you've got the old town square right here [POINT:300,220:old town square], the riverside market just down here [POINT:420,360:riverside market], the art museum over here [POINT:540,180:art museum], and that little ramen alley tucked in here [POINT:610,300:ramen alley]." point at each place you actually name, with its real name as the label.
    - user asks what html is (nothing worth pointing at): "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Extra guidance appended to the system prompt ONLY on turns where a research
    /// session is FOCUSED (the user just opened / is viewing that session's page).
    /// It biases the warm router to emit a `[FOLLOWUP]` directive for a genuine
    /// continuation of the open page — a question about it or an ask to iterate on
    /// it — so the app can route it to that session's own claude thread. It
    /// deliberately does NOT touch the sacred pointing rule: an on-screen pointing
    /// question STILL gets a quick spoken answer with a [POINT:...] tag, never a
    /// follow-up. Trivially-quick standalone questions are still answered inline,
    /// and a brand-new go-gather-and-build ask still routes via [RESEARCH].
    private static let companionFocusedFollowUpAddendum = """

    focused research page (continue-thread routing):
    right now the user has an open research page you generated for them in an earlier turn — they're looking at it. so ONE more routing option is live on THIS turn: continuing that page's own thread.

    when (and only when) the user's prompt is a genuine CONTINUATION of that open page — asking a question ABOUT its content or sources ("what sources did you use", "which of these is cheapest", "summarize the second section"), or asking to CHANGE/ITERATE on it ("make the background darker", "add a section on X", "remove the last row") — do NOT answer it yourself and do NOT speak. instead your ENTIRE reply must be exactly one line: the marker [FOLLOWUP] followed by a single clear sentence restating what they want. nothing before it, nothing after it, no spoken text, no point tag.

    examples:
    - user says "make the background darker": [FOLLOWUP] change the page's background to a darker color.
    - user says "what sources did you use": [FOLLOWUP] tell me which sources the page was built from.

    CRUCIAL — this does NOT change the pointing rule or quick answers. an on-screen POINTING question ("where do i click", "which button", "point to the submit button") is ALWAYS a quick spoken answer with a [POINT:...] tag, NEVER a [FOLLOWUP]. a quick standalone question unrelated to the page ("what's the capital of japan") you still answer inline. a brand-new go-gather-and-build ask about a DIFFERENT topic still uses [RESEARCH]. only a real continuation of the page you're looking at uses [FOLLOWUP].
    """

    // MARK: - Annotation Teardown

    /// Guaranteed teardown for annotation mode. Safe to call multiple times —
    /// the second call is a no-op if annotation mode is already inactive.
    ///
    /// This covers EVERY exit path:
    ///   - Success: call AFTER compositing strokes into the screenshot.
    ///   - Failure / cancel / no-engine: call before the early return.
    ///   - PTT release: clears isAnnotationModeActive immediately so the
    ///     affordance pill disappears even if sendTranscript hasn't run yet.
    ///
    /// Fade behavior:
    ///   - If strokes are present (success path — just composited): fades them
    ///     to opacity 0 over 0.7s, then clears the store and resets opacity.
    ///   - If no strokes (failure / cancel / single-click): skips the fade and
    ///     resets opacity immediately so no visual artifact remains.
    func teardownAnnotationMode() {
        // Cancel the wedge watchdog — this is the single choke point every normal
        // exit (release / escape / success / resign) flows through, so cancelling
        // here guarantees the watchdog can never fire once we've torn down cleanly.
        annotationModeWatchdogTask?.cancel()
        annotationModeWatchdogTask = nil

        // Remove the mouse event monitor and restore click-through on the overlay.
        // Calling setAnnotationMode(false) when the monitor is already nil is safe —
        // the else branch in the overlay manager is idempotent.
        overlayWindowManager.setAnnotationMode(false, annotationStrokeStore: nil)

        // Clear the active flag so the "Draw to annotate" pill disappears and the
        // annotation render gate in the overlay reverts to cursor-only.
        isAnnotationModeActive = false

        let hasDrawnStrokes = !annotationStrokeStore.strokes.isEmpty
        if hasDrawnStrokes {
            // Animate the composited strokes to opacity 0 so they appear to "sink
            // into" the screenshot. After the animation, clear the store and reset
            // opacity for the next turn. This Task is intentionally independent of
            // any response task so cancelling a turn doesn't skip the cleanup.
            withAnimation(.easeOut(duration: 0.7)) {
                annotationStrokeOpacity = 0.0
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.annotationStrokeStore.clearAll()
                self?.annotationStrokeOpacity = 1.0
            }
        } else {
            // No strokes to fade — just reset opacity so the next turn starts clean.
            annotationStrokeOpacity = 1.0
        }
    }

    /// Escape escape-hatch handler. Gated on `isAnnotationModeActive` so Escape is
    /// completely inert unless annotation mode is armed. When it IS armed (e.g. a
    /// window-manager shortcut ate the modifier release and the overlay is wedged
    /// on), one Escape performs a TRUE abort of the turn.
    private func handleEscapeKeyPressed() {
        guard Self.escapeShouldCancelAnnotation(isAnnotationModeActive: isAnnotationModeActive) else {
            return
        }
        abortAnnotationModeAndDictation()
    }

    /// App-resign backstop for the annotation-mode wedge. If the app resigns active
    /// while annotation mode is still armed — the classic missed-release case where
    /// a window-manager shortcut grabbed the keys and our tap never saw the key-UP —
    /// perform a TRUE abort. Inert when annotation mode is off. Aborting (rather
    /// than only clearing the overlay) is required so the dictation session is
    /// cancelled too: otherwise the later key-up is ignored (held-state already
    /// forced false) and dictation stays live, blocking the next press's
    /// `guard !isDictationInProgress` — trading the overlay wedge for a voice wedge.
    private func tearDownAnnotationModeOnAppResignIfNeeded() {
        guard isAnnotationModeActive else { return }
        abortAnnotationModeAndDictation()
    }

    /// The shared TRUE-abort used by the Escape hatch, the wedge watchdog, and the
    /// app-resign backstop. Unlike the normal PTT release, this cancels the
    /// dictation session WITHOUT finalizing or submitting the in-progress draft (an
    /// abort is never a submit — `stopPushToTalkFromKeyboardShortcut` would request
    /// the final transcript and auto-submit it), cancels any pending capture and
    /// in-flight response, discards drawn strokes, tears annotation mode down, and
    /// clears the monitor's held-state. This leaves `isDictationInProgress` and the
    /// held-state mutually consistent so the next clean Ctrl+Option press re-arms.
    func abortAnnotationModeAndDictation() {
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        pendingScreenCaptureTask?.cancel()
        pendingScreenCaptureTask = nil
        currentResponseTask?.cancel()

        // Cancel-WITHOUT-submit: discard the in-progress draft instead of finalizing
        // it and firing sendTranscriptToClaudeWithScreenshot like a release would.
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)

        pendingAnnotationStrokes = []
        teardownAnnotationMode()
        globalPushToTalkShortcutMonitor.clearHeldShortcutState()
    }

    /// Starts (or restarts) the wedge watchdog. It is a wedge DETECTOR, not a hard
    /// timeout: after each `AnnotationModeWatchdog.maximumActiveDurationSeconds`
    /// interval, if annotation mode is STILL armed it reconciles against the LIVE
    /// hardware modifier flags. If the chord is still physically held the user is
    /// mid-way through a legitimate long spoken prompt, so it re-arms and re-checks
    /// rather than interrupting. Only a confirmed wedge — armed past the interval
    /// with the chord actually up — triggers the abort. Every normal exit cancels
    /// this task via teardownAnnotationMode, so it never fires for a real turn.
    func startAnnotationModeWatchdog() {
        annotationModeWatchdogTask?.cancel()
        annotationModeWatchdogTask = Task { @MainActor [weak self] in
            let intervalSeconds = AnnotationModeWatchdog.maximumActiveDurationSeconds
            while true {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.isAnnotationModeActive else { return }

                let liveFlagsContainShortcut = BuddyPushToTalkShortcut.modifierFlagsContainCurrentShortcut(
                    modifierFlagsRawValue: CGEventSource.flagsState(.combinedSessionState).rawValue
                )
                if AnnotationModeWatchdog.shouldForceTeardown(
                    isAnnotationModeActive: self.isAnnotationModeActive,
                    liveFlagsContainShortcut: liveFlagsContainShortcut,
                    elapsedSeconds: intervalSeconds
                ) {
                    self.abortAnnotationModeAndDictation()
                    return
                }
                // Chord still physically held → legitimate long prompt. Loop and
                // re-check after another interval instead of interrupting the turn.
            }
        }
    }

    /// Test-only: whether the wedge watchdog Task is currently armed. Used to assert
    /// it is cancelled on every normal exit (release / escape / success).
    var isAnnotationModeWatchdogActiveForTesting: Bool {
        annotationModeWatchdogTask != nil
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via local TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        stopAllTTS()

        // LINEAGE follow-up routing: the warm agent stays the router. When a research
        // session is FOCUSED (the user opened / is viewing its page), we DON'T short-
        // circuit here — that would swallow the sacred POINT path for pointing
        // questions. Instead we run the normal warm turn WITH a screenshot, and bias
        // the router's system prompt to emit a [FOLLOWUP] directive ONLY for a genuine
        // continuation of the open page, while a pointing question still gets a POINT
        // and a quick question is still answered inline. The app then routes a
        // [FOLLOWUP] directive to the focused session's own thread. When NO session is
        // focused, the prompt and every downstream branch are exactly as before.
        // Resolve the follow-up target ROBUSTLY: prefer the session bound to the
        // frontmost on-screen results window the user is actually viewing (whether it
        // was opened from a live pill OR from the History window) over the ephemeral
        // click-focus state. This is what fixes "speak feedback about the open page →
        // it started a NEW research run": the open page's lineage no longer depends on
        // focus being set and un-cleared. When neither a results window is frontmost
        // nor a session is focused, `followUpTargetSessionID` is nil and every branch
        // below is exactly as before (warm quick-answer / new-research).
        let followUpTargetSessionID = resolveFollowUpTargetSessionID()
        let hasFollowUpTarget = followUpTargetSessionID != nil
        let effectiveSystemPrompt = hasFollowUpTarget
            ? Self.companionVoiceResponseSystemPrompt + Self.companionFocusedFollowUpAddendum
            : Self.companionVoiceResponseSystemPrompt

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            // Arm the visual thinking cue: if this turn runs past the threshold
            // with no audio/answer, a non-intrusive indicator appears. Purely
            // visual — it never times out or retries the request.
            startThinkingCueCountdown()

            // Bail early with a friendly spoken message if no coaching CLI is
            // installed, instead of silently failing.
            guard let coachEngine = resolveActiveCoachEngine() else {
                voiceState = .idle
                // Guaranteed teardown so annotation mode never wedges on this path.
                teardownAnnotationMode()
                speakLocalErrorFallback()
                scheduleTransientHideIfNeeded()
                return
            }

            do {
                // Use the capture started at push-to-talk press if it finished
                // successfully (it overlapped the user speaking); otherwise capture
                // now. Re-capture only when there was none or it failed.
                let pendingCapture = pendingScreenCaptureTask
                pendingScreenCaptureTask = nil
                let reusableCapture = pendingCapture == nil ? nil : try? await pendingCapture!.value
                var screenCaptures: [CompanionScreenCapture]
                switch ScreenCaptureOverlapPlan.source(
                    hasPendingCapture: pendingCapture != nil,
                    pendingCaptureSucceeded: reusableCapture != nil
                ) {
                case .reusePendingCapture:
                    screenCaptures = reusableCapture ?? []
                case .captureFresh:
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }

                guard !Task.isCancelled else {
                    // Cancelled before we could composite — guaranteed teardown so the
                    // overlay and click-through state never wedge on this path.
                    teardownAnnotationMode()
                    return
                }

                // Composite annotation strokes into the cursor display's screenshot (index 0).
                // Reads `pendingAnnotationStrokes` — populated synchronously at PTT release
                // BEFORE teardownAnnotationMode's 0.7s clearAll timer — so the strokes are
                // available here even when the dictation fallback path delays this call by
                // up to ~2.4s. Strokes must be burned in BEFORE `labeledImages` is built.
                // Only drawable strokes (≥ 2 points) are included; single-click sessions
                // leave pendingAnnotationStrokes empty and skip the compositor entirely.
                if !pendingAnnotationStrokes.isEmpty, !screenCaptures.isEmpty {
                    let cursorDisplayCapture = screenCaptures[0]

                    // Scale the on-screen stroke width (4pt) by the screenshot/display
                    // ratio so the burned-in stroke matches the perceived weight on a
                    // Retina display. At the 800px cap on a 2560pt-wide display the ratio
                    // is 800/2560 ≈ 0.31, giving ~1.25px instead of 4px.
                    let strokeScaleRatio = CGFloat(cursorDisplayCapture.screenshotWidthInPixels)
                        / CGFloat(cursorDisplayCapture.displayWidthInPoints)
                    let scaledLineWidthPx = 4.0 * strokeScaleRatio

                    let compositedImageData = try? AnnotationImageCompositor.composite(
                        capture: cursorDisplayCapture,
                        strokes: pendingAnnotationStrokes,
                        lineWidthPx: scaledLineWidthPx,
                        jpegQuality: CompanionScreenCaptureUtility.screenshotJPEGCompressionQuality
                    )
                    if let compositedImageData {
                        screenCaptures[0] = CompanionScreenCapture(
                            imageData: compositedImageData,
                            label: cursorDisplayCapture.label,
                            isCursorScreen: cursorDisplayCapture.isCursorScreen,
                            displayWidthInPoints: cursorDisplayCapture.displayWidthInPoints,
                            displayHeightInPoints: cursorDisplayCapture.displayHeightInPoints,
                            displayFrame: cursorDisplayCapture.displayFrame,
                            screenshotWidthInPixels: cursorDisplayCapture.screenshotWidthInPixels,
                            screenshotHeightInPixels: cursorDisplayCapture.screenshotHeightInPixels
                        )
                    }
                    // Consumed — clear so the next turn cannot reuse these strokes.
                    pendingAnnotationStrokes = []
                }

                // Belt-and-suspenders: tear down annotation mode on the success path too.
                // teardownAnnotationMode() is idempotent — it was already called from the
                // PTT .released handler, so this call finds isAnnotationModeActive=false
                // and the monitor already removed; it either fades any residual strokes or
                // no-ops if the store is already empty.
                teardownAnnotationMode()

                // Build image labels with the actual screenshot pixel dimensions
                // so the model's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so the engine remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Set up streaming TTS: buffer the streamed text into complete
                // sentences and speak each one as it lands, so audio starts on the
                // first sentence instead of waiting for the whole reply. A trailing
                // [POINT:...] tag is stripped by the buffer so it's never spoken.
                let sentenceBuffer = SentenceStreamBuffer()
                let responseSpeaker = StreamingResponseSpeaker(
                    provider: TTSProviderSelection.resolveProviderKind(
                        selectedEngine: selectedTTSEngineKind,
                        hasUsableElevenLabsKey: hasElevenLabsAPIKey
                    ),
                    appleTTSClient: localTTSClient,
                    elevenLabsTTSClient: elevenLabsTTSClient,
                    // On-demand: the speaker reads this ONLY if it resolves to and
                    // synthesizes through ElevenLabs. Under Apple TTS it's never
                    // invoked, so this turn never touches the Keychain.
                    elevenLabsAPIKeyProvider: loadElevenLabsAPIKeyFromKeychain,
                    elevenLabsVoiceID: elevenLabsVoiceID,
                    onPlaybackStarted: { [weak self] in
                        self?.voiceState = .responding
                        // Audio has begun — the thinking cue is no longer needed.
                        self?.markAnswerOrAudioStartedHidingThinkingCue()
                    },
                    // Stage 4: capture each ElevenLabs clip's timing as it starts so the
                    // audio-sync scheduler can advance the cursor at each element's word.
                    onClipSpoken: { [weak self] clipReport in
                        self?.recordSpokenClipForAudioSync(clipReport)
                    }
                )
                currentSentenceBuffer = sentenceBuffer
                currentResponseSpeaker = responseSpeaker

                let (fullResponseText, _) = try await coachEngine.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: effectiveSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedText in
                        self?.handleStreamedResponseText(accumulatedText)
                    }
                )

                guard !Task.isCancelled else { return }

                // ROUTING: the warm agent is the router. Decide — purely from the
                // reply text + whether a research session is focused — whether this
                // turn (a) continues the focused page's own thread ([FOLLOWUP]), (b)
                // spawns a brand-new research run ([RESEARCH]), or (c) is a normal
                // spoken answer / POINT. CRITICAL: a pointing question is (c) even when
                // focused — the agent emits POINT, so the blue cursor is NEVER swallowed
                // by focus. Both directive paths never speak the marker and never point.
                switch Self.routeWarmReply(
                    fullResponseText: fullResponseText,
                    isResearchSessionFocused: hasFollowUpTarget
                ) {
                case .followUpFocusedSession:
                    stopAllTTS()
                    cancelThinkingCue()
                    // Route the user's SPOKEN prompt (not the directive restatement) to the
                    // target session's own thread — the frontmost results window's session
                    // (reconstructed from the manifest if it isn't live). A
                    // `.followUpFocusedSession` route is only produced when a target exists, so
                    // `followUpTargetSessionID` is non-nil here. HONOR the honest Bool: the
                    // target can REFUSE (a live `.stopped`/`.error`/`.idle`, or reconstruction
                    // fails), in which case we must NOT claim it continued and must NOT swallow
                    // the user's words silently — the handler records an honest line and speaks
                    // a fallback, settling `voiceState` back to idle after it finishes.
                    let followUpRouted = followUpTargetSessionID.map {
                        researchSessionManager.followUpOnSession(id: $0, prompt: transcript)
                    } ?? false
                    await handleFocusedFollowUpResult(routed: followUpRouted, transcript: transcript)
                    return
                case .newResearch(let researchTaskDescription):
                    stopAllTTS()
                    cancelThinkingCue()
                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: "(handed this off to research mode)"
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }
                    researchSessionManager.startSession(taskDescription: researchTaskDescription ?? transcript)
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    return
                case .speakOrPoint:
                    break // fall through to the normal quick-answer / POINT path
                }

                // Parse the [POINT:...] tags from Claude's response. There may be
                // several (an ordered sequence, one per location the model named),
                // a single one, or none / [POINT:none].
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Map each parsed point to a global on-screen target, in order.
                // Each point picks the screen capture matching its screen number,
                // falling back to the cursor screen when it wasn't specified. A
                // point whose screen can't be resolved is dropped. We keep each target
                // PAIRED with its parsed point's spoken position so the audio-sync
                // scheduler advances each target at the right word (a dropped point must
                // not shift the remaining targets' positions).
                let pointingTargetsWithSpokenPositions: [(target: DetectedElementTarget, spokenPosition: Int)] = parseResult.points.compactMap { parsedPoint in
                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parsedPoint.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()
                    guard let targetScreenCapture else { return nil }

                    // The coordinate is in the screenshot's pixel space (top-left
                    // origin, e.g. 1280x831). Map to a global AppKit screen location
                    // (bottom-left origin) the blue cursor overlay flies to.
                    let displayFrame = targetScreenCapture.displayFrame
                    let globalLocation = Self.mapScreenshotPointToGlobalScreenLocation(
                        screenshotPoint: parsedPoint.coordinate,
                        screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                        screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                        displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                        displayHeightInPoints: targetScreenCapture.displayHeightInPoints,
                        displayFrame: displayFrame
                    )
                    let target = DetectedElementTarget(
                        screenLocation: globalLocation,
                        displayFrame: displayFrame,
                        elementLabel: parsedPoint.elementLabel
                    )
                    return (target, parsedPoint.spokenPosition)
                }
                let pointingTargets = pointingTargetsWithSpokenPositions.map(\.target)

                // Finalize streaming TTS FIRST (BLOCKER 1): speak whatever sentence(s) hadn't
                // yet been spoken from the authoritative final text (point tag stripped). This
                // MUST happen before the audio-sync decision below — for a one-sentence reply
                // the only ElevenLabs clip is enqueued right here, so deciding earlier saw
                // zero reported clips and always dropped to the fixed dwell. Audio for earlier
                // sentences is already playing; the speaker flips voiceState to .responding
                // the moment the first audio started.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let finalRemainder = sentenceBuffer.consumeFinalText(fullResponseText)
                    responseSpeaker.finish(finalRemainder: finalRemainder, fullSpokenText: spokenText)
                }
                currentSentenceBuffer = nil

                // Handle element pointing if Claude returned any targets.
                // Switch to idle BEFORE starting the sequence so the triangle
                // becomes visible and can fly to the first target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                if !pointingTargets.isEmpty {
                    voiceState = .idle
                    for target in pointingTargets {
                        ClawdyAnalytics.trackElementPointed(elementLabel: target.elementLabel)
                    }
                    // Stage 4 (BLOCKER 1): decide audio-sync AFTER finish, with a bounded wait
                    // for the clip reports, so a genuinely-timed response actually uses timed
                    // sync (Apple / no-timing decides instantly — no needless wait). Setting
                    // the flag BEFORE beginPointingSequence keeps the overlay from
                    // double-driving the advance on its first dwell.
                    let audioSynced = await resolveAudioSyncEligibility()
                    guard !Task.isCancelled else { return }
                    pointingAdvanceIsAudioSynced = audioSynced
                    beginPointingSequence(pointingTargets)
                    if audioSynced {
                        startAudioSyncedPointingSchedule(
                            spokenPositionsByTargetIndex: pointingTargetsWithSpokenPositions.map(\.spokenPosition),
                            spokenText: spokenText
                        )
                    }
                    print("🎯 Element pointing sequence: \(pointingTargets.count) target(s), audioSynced=\(audioSynced)")
                } else {
                    print("🎯 Element pointing: no element")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClawdyAnalytics.trackAIResponseReceived(response: spokenText)
            } catch is CancellationError {
                // User spoke again — response was interrupted. Guaranteed teardown
                // so annotation mode never wedges when a turn is cancelled mid-flight.
                teardownAnnotationMode()
            } catch {
                // An unexpected error ended the turn. Guaranteed teardown so annotation
                // mode never wedges when capture, engine, or encoding throws.
                teardownAnnotationMode()
                ClawdyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakLocalErrorFallback(for: error)
            }

            // The turn has ended (success, error, or cancellation) — the thinking
            // cue must never linger past it.
            cancelThinkingCue()

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clawdy" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClawdyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while isAnyTTSPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for the pointing sequence to finish (the index is cleared
            // when the buddy has flown back to the cursor after the last target)
            while isPointingSequenceActive {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Feeds the latest accumulated streamed response text into the sentence
    /// buffer and speaks each newly-completed sentence early through the active
    /// streaming speaker. Called from the engine's onTextChunk on the main actor.
    private func handleStreamedResponseText(_ accumulatedText: String) {
        // The answer has begun arriving — hide the visual thinking cue (and stop
        // its countdown) immediately.
        markAnswerOrAudioStartedHidingThinkingCue()

        // If the warm router is emitting a routing directive ([RESEARCH] for a new
        // research run, or [FOLLOWUP] for a continuation of the focused page), never
        // speak it: suppress TTS while the streamed text could still be either marker.
        // The final-result handler routes it. Both markers start with "[", so a lone
        // "[" already suppresses until it resolves one way or the other.
        if ResearchDirective.looksLikeResearchPrefix(accumulatedText)
            || FollowUpDirective.looksLikeFollowUpPrefix(accumulatedText) { return }

        guard let sentenceBuffer = currentSentenceBuffer,
              let responseSpeaker = currentResponseSpeaker else { return }
        for sentence in sentenceBuffer.consumeAccumulatedText(accumulatedText) {
            responseSpeaker.enqueueSentence(sentence)
        }
    }

    /// Whether ANY TTS provider is currently producing audio. Used by the
    /// transient-cursor timing so the overlay doesn't fade out mid-sentence
    /// regardless of which provider spoke. Includes the streaming speaker so the
    /// brief gap between queued sentences doesn't read as "finished".
    private var isAnyTTSPlaying: Bool {
        localTTSClient.isPlaying
            || elevenLabsTTSClient.isPlaying
            || (currentResponseSpeaker?.isSpeaking ?? false)
    }

    /// Cancels an in-flight warm QUICK-ANSWER turn AND any TTS currently speaking,
    /// returning the voice pipeline to idle. Wired to the menu-bar panel's Stop control
    /// (shown while processing/responding). This mirrors what a re-press already does —
    /// cancel the current turn (a `control_request` interrupt that ends only THIS turn;
    /// the shared warm `claude` process survives for the next push-to-talk) plus stop
    /// TTS — and then settles the visible state to idle. Touches ONLY the warm path:
    /// never a research run (a pill's Stop is separate) and never the warm process
    /// itself. A no-op when nothing is in flight.
    func cancelQuickAnswer() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        stopAllTTS()
        clearDetectedElementLocation()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// Stops playback on every TTS provider and abandons any streamed-sentence
    /// queue. Called when the user speaks again so a new utterance never overlaps
    /// the previous one.
    private func stopAllTTS() {
        currentResponseSpeaker?.cancel()
        currentResponseSpeaker = nil
        currentSentenceBuffer = nil
        localTTSClient.stopPlayback()
        elevenLabsTTSClient.stopPlayback()
        // Tear down any audio-synced pointing schedule from the previous turn so a stale
        // timer can never advance the cursor after the audio has moved on (Stage 4).
        cancelAudioSyncedPointing()
        // A new utterance (or a re-press) is taking over — clear any thinking cue.
        cancelThinkingCue()
    }

    /// Cancels the audio-sync pointing scheduler and clears its per-turn state. Called at
    /// the start of every turn (via `stopAllTTS`) and when a sequence is superseded, so the
    /// scheduled advances never outlive the audio they were timed against.
    private func cancelAudioSyncedPointing() {
        audioSyncPointingScheduler?.cancel()
        audioSyncPointingScheduler = nil
        audioSyncClipReports = [:]
        pointingAdvanceIsAudioSynced = false
    }

    /// Records one ElevenLabs clip's timing as its audio starts (wired to the speaker's
    /// `onClipSpoken`). The scheduler later locates each clip's text WITHIN the spoken text
    /// to place point positions and the clip boundary on ONE coordinate system (BLOCKER 2).
    private func recordSpokenClipForAudioSync(_ report: SpokenClipReport) {
        audioSyncClipReports[report.clipOrdinal] = report
    }

    /// Resolves — AFTER `finish()`, with a bounded wait for the clip reports — whether this
    /// turn should drive pointing from the ElevenLabs audio clock.
    ///
    /// BLOCKER 1: the old check ran BEFORE `finish()`, so for a one-sentence response (whose
    /// only clip is enqueued by `finish()`) no clip had been reported yet and it ALWAYS
    /// returned false — wrongly dropping a genuinely-timed response to the fixed dwell. We
    /// now decide after the speaker has finished and wait (bounded) for clip 0's report, so
    /// a timed response actually uses timed sync. The wait is short and only taken when
    /// ElevenLabs is the resolved provider — Apple TTS (which never produces timing) is
    /// decided instantly so the untimed walk starts promptly, never after a needless wait.
    private func resolveAudioSyncEligibility() async -> Bool {
        let resolvedProvider = TTSProviderSelection.resolveProviderKind(
            selectedEngine: selectedTTSEngineKind,
            hasUsableElevenLabsKey: hasElevenLabsAPIKey
        )
        guard resolvedProvider == .elevenLabs else { return false }
        // Wait (bounded) for clip 0's report. Because the speaker now emits a report on EVERY
        // path (real timing on success, nil alignment on Apple fallback — BLOCKER 3), this
        // resolves as soon as clip 0's audio starts; it only times out if clip 0 never plays.
        let firstClip = await awaitClipReport(ordinal: 0, maxWaitPolls: Self.audioSyncDecisionMaxPolls)
        return PointAudioSyncMapper.shouldUseTimedPointing(
            providerIsElevenLabs: true,
            firstClipAlignment: firstClip?.timing.alignment
        )
    }

    /// Starts the scheduler that walks the ordered pointing targets in step with the spoken
    /// audio. Target 0 is already shown by `beginPointingSequence`; this times the ADVANCE to
    /// targets 1…n-1 so the cursor ARRIVES on each just before its element is named. Each
    /// advance is scheduled against the SAME clip's playhead its word time was computed from
    /// (TRAP 2). If a needed clip has no per-word timing, that target degrades to the untimed
    /// fixed dwell rather than hanging or jumping (BLOCKER 3).
    private func startAudioSyncedPointingSchedule(spokenPositionsByTargetIndex: [Int], spokenText: String) {
        audioSyncPointingScheduler?.cancel()
        let targetCount = spokenPositionsByTargetIndex.count

        // BLOCKER 2: locate clip 0 within the spoken text so point positions and the clip
        // boundary share ONE coordinate system (the spoken-text ruler, including the
        // inter-clip separator whitespace). `resolveAudioSyncEligibility` guaranteed clip 0's
        // report is present. A tag at/just after clip 0's last word stays anchored to clip 0.
        let clipZeroText = audioSyncClipReports[0]?.clipText ?? ""
        let clipZeroStartOffset = PointAudioSyncMapper.clipStartOffset(of: clipZeroText, in: spokenText, from: 0) ?? 0
        let clipZeroEndOffset = clipZeroStartOffset + clipZeroText.trimmingCharacters(in: .whitespacesAndNewlines).count

        audioSyncPointingScheduler = Task { @MainActor [weak self] in
            guard let self else { return }
            var targetIndex = 1
            while targetIndex < targetCount {
                if Task.isCancelled { return }

                let spokenPosition = spokenPositionsByTargetIndex[targetIndex]
                // BLOCKER 2 (residual): route by the NAMED word (the word before the tag), so a
                // tag in the separator whitespace after clip 0's last word — or at clip 1's
                // first character — still uses clip 0's alignment/playhead, never clip 1's.
                // (The streaming speaker emits at most two clips: clip 0 = first sentence,
                // clip 1 = batched remainder — so "not clip 0" is clip 1.)
                let namingClipOrdinal = PointAudioSyncMapper.belongsToFirstClip(
                    spokenPosition: spokenPosition,
                    firstClipEndOffset: clipZeroEndOffset,
                    in: spokenText
                ) ? 0 : 1

                // Wait (bounded) for this point's clip to be reported — clip 1 (the batched
                // remainder) is spoken only after clip 0 finishes, so its report can arrive
                // well after the sequence began. This is a DESIRED wait (the buddy dwells on
                // the prior target until clip 1 begins), not the BLOCKER 3 hang: the speaker
                // now always reports a clip, so this resolves when the clip actually plays.
                let clipReport = await self.awaitClipReport(ordinal: namingClipOrdinal, maxWaitPolls: Self.audioSyncClipReportMaxPolls)
                if Task.isCancelled { return }

                // Locate the naming clip on the SAME spoken-text ruler so we re-base into its
                // own coordinate (TRAP 2). MINOR: if clip 1's text can't be located (whitespace
                // normalization mismatch), `clipStartOffset` stays nil and the fire time below
                // is nil → we DEGRADE this target rather than schedule from a guessed offset.
                let namingClipStartOffset: Int?
                if namingClipOrdinal == 0 {
                    namingClipStartOffset = clipZeroStartOffset
                } else if let clipOneText = clipReport?.clipText {
                    namingClipStartOffset = PointAudioSyncMapper.clipStartOffset(of: clipOneText, in: spokenText, from: clipZeroEndOffset)
                } else {
                    namingClipStartOffset = nil
                }

                if let clipReport,
                   let fireTimeSeconds = PointAudioSyncMapper.fireTimeSeconds(
                       spokenPosition: spokenPosition,
                       clipStartOffset: namingClipStartOffset,
                       alignment: clipReport.timing.alignment,
                       strategy: PointAudioSyncTuning.anchorStrategy,
                       leadSeconds: PointAudioSyncTuning.leadSeconds
                   ) {
                    // Poll THIS clip's own playhead until it reaches the fire time (word
                    // start − lead). TRAP 2: the reader is bound to the clip we mapped
                    // against, so we never wait on a different clip's timeline.
                    await self.waitForClipPlayhead(
                        clipReport.timing.playheadSecondsReader,
                        toReachSeconds: fireTimeSeconds
                    )
                } else {
                    // BLOCKER 3 / MINOR: no per-word timing for this clip (Apple fallback /
                    // empty alignment / no report) OR the clip couldn't be located on the
                    // spoken-text ruler. Degrade PROMPTLY to the untimed multi-point walk — a
                    // fixed dwell for this target — instead of hanging or scheduling from a
                    // wrong offset.
                    await self.sleepUntimedPointingDwell()
                }

                if Task.isCancelled { return }
                self.advanceToNextPointingTarget()
                targetIndex += 1
            }
        }
    }

    /// Sleeps one fixed pointing dwell (the Stage 1–3 untimed cadence) so a target whose clip
    /// lacks per-word timing still gets a natural hold before advancing — the graceful
    /// degradation the scheduler applies per-clip when timing is unavailable (BLOCKER 3).
    private func sleepUntimedPointingDwell() async {
        let dwellNanoseconds = UInt64(Self.untimedPointingDwellSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: dwellNanoseconds)
    }

    /// Waits (bounded) for the clip with `ordinal` to be reported, returning it or nil if it
    /// never arrives within `maxWaitPolls`. Polls the reports the speaker fills in as each
    /// clip's audio starts.
    private func awaitClipReport(ordinal: Int, maxWaitPolls: Int) async -> SpokenClipReport? {
        let pollIntervalNanoseconds: UInt64 = 30_000_000 // 30ms
        var pollsRemaining = maxWaitPolls
        while pollsRemaining > 0 {
            if Task.isCancelled { return nil }
            if let report = audioSyncClipReports[ordinal] { return report }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            pollsRemaining -= 1
        }
        return audioSyncClipReports[ordinal]
    }

    /// Polls `playheadReader` until this clip's playhead reaches `fireTimeSeconds`, then
    /// returns so the caller advances the cursor. Returns early when the reader yields nil
    /// (the clip finished or was superseded — the word already passed, so advance now) or
    /// on a safety ceiling, so a point can never wedge the sequence.
    private func waitForClipPlayhead(
        _ playheadReader: (@MainActor () -> TimeInterval?)?,
        toReachSeconds fireTimeSeconds: Double
    ) async {
        guard let playheadReader else { return }
        let pollIntervalNanoseconds: UInt64 = 25_000_000 // 25ms — fine-grained for tight sync
        let maximumPolls = 800 // ~20s ceiling
        var pollsRemaining = maximumPolls
        while pollsRemaining > 0 {
            if Task.isCancelled { return }
            guard let currentPlayheadSeconds = playheadReader() else { return }
            if currentPlayheadSeconds >= fireTimeSeconds { return }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            pollsRemaining -= 1
        }
    }

    /// Resolves which research session (if any) a spoken follow-up should continue,
    /// preferring the ACTUAL frontmost on-screen results window's bound session over
    /// the ephemeral click-focus state. This is the robust lineage signal the follow-up
    /// fix keys on: while the user is viewing a generated page — opened from a live pill
    /// OR from the History window — that page's session is unambiguous no matter what
    /// took transient key focus, and it's reachable even after the run's pill auto-hid.
    /// Falls back to `focusedSessionID` (unchanged behavior) when no results window is
    /// frontmost, and returns nil when neither applies.
    private func resolveFollowUpTargetSessionID() -> ResearchSessionID? {
        if let frontmostResultsSessionID = ResearchResultsWindowRegistry.shared.frontmostSessionID() {
            return frontmostResultsSessionID
        }
        return researchSessionManager.focusedSessionID
    }

    // MARK: - Test hooks

    /// The research session manager, so a test can set up focus / bindings and exercise
    /// the production follow-up-target precedence.
    var researchSessionManagerForTesting: ResearchSessionManager { researchSessionManager }
    /// Exercises the PRODUCTION `resolveFollowUpTargetSessionID()` (real registry + real
    /// `focusedSessionID`), so a test can assert the frontmost results window's session
    /// overrides an unrelated focused session.
    func resolveFollowUpTargetSessionIDForTesting() -> ResearchSessionID? {
        resolveFollowUpTargetSessionID()
    }

    /// The most recently recorded assistant line in conversation history (test-only), so a test
    /// can assert the refused `[FOLLOWUP]` path records an HONEST line rather than a false
    /// "continued" success.
    var lastConversationAssistantLineForTesting: String? {
        conversationHistory.last?.assistantResponse
    }

    /// Pins the active TTS engine WITHOUT persisting to UserDefaults (test-only), so a test can
    /// force the refused-fallback speak path onto the injected fake Apple client regardless of
    /// the machine's saved TTS preference (which might select ElevenLabs → a real network call).
    func setSelectedTTSEngineForTesting(_ kind: TTSEngineKind) {
        selectedTTSEngineKind = kind
    }

    /// Handles a warm `[FOLLOWUP]` route once the target session reported (honestly) whether it
    /// accepted: records the resolved conversation line (a quiet "continued" on success, an
    /// HONEST "couldn't continue" on refusal — never a false success), and on refusal SPEAKS a
    /// short fallback so the spoken prompt never vanishes. CRUCIALLY it then settles
    /// `voiceState` back to `.idle` — on the refused path AFTER the fallback speech finishes
    /// (including when TTS is suppressed/unavailable, where the speaker chain drains
    /// immediately), so the panel never wedges on "Responding"/Stop. The SUCCESS path stays
    /// silent and settles to idle exactly as before.
    func handleFocusedFollowUpResult(routed: Bool, transcript: String) async {
        let resolution = FocusedFollowUpResolution.resolve(routed: routed)
        conversationHistory.append((
            userTranscript: transcript,
            assistantResponse: resolution.conversationLine
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        if let spokenFallback = resolution.spokenFallback {
            await speakRefusedFollowUpFallbackAndSettle(spokenFallback)
        } else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Speaks the honest refused-follow-up fallback and settles the panel back to `.idle` ONLY
    /// after the utterance has actually finished — so the async `onPlaybackStarted` (`.
    /// responding`) can never be left uncleared. When TTS is suppressed/unavailable the speaker
    /// chain drains immediately, so this still settles (never wedges). If a newer turn replaced
    /// the speaker meanwhile (`stopAllTTS`), we leave that fresher state alone.
    private func speakRefusedFollowUpFallbackAndSettle(_ message: String) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }
        stopAllTTS()
        let responseSpeaker = StreamingResponseSpeaker(
            provider: TTSProviderSelection.resolveProviderKind(
                selectedEngine: selectedTTSEngineKind,
                hasUsableElevenLabsKey: hasElevenLabsAPIKey
            ),
            appleTTSClient: localTTSClient,
            elevenLabsTTSClient: elevenLabsTTSClient,
            elevenLabsAPIKeyProvider: loadElevenLabsAPIKeyFromKeychain,
            elevenLabsVoiceID: elevenLabsVoiceID,
            onPlaybackStarted: { [weak self] in
                self?.voiceState = .responding
            }
        )
        currentResponseSpeaker = responseSpeaker
        responseSpeaker.finish(finalRemainder: trimmedMessage, fullSpokenText: trimmedMessage)
        // Wait for the fallback speech to actually finish (or drain immediately when there's
        // nothing to play) BEFORE settling, so `.responding` is never left stuck.
        await responseSpeaker.awaitAllPlaybackFinished()
        // Only settle if this is still the current speaker — a newer turn may have taken over.
        if currentResponseSpeaker === responseSpeaker {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Speaks a focused research session's voice FOLLOW-UP reply through the same TTS
    /// provider selection quick answers use (Apple / ElevenLabs, with automatic
    /// fallback). The reply is already concise (a question's answer or a short iterate
    /// confirmation), so it's spoken in one utterance. A new utterance takes over any
    /// prior TTS. Reuses `currentResponseSpeaker` so `stopAllTTS` / the transient-hide
    /// timing track it exactly like a streamed quick answer.
    private func speakResearchFollowUpAnswer(_ reply: String) {
        // Fire-and-forget from the (sync) `onFollowUpSpokenAnswer` closure, but route
        // through the async core so `voiceState` is settled back to `.idle` AFTER the
        // utterance actually finishes — otherwise the `.responding` set in
        // onPlaybackStarted is never cleared and the panel wedges on "Responding"/Stop.
        Task { [weak self] in
            await self?.speakResearchFollowUpAnswerAndSettle(reply)
        }
    }

    /// Speaks a focused research follow-up reply as one utterance, then settles
    /// `voiceState` back to `.idle` on ALL completion paths — success, empty/TTS-
    /// suppressed (the speaker chain drains immediately), and cancellation. Mirrors
    /// `speakRefusedFollowUpFallbackAndSettle` so both spoken follow-up paths settle
    /// identically. `async` so tests can await the full settle.
    private func speakResearchFollowUpAnswerAndSettle(_ reply: String) async {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            // Nothing to say (shouldn't happen — the session only sends non-empty
            // text) — just settle the overlay back down.
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }
        stopAllTTS()
        let responseSpeaker = StreamingResponseSpeaker(
            provider: TTSProviderSelection.resolveProviderKind(
                selectedEngine: selectedTTSEngineKind,
                hasUsableElevenLabsKey: hasElevenLabsAPIKey
            ),
            appleTTSClient: localTTSClient,
            elevenLabsTTSClient: elevenLabsTTSClient,
            // On-demand: read the secret ONLY if this resolves to ElevenLabs.
            elevenLabsAPIKeyProvider: loadElevenLabsAPIKeyFromKeychain,
            elevenLabsVoiceID: elevenLabsVoiceID,
            onPlaybackStarted: { [weak self] in
                self?.voiceState = .responding
            }
        )
        currentResponseSpeaker = responseSpeaker
        // The reply is fully known — speak it as one utterance (works for both Apple
        // and ElevenLabs: the remainder path speaks the whole text).
        responseSpeaker.finish(finalRemainder: trimmedReply, fullSpokenText: trimmedReply)
        scheduleTransientHideIfNeeded()
        // Wait for the utterance to actually finish (or drain immediately when TTS is
        // suppressed/unavailable) BEFORE settling, so `.responding` is never left stuck.
        await responseSpeaker.awaitAllPlaybackFinished()
        // Only settle if this is still the current speaker — a newer turn may have
        // taken over (stopAllTTS swaps currentResponseSpeaker), and clobbering its
        // state would regress the fresher turn.
        if currentResponseSpeaker === responseSpeaker {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Test-only: drives the research follow-up spoken-answer path and AWAITS the
    /// settle, so a test can assert `voiceState` returns to `.idle` after playback
    /// (including the TTS-suppressed path). Mirrors the real
    /// `onFollowUpSpokenAnswer` → `speakResearchFollowUpAnswer` flow.
    func speakResearchFollowUpAnswerAndSettleForTesting(_ reply: String) async {
        await speakResearchFollowUpAnswerAndSettle(reply)
    }

    // MARK: - Visual thinking cue

    /// Starts the delayed countdown that shows the visual thinking cue if a turn
    /// runs past `ThinkingCueState.appearanceDelaySeconds` with no audio/answer.
    /// Resets the per-request signal flag and cancels any prior countdown so each
    /// request starts clean. This NEVER cancels or times out the request itself.
    private func startThinkingCueCountdown() {
        thinkingCueTask?.cancel()
        isShowingThinkingCue = false
        hasAnswerOrAudioStartedForCurrentRequest = false

        let appearanceDelaySeconds = ThinkingCueState.appearanceDelaySeconds
        thinkingCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(appearanceDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Mirror the pure rule: only show while the request is still in flight
            // and nothing has been heard/seen yet.
            let shouldShow = ThinkingCueState.shouldShowCue(
                isRequestInFlight: self.currentResponseTask != nil,
                hasAnswerOrAudioStarted: self.hasAnswerOrAudioStartedForCurrentRequest,
                elapsedSeconds: appearanceDelaySeconds
            )
            if shouldShow {
                self.isShowingThinkingCue = true
            }
        }
    }

    /// Marks that audio/answer has begun for the current request and hides the cue
    /// immediately. Idempotent — safe to call from both the first text delta and
    /// the first audio-playback callback.
    private func markAnswerOrAudioStartedHidingThinkingCue() {
        hasAnswerOrAudioStartedForCurrentRequest = true
        if isShowingThinkingCue { isShowingThinkingCue = false }
        thinkingCueTask?.cancel()
        thinkingCueTask = nil
    }

    /// Cancels the countdown and hides the cue. Called when the request ends or is
    /// cancelled so the cue can never linger after a turn finishes.
    private func cancelThinkingCue() {
        thinkingCueTask?.cancel()
        thinkingCueTask = nil
        if isShowingThinkingCue { isShowingThinkingCue = false }
    }

    /// Speaks a friendly error message when the coaching engine fails or no
    /// engine is installed. Uses NSSpeechSynthesizer (local, always available)
    /// so it works even if the selected engine is missing or errored. The failing
    /// turn's `error` (when known) selects a SPECIFIC message for the isolation-mode
    /// empty-output case instead of the generic snag.
    private func speakLocalErrorFallback(for error: Error? = nil) {
        let utterance = Self.localErrorFallbackUtterance(
            for: error,
            hasAnyCoachEngineInstalled: hasAnyCoachEngineInstalled
        )
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Pure mapping from a failed turn's error to the spoken fallback utterance, so the
    /// specific isolation-mode guidance is unit-testable without a live engine. No
    /// engine installed wins first; then the `--safe-mode` empty-output case
    /// (`.isolationModeUnsupported`) gets its own actionable line; everything else is
    /// the generic snag.
    static func localErrorFallbackUtterance(for error: Error?, hasAnyCoachEngineInstalled: Bool) -> String {
        guard hasAnyCoachEngineInstalled else {
            return "i need claude code or codex installed to think. install one of them, then talk to me again."
        }
        if let sessionError = error as? ClaudePersistentSession.SessionError,
           case .isolationModeUnsupported = sessionError {
            return "isolation mode isn't supported by your claude version. turn 'use my claude code setup' back on in the menu bar, then try again."
        }
        return "sorry, i hit a snag talking to your coding assistant. give it another try."
    }

    // MARK: - Warm-reply routing decision

    /// The three destinations the warm router's reply can resolve to after a turn.
    enum WarmReplyRoute: Equatable {
        /// Continue the FOCUSED research session's own claude thread (`[FOLLOWUP]`).
        case followUpFocusedSession
        /// Spawn a brand-new research run (`[RESEARCH]`); carries the task text (nil
        /// when the marker had no description, in which case the transcript is used).
        case newResearch(task: String?)
        /// A normal spoken answer or an on-screen POINT — the everyday voice path.
        case speakOrPoint
    }

    /// What a warm `[FOLLOWUP]` route resolves to ONCE the target research session has been
    /// asked to continue and has reported (via the honest `followUpOnSession` Bool) whether it
    /// actually accepted. Pure so the invariant "a refused follow-up NEVER claims success and
    /// NEVER vanishes silently" is unit-testable: a routed follow-up records the quiet
    /// "continued" line and stays silent; a REFUSED one records an HONEST line and carries a
    /// short spoken fallback so the user's words are still acknowledged out loud.
    struct FocusedFollowUpResolution: Equatable {
        /// The line recorded in `conversationHistory` for this turn. Deliberately DIFFERENT
        /// for the refused case so History never shows a false "continued" success.
        let conversationLine: String
        /// A message to SPEAK when the follow-up was refused (so the spoken prompt isn't lost);
        /// nil when it genuinely continued (that path stays silent, as before).
        let spokenFallback: String?
        /// Whether the follow-up actually continued the session.
        let didContinue: Bool

        static func resolve(routed: Bool) -> FocusedFollowUpResolution {
            if routed {
                return FocusedFollowUpResolution(
                    conversationLine: "(continued the focused research page)",
                    spokenFallback: nil,
                    didContinue: true
                )
            }
            return FocusedFollowUpResolution(
                conversationLine: "(couldn't continue that research page — it's no longer active)",
                spokenFallback: "Sorry — I couldn't continue that research page. It may no longer be active.",
                didContinue: false
            )
        }
    }

    /// The literal marker every POINT tag begins with (`[POINT:x,y:label]`,
    /// `[POINT:...:screenN]`, or `[POINT:none]`). Used to give pointing UNCONDITIONAL
    /// precedence in the routing decision.
    static let pointTagMarker = "[POINT:"

    /// PURE routing decision used by `sendTranscriptToClaudeWithScreenshot`: given the
    /// warm agent's full reply and whether a research session is focused, decide where
    /// this turn goes. Order matters and encodes the sacred rules:
    ///   0. POINT WINS, ALWAYS. If the reply contains a `[POINT:...]` tag ANYWHERE, it's
    ///      the everyday speak/POINT path — even if the (model-disobedient) reply also
    ///      begins with `[FOLLOWUP]`/`[RESEARCH]`, and regardless of focus. Pointing is
    ///      the sacred, unconditional path and must never be swallowed by a directive.
    ///   1. Else a `[FOLLOWUP]` directive routes to the focused session — but ONLY when
    ///      a session is actually focused (the addendum is the only thing that makes the
    ///      agent emit it, and we never honor a stray marker with nothing focused).
    ///   2. Else a `[RESEARCH]` directive spawns a new research run.
    ///   3. Else it's a normal spoken answer.
    static func routeWarmReply(fullResponseText: String, isResearchSessionFocused: Bool) -> WarmReplyRoute {
        // 0. A POINT tag anywhere in the reply takes precedence over any routing
        // directive — pointing must ALWAYS fire the blue cursor.
        if fullResponseText.contains(pointTagMarker) {
            return .speakOrPoint
        }
        if isResearchSessionFocused,
           FollowUpDirective.parse(from: fullResponseText).isFollowUpRequest {
            return .followUpFocusedSession
        }
        let researchDirective = ResearchDirective.parse(from: fullResponseText)
        if researchDirective.isResearchRequest {
            return .newResearch(task: researchDirective.taskDescription)
        }
        return .speakOrPoint
    }

    // MARK: - Point Tag Parsing

    /// A single [POINT:x,y:label:screenN] tag parsed out of the response, in the
    /// order it appeared in the text.
    struct ParsedPoint: Equatable {
        /// The parsed pixel coordinate in the screenshot's coordinate space.
        let coordinate: CGPoint
        /// Short label describing the element (e.g. "run button"), or nil.
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
        /// The character offset of this tag's opening `[` within the ORIGINAL
        /// response text (tags still present).
        ///
        /// IMPORTANT — character offset is preserved for the audio-sync stage: it maps
        /// each point to its word in the ElevenLabs alignment array (so the cursor can
        /// arrive exactly as the element's word is spoken). Do not remove.
        let characterOffset: Int
        /// The position of this tag within the SPOKEN (tag-stripped, trimmed) text — i.e.
        /// where the element's naming word ends and the tag sat. This is the audio-sync
        /// anchor: it maps into the spoken clip's `alignment` array to find the audio time
        /// the element is named. Derived from `characterOffset` by removing the earlier
        /// tags' and the leading trim's character counts (see `parsePointingCoordinates`).
        let spokenPosition: Int
    }

    /// Result of parsing the [POINT:...] tags from Claude's response.
    struct PointingParseResult {
        /// The response text with ALL [POINT:...] tags removed — this is what gets spoken.
        let spokenText: String
        /// The ordered pointing targets parsed from the reply, in the order the model
        /// emitted them (each placed right after the clause naming its element).
        /// Empty for a reply with no tag or an explicit [POINT:none].
        let points: [ParsedPoint]
    }

    /// Maps a [POINT:x,y] coordinate from the screenshot's pixel space (top-left
    /// origin, the dimensions the model was told and answered in) to the global
    /// AppKit screen location (bottom-left origin) the blue cursor overlay flies to
    /// and points at. This is the seam between the parsed POINT tag and the visible
    /// cursor: each `DetectedElementTarget.screenLocation` is set to this value, which
    /// `OverlayWindow`/`BlueCursorView` observes to animate the pointer. Pulled out
    /// as a pure function (identical math was duplicated in the voice-answer and
    /// onboarding-demo point paths) so the POINT→cursor targeting is unit-testable
    /// without a live screen.
    static func mapScreenshotPointToGlobalScreenLocation(
        screenshotPoint: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        displayFrame: CGRect
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)

        // Clamp to screenshot coordinate space
        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    /// Parses ALL [POINT:x,y:label:screenN] / [POINT:none] tags out of Claude's
    /// response, wherever they appear (tags are now emitted INLINE, one right after
    /// the clause naming each element). Returns the spoken text (every tag removed)
    /// plus the ordered list of coordinate points, in the order they appeared.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2].
        // NOTE the end-anchor (`\s*$`) is intentionally GONE: tags may be mid-text,
        // and we use `matches(in:)` (not `firstMatch`) to capture every one in order.
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

        // The spoken text always has every tag stripped, even a bare [POINT:none].
        let spokenText = SentenceStreamBuffer.strippingPointTag(from: responseText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return PointingParseResult(spokenText: spokenText, points: [])
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, range: fullRange)

        // How many leading whitespace characters `spokenText` trimmed off the front of the
        // tag-stripped text. A tag's spoken position must be shifted left by this so it
        // indexes into the same (trimmed) text the TTS clip alignment covers.
        let strippedFullText = SentenceStreamBuffer.strippingPointTag(from: responseText)
        let leadingTrimmedCount = strippedFullText.prefix { $0.isWhitespace || $0.isNewline }.count

        var points: [ParsedPoint] = []
        for match in matches {
            guard let tagRange = Range(match.range, in: responseText) else { continue }
            // Character offset of this tag's opening `[` within the original text.
            let characterOffset = responseText.distance(from: responseText.startIndex, to: tagRange.lowerBound)

            // The tag's position in the SPOKEN (tag-stripped, trimmed) text: strip the
            // earlier tags out of everything BEFORE this tag (the prefix ends right before
            // this tag's `[`, so it contains no partial tag), then remove the leading trim.
            // This is where the element's naming word ends — the audio-sync anchor.
            let originalPrefix = String(responseText[responseText.startIndex..<tagRange.lowerBound])
            let strippedPrefixCount = SentenceStreamBuffer.strippingPointTag(from: originalPrefix).count
            let spokenPosition = max(0, strippedPrefixCount - leadingTrimmedCount)

            // [POINT:none] has no coordinate capture groups — it is stripped from the
            // spoken text but contributes no target to point at.
            guard let xRange = Range(match.range(at: 1), in: responseText),
                  let yRange = Range(match.range(at: 2), in: responseText),
                  let x = Double(responseText[xRange]),
                  let y = Double(responseText[yRange]) else {
                continue
            }

            var elementLabel: String? = nil
            if let labelRange = Range(match.range(at: 3), in: responseText) {
                elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            }

            var screenNumber: Int? = nil
            if let screenRange = Range(match.range(at: 4), in: responseText) {
                screenNumber = Int(responseText[screenRange])
            }

            points.append(ParsedPoint(
                coordinate: CGPoint(x: x, y: y),
                elementLabel: elementLabel,
                screenNumber: screenNumber,
                characterOffset: characterOffset,
                spokenPosition: spokenPosition
            ))
        }

        return PointingParseResult(spokenText: spokenText, points: points)
    }

    // MARK: - Onboarding Prompt

    /// Streams the "press control + option and introduce yourself" cue onto the
    /// cursor after the welcome bubble. Called by BlueCursorView once the welcome
    /// animation finishes (the intro video/music were removed).
    func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

}
