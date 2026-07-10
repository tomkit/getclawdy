//
//  ClaudePersistentSession.swift
//  Clawdy
//
//  A long-lived `claude -p --input-format stream-json` process that is kept warm
//  across push-to-talk turns. The CLI only runs a turn while its stdin stays
//  OPEN (closing stdin makes it exit before answering), so a one-shot-per-request
//  process can't use stream-json input at all — and keeping the SAME process warm
//  removes the ~1.5s cold start from every turn after the first AND lets the CLI
//  remember the conversation server-side (so we stop folding history into every
//  prompt).
//
//  Lifecycle, all serialized on a single state queue so there are no data races:
//   - SPAWN at app launch (prewarm) for the selected engine, or lazily on the
//     first request. In keep-warm mode (the live app config) the process then
//     stays alive for the WHOLE app lifetime — every push-to-talk reuses it.
//   - HEALTH/RESPAWN: if the process dies or its stdout hits EOF unexpectedly, a
//     keep-warm session proactively respawns a fresh one (capped to avoid a hot
//     loop) so the next turn still hits a warm process; an in-flight request at
//     that moment fails cleanly. In legacy mode the next request respawns instead.
//   - IDLE TEARDOWN: legacy-only — after `idleTimeoutSeconds` with no active
//     request the process is terminated to free resources, and the next request
//     respawns it. DISABLED in keep-warm mode (see `shouldArmIdleTeardown`).
//   - EXPLICIT SHUTDOWN: `shutdown()` terminates the process on engine switch and
//     app quit. An intentional terminate bumps the process generation so its EOF
//     is NOT mistaken for an unexpected death (and so never triggers a respawn).
//   - CANCEL: when the user re-presses mid-response we send a `control_request`
//     interrupt (the warm process survives it), resume the caller with
//     CancellationError immediately, and mark the stream "unsynced" until the
//     interrupted turn drains to its terminal `result`. If a new request arrives
//     before that drain completes, we respawn rather than risk interleaved turns.
//   - PER-REQUEST TIMEOUT: a stalled turn fails with `.timedOut` and forces a
//     respawn so usability is restored without hanging.
//
//  The spawn/respawn/teardown/cancel DECISIONS live in `ClaudePersistentSessionPolicy`
//  as pure functions so they can be unit-tested without a live process.
//

import Foundation

/// One meaningful event parsed from a single line of the CLI's stream-json
/// output. Pure and `Equatable` so the line→event mapping is unit-testable
/// without a live process. Lines we don't care about (system/hook/init events)
/// map to `.other`.
enum ClaudeStreamEvent: Equatable {
    /// A streamed text delta (one chunk of the model's answer as it's written).
    case textDelta(String)
    /// The terminal event for a turn: the authoritative final text (nil if the
    /// CLI omitted it) and whether the turn ended in an error.
    case result(text: String?, isError: Bool)
    /// The `system`/`init` line emitted once when the process starts — carries the
    /// warm session's own `session_id`. Captured READ-ONLY (for the History index);
    /// it does not affect how a turn is served.
    case sessionInitialized(sessionID: String)
    /// Anything else (system/hook/control/usage events) — ignored by the session.
    case other

    /// Parses one NDJSON line. Returns `.other` for blank/unparseable lines so the
    /// caller can treat "nothing actionable" uniformly.
    static func parse(line: String) -> ClaudeStreamEvent {
        guard let jsonObject = decodeJSONLine(line),
              let eventType = jsonObject["type"] as? String else {
            return .other
        }

        // The first line: { type: "system", subtype: "init", session_id: "..." }
        if eventType == "system",
           (jsonObject["subtype"] as? String) == "init",
           let sessionID = jsonObject["session_id"] as? String {
            return .sessionInitialized(sessionID: sessionID)
        }

        if eventType == "result" {
            let isError = (jsonObject["is_error"] as? Bool) ?? false
            return .result(text: jsonObject["result"] as? String, isError: isError)
        }

        // Streamed text deltas are wrapped: { type: stream_event, event: { type:
        // content_block_delta, delta: { type: text_delta, text: "..." } } }
        if eventType == "stream_event",
           let event = jsonObject["event"] as? [String: Any],
           (event["type"] as? String) == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           (delta["type"] as? String) == "text_delta",
           let textChunk = delta["text"] as? String {
            return .textDelta(textChunk)
        }

        return .other
    }
}

/// Pure, side-effect-free lifecycle decisions for the warm Claude session.
/// Extracted from the live class so the policy is unit-testable headlessly.
enum ClaudePersistentSessionPolicy {
    /// Whether a usable process must be (re)spawned before serving a request.
    /// Respawn when: there is no live process; the previous turn was cancelled and
    /// hasn't finished draining (stream unsynced) so reusing it could interleave
    /// output; or the requested system prompt differs from the one the live
    /// process was launched with (it's a fixed launch flag, so a change needs a
    /// fresh process).
    static func shouldSpawnBeforeRequest(
        hasLiveProcess: Bool,
        isStreamSynced: Bool,
        liveSystemPrompt: String?,
        requestedSystemPrompt: String
    ) -> Bool {
        if !hasLiveProcess { return true }
        if !isStreamSynced { return true }
        if liveSystemPrompt != requestedSystemPrompt { return true }
        return false
    }

    /// Whether a freshly-spawned (cold) process should be primed with the rendered
    /// conversation history. Only a cold process needs it — a warm process already
    /// remembers the session server-side, so re-sending history would waste tokens
    /// and defeat prompt caching.
    static func shouldPrimeWithHistory(isFreshlySpawned: Bool, hasHistory: Bool) -> Bool {
        return isFreshlySpawned && hasHistory
    }

    /// Whether the idle process should be torn down now.
    static func shouldTearDownIdle(idleSeconds: TimeInterval, idleTimeoutSeconds: TimeInterval) -> Bool {
        return idleSeconds >= idleTimeoutSeconds
    }

    /// Whether the idle-teardown timer should be armed at all. When the session is
    /// meant to stay warm for the WHOLE app lifetime, idle teardown is disabled —
    /// the process is never reclaimed while Clawdy is running, only ever terminated
    /// explicitly (engine switch / app quit) or replaced after an unexpected death.
    static func shouldArmIdleTeardown(keepWarmForAppLifetime: Bool) -> Bool {
        return !keepWarmForAppLifetime
    }

    /// Whether a process that exited UNEXPECTEDLY (crash/exit, not our own
    /// terminate) should be proactively respawned so the long-lived session
    /// self-heals into a fresh warm process. True only in keep-warm mode, and only
    /// until `maxConsecutiveRespawns` consecutive respawns have happened with no
    /// successful turn in between — that cap stops a CLI that dies instantly (e.g.
    /// broken auth) from spinning in a hot respawn loop; past the cap we stop and
    /// let the next real request surface the genuine error to the user.
    static func shouldRespawnAfterUnexpectedDeath(
        keepWarmForAppLifetime: Bool,
        consecutiveRespawnsWithoutSuccess: Int,
        maxConsecutiveRespawns: Int
    ) -> Bool {
        guard keepWarmForAppLifetime else { return false }
        return consecutiveRespawnsWithoutSuccess < maxConsecutiveRespawns
    }

    /// Whether a warm turn that ENDED WITH NO TEXT (EOF / empty stdout, no `result`)
    /// is the known `--safe-mode` + `--input-format stream-json` empty-output
    /// incompatibility rather than a generic crash. True only when safe-mode was
    /// actually active for the turn (the "Use my Claude Code setup" toggle is OFF)
    /// AND the turn produced no streamed text at all. Lets the session surface the
    /// specific `.isolationModeUnsupported` guidance instead of the generic snag —
    /// but ONLY on the safe-mode-active branch, so a normal crash still reads as one.
    static func isLikelySafeModeEmptyOutput(safeModeActive: Bool, producedAnyText: Bool) -> Bool {
        return safeModeActive && !producedAnyText
    }

    /// Whether cancelling the in-flight turn should terminate the warm process.
    /// Always false: a cancel interrupts just that turn (via a `control_request`)
    /// and leaves the long-lived session ready for the next request. Killing the
    /// process on every cancel would defeat the warm-session design and force a
    /// cold start on the very next push-to-talk.
    static func shouldTerminateProcessOnTurnCancel() -> Bool {
        return false
    }
}

/// Owns one warm `claude` process and serves one request at a time (push-to-talk
/// is inherently serial — CompanionManager cancels the previous turn before
/// starting the next). `@unchecked Sendable` because all mutable state is touched
/// only on `stateQueue`; the few cross-thread reads are the queues themselves.
final class ClaudePersistentSession: @unchecked Sendable {
    /// Thrown when the warm process dies or its output ends before a turn finished.
    enum SessionError: LocalizedError {
        case processEndedUnexpectedly(standardError: String)
        case launchFailed(underlying: Error)
        case responseTimedOut(seconds: TimeInterval)
        case responseReportedError
        /// The specific case where the warm turn was spawned WITH `--safe-mode`
        /// (isolation mode / "Use my Claude Code setup" is OFF) and came back EMPTY —
        /// the known `--safe-mode` + `--input-format stream-json` empty-output
        /// incompatibility on some `claude` versions (observed 2.1.198; 2.1.199 fixed
        /// it). Surfaced INSTEAD of the generic snag so the user gets actionable
        /// guidance to turn the setting back on.
        case isolationModeUnsupported

        var errorDescription: String? {
            switch self {
            case .processEndedUnexpectedly(let standardError):
                let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "The Claude session ended unexpectedly."
                    : "The Claude session ended unexpectedly: \(trimmed)"
            case .launchFailed(let underlying):
                return "Couldn't launch the Claude session: \(underlying.localizedDescription)"
            case .responseTimedOut(let seconds):
                return "Claude didn't respond within \(Int(seconds)) seconds."
            case .responseReportedError:
                return "Claude reported an error while answering."
            case .isolationModeUnsupported:
                return "Isolation mode isn't supported by your Claude CLI version — turn 'Use my Claude Code setup' back on."
            }
        }
    }

    private let binaryPath: String
    private let homeDirectoryPath: String
    /// Mirrors the app-wide "Use my Claude Code setup" setting (default true). When
    /// false the warm process is spawned WITH `--safe-mode` (isolated). Fixed for
    /// this session's lifetime — CompanionManager rebuilds the engine when the user
    /// toggles it, so a change spawns a fresh process with the new args. Also drives
    /// the empty-output guard: safe-mode is active exactly when this is false.
    private let useClaudeCustomizations: Bool
    private let perResponseTimeoutSeconds: TimeInterval
    private let idleTimeoutSeconds: TimeInterval
    /// Upper bound on how long a CANCELLED turn is allowed to drain to its terminal
    /// `result` before the warm process is treated as WEDGED. On cancel we send a
    /// `control_request` interrupt and keep `activeRequest` set (still draining) with
    /// the stream marked unsynced, awaiting that `result`. If the child dropped the
    /// interrupt (or is wedged-but-alive) and never emits it, without this backstop
    /// `activeRequest`/`isStreamSynced` would stay stuck INDEFINITELY with no timeout
    /// armed and keep-warm mode would never reclaim the process. When this elapses we
    /// terminate (and, in keep-warm mode, respawn) so the session self-heals within a
    /// bounded window instead of waiting for the next push-to-talk.
    private let cancelDrainTimeoutSeconds: TimeInterval
    /// When true, the process is kept warm for the ENTIRE app lifetime: idle
    /// teardown is disabled and an unexpected death triggers a proactive respawn,
    /// so every push-to-talk reuses one long-lived session. The process is only
    /// ever terminated explicitly (engine switch / app quit). When false (the
    /// legacy default), the process is reclaimed after `idleTimeoutSeconds`.
    private let keepWarmForAppLifetime: Bool
    /// Optional READ-ONLY hook fired with the warm process's own `session_id` when it
    /// appears in the stream's `system`/`init` line. Used to index the root session
    /// in the History manifest. It NEVER changes how the session runs — no argument,
    /// working directory, or turn behavior depends on it. Invoked off the state queue.
    private let onRootSessionCaptured: (@Sendable (String) -> Void)?
    /// Hard cap on consecutive auto-respawns with no successful turn in between, so
    /// a CLI that dies instantly can't hot-loop. Reset to 0 by any successful turn.
    private let maxConsecutiveAutoRespawns = 3

    /// Serializes ALL state-machine mutations and the reader's parsed events.
    private let stateQueue = DispatchQueue(label: "com.clawdy.claude-session.state")
    /// Serializes stdin writes off the state queue so a large image write can't
    /// block the state machine (cancel/timeout) while the child drains stdin.
    private let writerQueue = DispatchQueue(label: "com.clawdy.claude-session.writer")

    // MARK: - State (only touched on stateQueue)

    private var process: Process?
    private var standardInputHandle: FileHandle?
    /// Bumped on every spawn so a stale reader thread (from a killed process) can
    /// be ignored when it reports EOF.
    private var processGeneration = 0
    private var hasLiveProcess = false
    private var liveSystemPrompt: String?
    /// Total number of times a child process has been spawned over this session's
    /// lifetime (first spawn / prewarm + every respawn). Used only by the lifecycle
    /// regression tests to distinguish "reused the same warm process" (count
    /// unchanged) from "respawned" (count incremented).
    private var spawnCount = 0
    /// True when the stdout stream is in a known-good state for a new turn. Set
    /// false from a cancel until the interrupted turn drains to its `result`.
    private var isStreamSynced = true
    /// True for exactly the first request served by a freshly-spawned process.
    private var isFreshlySpawned = false
    private var collectedStandardError = ""

    private var activeRequest: ActiveRequest?
    private var idleTeardownWorkItem: DispatchWorkItem?
    /// The system prompt the live (or most-recently-live) process was launched
    /// with. Retained across teardown so a keep-warm respawn-after-death can relaunch
    /// with the SAME launch flags. (Distinct from `liveSystemPrompt`, which is
    /// cleared on teardown to signal there's no live process.)
    private var lastLaunchedSystemPrompt: String?
    /// How many times the keep-warm session has auto-respawned after an unexpected
    /// death without a successful turn since. Reset to 0 on any successful result.
    private var consecutiveAutoRespawnsWithoutSuccess = 0
    /// The most recent `session_id` captured from the process's `system`/`init`
    /// line. Read-only bookkeeping for the History manifest; never gates a turn.
    private var capturedRootSessionID: String?

    /// One in-flight turn: the continuation to resume once, the accumulated text,
    /// and the streaming callback.
    private final class ActiveRequest {
        let requestID: String
        let continuation: CheckedContinuation<String, Error>
        let onAccumulatedText: @MainActor @Sendable (String) -> Void
        var accumulatedText = ""
        var hasResumed = false
        var wasCancelled = false
        var timeoutWorkItem: DispatchWorkItem?
        /// Armed when this turn is cancelled and left to drain; fires if the terminal
        /// `result` never arrives within `cancelDrainTimeoutSeconds`, treating the
        /// warm process as wedged. Cancelled the moment the `result` drains normally.
        var drainTimeoutWorkItem: DispatchWorkItem?

        init(
            requestID: String,
            continuation: CheckedContinuation<String, Error>,
            onAccumulatedText: @escaping @MainActor @Sendable (String) -> Void
        ) {
            self.requestID = requestID
            self.continuation = continuation
            self.onAccumulatedText = onAccumulatedText
        }
    }

    init(
        binaryPath: String,
        homeDirectoryPath: String = NSHomeDirectory(),
        useClaudeCustomizations: Bool = true,
        perResponseTimeoutSeconds: TimeInterval = 60,
        idleTimeoutSeconds: TimeInterval = 120,
        cancelDrainTimeoutSeconds: TimeInterval = 6,
        keepWarmForAppLifetime: Bool = false,
        onRootSessionCaptured: (@Sendable (String) -> Void)? = nil
    ) {
        self.binaryPath = binaryPath
        self.homeDirectoryPath = homeDirectoryPath
        self.useClaudeCustomizations = useClaudeCustomizations
        self.perResponseTimeoutSeconds = perResponseTimeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.cancelDrainTimeoutSeconds = cancelDrainTimeoutSeconds
        self.keepWarmForAppLifetime = keepWarmForAppLifetime
        self.onRootSessionCaptured = onRootSessionCaptured
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Public API

    /// Sends one turn to the warm process and returns Claude's authoritative final
    /// text. Streams accumulated text to `onAccumulatedText` as deltas arrive.
    /// `historyPrimerText` is folded in only when this request lands on a cold
    /// (freshly-spawned) process — a warm process already remembers the session.
    /// Throws `CancellationError` if the awaiting Task is cancelled (user
    /// re-pressed), or `SessionError` on process death / timeout / engine error.
    func sendRequest(
        systemPrompt: String,
        userText: String,
        historyPrimerText: String?,
        images: [ClaudeStreamJSONMessage.InlineImage],
        onAccumulatedText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let requestID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                stateQueue.async {
                    self.startRequestOnStateQueue(
                        requestID: requestID,
                        systemPrompt: systemPrompt,
                        userText: userText,
                        historyPrimerText: historyPrimerText,
                        images: images,
                        onAccumulatedText: onAccumulatedText,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            stateQueue.async {
                self.cancelRequestOnStateQueue(requestID: requestID)
            }
        }
    }

    /// Spawns the warm process AHEAD of the first real turn so the user's first
    /// push-to-talk of the session doesn't pay the ~1.5s cold start. A no-op unless
    /// the session is fully cold (no live process and no in-flight/draining turn),
    /// so it can never disturb an active turn, a cancellation drain, or an
    /// already-warm process — and it's safe to call repeatedly. In keep-warm mode
    /// the spawned process stays alive for the app's lifetime (no idle teardown is
    /// armed); it's only ever reclaimed by an explicit `shutdown()`. It launches
    /// with the SAME system prompt real turns use, so the first request reuses this
    /// process instead of respawning it (the system prompt is a fixed launch flag).
    func prewarm(systemPrompt: String) {
        stateQueue.async {
            guard self.activeRequest == nil, !self.hasLiveProcess else { return }
            do {
                try self.spawnProcessOnStateQueue(systemPrompt: systemPrompt)
                // Arm idle teardown only in legacy (non-keep-warm) mode; in keep-warm
                // mode `armIdleTeardown` is a no-op so the prewarmed process persists.
                self.armIdleTeardown()
                print("🔥 ClaudePersistentSession: pre-warmed at launch")
            } catch {
                // A failed prewarm is harmless — the next real request will spawn
                // and surface any genuine launch error to the user then.
                print("⚠️ ClaudePersistentSession: prewarm spawn failed: \(error)")
            }
        }
    }

    /// Terminates the warm process if running. Safe to call repeatedly.
    func shutdown() {
        stateQueue.async {
            self.cancelIdleTeardown()
            // Disarm any cancelled-but-draining turn's backstop FIRST: otherwise the
            // drain timer could still fire after this intentional teardown and respawn
            // a fresh warm process — restarting a session we just shut down. (The
            // generation guard in handleCancelDrainTimeout is a second line of defense.)
            self.clearCancelledDrainingRequest()
            self.terminateProcessOnStateQueue()
        }
    }

    /// If the current active request is a CANCELLED turn left to drain, cancel + nil
    /// its drain backstop and drop it. Used on intentional teardown (`shutdown()`) so
    /// the backstop can never fire post-shutdown, and when a fresh request supersedes a
    /// still-draining cancelled turn so its timer can't leak or fire under the new turn.
    /// A no-op unless the active request is exactly a cancelled-draining one.
    private func clearCancelledDrainingRequest() {
        guard let request = activeRequest, request.wasCancelled else { return }
        request.drainTimeoutWorkItem?.cancel()
        request.drainTimeoutWorkItem = nil
        activeRequest = nil
    }

    // MARK: - Test-only inspection (read on stateQueue so it can't race state)

    /// Number of child spawns over this session's lifetime. Tests use it to tell a
    /// warm-process REUSE (unchanged) from a RESPAWN (incremented).
    var spawnCountForTesting: Int { stateQueue.sync { spawnCount } }

    /// Whether a child process is currently live. Tests use it to confirm the
    /// session self-healed after an unexpected death, or was torn down on shutdown.
    var hasLiveProcessForTesting: Bool { stateQueue.sync { hasLiveProcess } }

    /// Whether the stdout stream is synced (ready to serve a new turn). Tests use it
    /// to confirm an interrupted (cancelled) turn drained so the same warm process
    /// is reusable rather than respawned.
    var isStreamSyncedForTesting: Bool { stateQueue.sync { isStreamSynced } }

    /// The last `session_id` captured from the process's `system`/`init` line. Tests
    /// use it to confirm the warm session's own id is captured read-only.
    var capturedRootSessionIDForTesting: String? { stateQueue.sync { capturedRootSessionID } }

    // MARK: - Request start (stateQueue)

    private func startRequestOnStateQueue(
        requestID: String,
        systemPrompt: String,
        userText: String,
        historyPrimerText: String?,
        images: [ClaudeStreamJSONMessage.InlineImage],
        onAccumulatedText: @escaping @MainActor @Sendable (String) -> Void,
        continuation: CheckedContinuation<String, Error>
    ) {
        cancelIdleTeardown()

        // Defensive serialization: if a turn is somehow still in flight when a new
        // one starts (e.g. the onboarding-demo path overlapping a voice turn —
        // they share this session but don't cancel each other), the latest request
        // wins. Supersede the old one cleanly and force a fresh process so the old
        // turn's lingering output can't interleave with the new one's.
        if let supersededRequest = activeRequest, !supersededRequest.hasResumed {
            supersededRequest.hasResumed = true
            supersededRequest.timeoutWorkItem?.cancel()
            supersededRequest.timeoutWorkItem = nil
            supersededRequest.continuation.resume(throwing: CancellationError())
            activeRequest = nil
            isStreamSynced = false
        }

        // A PRIOR cancelled turn may still be draining (already resumed, so the branch
        // above doesn't catch it) with its backstop armed. Supersede it cleanly: cancel
        // + nil its drain timer and drop it so the timer can't leak or fire under this
        // new turn. (The spawn below starts a fresh process for this request anyway.)
        clearCancelledDrainingRequest()

        let mustSpawn = ClaudePersistentSessionPolicy.shouldSpawnBeforeRequest(
            hasLiveProcess: hasLiveProcess,
            isStreamSynced: isStreamSynced,
            liveSystemPrompt: liveSystemPrompt,
            requestedSystemPrompt: systemPrompt
        )
        if mustSpawn {
            do {
                try spawnProcessOnStateQueue(systemPrompt: systemPrompt)
            } catch {
                continuation.resume(throwing: SessionError.launchFailed(underlying: error))
                return
            }
        }

        // Fold conversation history in only when this is a cold turn.
        let shouldPrime = ClaudePersistentSessionPolicy.shouldPrimeWithHistory(
            isFreshlySpawned: isFreshlySpawned,
            hasHistory: !(historyPrimerText ?? "").isEmpty
        )
        isFreshlySpawned = false

        let composedText: String
        if shouldPrime, let historyPrimerText {
            composedText = historyPrimerText + "\n\n" + userText
        } else {
            composedText = userText
        }

        let request = ActiveRequest(
            requestID: requestID,
            continuation: continuation,
            onAccumulatedText: onAccumulatedText
        )
        activeRequest = request

        let messageLine = ClaudeStreamJSONMessage.makeUserMessageLine(text: composedText, images: images)
        writeToStandardInput(messageLine)

        armPerResponseTimeout(for: request)
    }

    // MARK: - Cancellation (stateQueue)

    private func cancelRequestOnStateQueue(requestID: String) {
        guard let request = activeRequest, request.requestID == requestID, !request.hasResumed else {
            return
        }
        request.wasCancelled = true
        request.hasResumed = true
        request.timeoutWorkItem?.cancel()
        request.timeoutWorkItem = nil
        request.continuation.resume(throwing: CancellationError())

        // Interrupt the in-flight turn but keep the warm process. The stream is
        // "unsynced" until the interrupted turn's terminal `result` drains in
        // handleParsedLine; until then a new request will respawn instead of risk
        // interleaving. activeRequest stays set (still draining) so its result is
        // recognized and not mistaken for a new turn's.
        isStreamSynced = false
        let interruptLine = ClaudeStreamJSONMessage.makeInterruptControlLine(requestID: requestID)
        writeToStandardInput(interruptLine)

        // Backstop the drain: if the interrupted turn never reaches its terminal
        // `result` within the bound (dropped interrupt / wedged-but-alive child),
        // reclaim the wedged process instead of leaving the session stuck unsynced
        // forever. The happy drain (result arrives) cancels this in handleResultEvent.
        armCancelDrainTimeout(for: request)

        armIdleTeardown()
    }

    // MARK: - Cancel-drain timeout (stateQueue)

    /// Arms the bounded drain-timeout for a turn that was just cancelled and left to
    /// drain. Stored on the request so it's cancelled the instant the terminal
    /// `result` arrives (the healthy drain), and so a superseding turn's guard can
    /// tell it's stale.
    private func armCancelDrainTimeout(for request: ActiveRequest) {
        // Capture the requestID and current process generation BY VALUE — never the
        // whole `request`. `request` retains this work item, so capturing `request`
        // here would form a retain cycle; capturing value types keeps the work item
        // → self (weak) only. The generation lets the timer no-op if the drained
        // process is torn down or replaced before it fires.
        let requestIDForDrain = request.requestID
        let generationForDrain = processGeneration
        let drainTimeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleCancelDrainTimeout(requestID: requestIDForDrain, generation: generationForDrain)
        }
        request.drainTimeoutWorkItem = drainTimeoutWorkItem
        stateQueue.asyncAfter(deadline: .now() + cancelDrainTimeoutSeconds, execute: drainTimeoutWorkItem)
    }

    /// The cancelled turn didn't drain to its `result` in time — treat the warm
    /// process as WEDGED. Terminate it (which bumps `processGeneration` so the
    /// forced-kill EOF isn't mis-read as a crash by `handleProcessEndedOnStateQueue`)
    /// and, in keep-warm mode, proactively respawn a fresh long-lived process —
    /// reusing the SAME terminate/respawn machinery and backoff cap the
    /// unexpected-death path uses. In legacy mode we just terminate and let the next
    /// request spawn. Either way the stream is marked synced so the session is usable.
    private func handleCancelDrainTimeout(requestID: String, generation: Int) {
        // Belt-and-suspenders: if the process we were draining has since been torn
        // down or replaced (intentional shutdown, a superseding request, an earlier
        // respawn), the generation has advanced — do nothing, so the backstop can
        // never respawn a deliberately dead session.
        guard generation == processGeneration else { return }
        // Still the same draining, cancelled turn? If the `result` already arrived (or
        // a newer turn took over), activeRequest was cleared / replaced and this no-ops.
        guard let request = activeRequest,
              request.requestID == requestID,
              request.wasCancelled else {
            return
        }
        activeRequest = nil
        request.drainTimeoutWorkItem = nil

        // Kill the wedged child (bumps the generation so its EOF is ignored below).
        terminateProcessOnStateQueue()
        isStreamSynced = true

        // Keep-warm self-heal: respawn a fresh warm process (honoring the same
        // consecutive-respawn backoff cap) so the next push-to-talk still hits a warm
        // one, exactly like the unexpected-death path.
        let shouldRespawn = ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: keepWarmForAppLifetime,
            consecutiveRespawnsWithoutSuccess: consecutiveAutoRespawnsWithoutSuccess,
            maxConsecutiveRespawns: maxConsecutiveAutoRespawns
        )
        guard shouldRespawn, let promptToRespawnWith = lastLaunchedSystemPrompt else { return }
        consecutiveAutoRespawnsWithoutSuccess += 1
        do {
            try spawnProcessOnStateQueue(systemPrompt: promptToRespawnWith)
            print("🔁 ClaudePersistentSession: respawned after cancel-drain timeout (attempt \(consecutiveAutoRespawnsWithoutSuccess))")
        } catch {
            print("⚠️ ClaudePersistentSession: respawn after cancel-drain timeout failed: \(error)")
        }
    }

    // MARK: - Spawning / teardown (stateQueue)

    private func spawnProcessOnStateQueue(systemPrompt: String) throws {
        terminateProcessOnStateQueue()

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: binaryPath)
        newProcess.arguments = ClaudeCodeEngine.makeArguments(
            systemPrompt: systemPrompt,
            useClaudeCustomizations: useClaudeCustomizations
        )
        // No tool/file access is granted (we pass `--tools ""`), so the working
        // directory is irrelevant; HOME (set in the environment) is what matters
        // for finding the user's stored subscription auth.
        newProcess.currentDirectoryURL = URL(fileURLWithPath: homeDirectoryPath)
        newProcess.environment = CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath)

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        newProcess.standardInput = standardInputPipe
        newProcess.standardOutput = standardOutputPipe
        newProcess.standardError = standardErrorPipe

        try newProcess.run()

        processGeneration += 1
        spawnCount += 1
        let generationForThisProcess = processGeneration
        process = newProcess
        standardInputHandle = standardInputPipe.fileHandleForWriting
        hasLiveProcess = true
        liveSystemPrompt = systemPrompt
        // Retained beyond teardown so a keep-warm respawn-after-death can relaunch
        // with the identical launch flags.
        lastLaunchedSystemPrompt = systemPrompt
        isStreamSynced = true
        isFreshlySpawned = true
        collectedStandardError = ""

        startReaderThread(
            readingFrom: standardOutputPipe.fileHandleForReading,
            generation: generationForThisProcess,
            isStandardError: false
        )
        startReaderThread(
            readingFrom: standardErrorPipe.fileHandleForReading,
            generation: generationForThisProcess,
            isStandardError: true
        )
    }

    private func terminateProcessOnStateQueue() {
        if let process, process.isRunning {
            process.terminate()
        }
        try? standardInputHandle?.close()
        process = nil
        standardInputHandle = nil
        hasLiveProcess = false
        liveSystemPrompt = nil
        // Bump the generation so THIS process's reader EOF is recognized as an
        // INTENTIONAL teardown (stale generation → ignored by
        // handleProcessEndedOnStateQueue) rather than an unexpected death. That's
        // how keep-warm distinguishes "we killed it" (engine switch / app quit /
        // timeout / respawn-before-request) from "it crashed" (which respawns).
        processGeneration += 1
    }

    // MARK: - Reader threads

    /// Drains a pipe line-by-line on a dedicated blocking thread (the same proven
    /// pattern as CLIProcessRunner) and forwards each complete line onto the state
    /// queue, preserving order. EOF (process closed its outputs) is reported once.
    private func startReaderThread(
        readingFrom fileHandle: FileHandle,
        generation: Int,
        isStandardError: Bool
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Reuse the shared, boundary-safe `LineAccumulator` (the same one
            // CLIProcessRunner drains its pipes with): it decodes raw bytes as
            // UTF-8 ACROSS read boundaries — a multibyte codepoint
            // (emoji/CJK/'…'/'—') can straddle two `availableData` reads, and
            // decoding each chunk independently would drop the whole chunk — and
            // emits each complete newline-terminated line. Each line is forwarded
            // onto the state queue, preserving order. `accumulatesFullText: false`
            // because this app-lifetime reader only consumes complete lines and
            // never reads `fullText`; retaining every stdout byte would grow
            // unbounded for the whole app lifetime.
            let lineAccumulator = LineAccumulator(accumulatesFullText: false) { line in
                self?.stateQueue.async {
                    if isStandardError {
                        self?.collectStandardErrorLine(line, generation: generation)
                    } else {
                        self?.handleParsedLine(line, generation: generation)
                    }
                }
            }
            while true {
                let data = fileHandle.availableData
                if data.isEmpty { break } // EOF
                lineAccumulator.append(data)
            }
            // Emit any trailing text that wasn't newline-terminated (including a
            // codepoint completed by the final read) before reporting EOF; for
            // stdout, EOF then flows into the process-ended handler. Both the
            // remainder and the ended notice enqueue onto the serial state queue
            // in that order, so ordering matches the previous inline reader.
            lineAccumulator.flushRemainder()
            if !isStandardError {
                self?.stateQueue.async {
                    self?.handleProcessEndedOnStateQueue(generation: generation)
                }
            }
        }
    }

    private func collectStandardErrorLine(_ line: String, generation: Int) {
        guard generation == processGeneration else { return }
        if !line.isEmpty { collectedStandardError += line + "\n" }
    }

    // MARK: - Stdout parsing (stateQueue)

    private func handleParsedLine(_ line: String, generation: Int) {
        guard generation == processGeneration else { return } // stale process

        switch ClaudeStreamEvent.parse(line: line) {
        case .sessionInitialized(let sessionID):
            captureRootSessionID(sessionID)

        case .result(let resultText, let isError):
            handleResultEvent(resultText: resultText, isError: isError)

        case .textDelta(let textChunk):
            guard let request = activeRequest, !request.wasCancelled else { return }
            request.accumulatedText += textChunk
            let snapshot = request.accumulatedText
            let deliver = request.onAccumulatedText
            Task { @MainActor in deliver(snapshot) }

        case .other:
            break
        }
    }

    /// Records the warm session's own `session_id` and forwards it to the read-only
    /// capture hook. Purely bookkeeping for the History manifest — it does not touch
    /// the active request, stream sync, or any launch flag, so the warm session's
    /// behavior is unchanged. The hook runs OFF the state queue so a manifest file
    /// write can't stall the state machine.
    private func captureRootSessionID(_ sessionID: String) {
        capturedRootSessionID = sessionID
        guard let onRootSessionCaptured else { return }
        DispatchQueue.global(qos: .utility).async {
            onRootSessionCaptured(sessionID)
        }
    }

    private func handleResultEvent(resultText: String?, isError: Bool) {
        guard let request = activeRequest else { return }
        activeRequest = nil
        request.timeoutWorkItem?.cancel()
        request.timeoutWorkItem = nil
        // The turn drained (normally or after a cancel) — cancel the drain backstop so
        // it can't later fire and needlessly kill a healthy warm process.
        request.drainTimeoutWorkItem?.cancel()
        request.drainTimeoutWorkItem = nil

        // The interrupted turn finished draining — the warm process is reusable.
        if request.wasCancelled {
            isStreamSynced = true
            armIdleTeardown()
            return
        }

        let finalText = resultText ?? request.accumulatedText

        if !request.hasResumed {
            request.hasResumed = true
            if isError {
                request.continuation.resume(throwing: SessionError.responseReportedError)
            } else {
                request.continuation.resume(returning: finalText)
                // A turn completed cleanly — the CLI is healthy, so clear the
                // auto-respawn backoff counter.
                consecutiveAutoRespawnsWithoutSuccess = 0
            }
        }
        isStreamSynced = true
        armIdleTeardown()
    }

    private func handleProcessEndedOnStateQueue(generation: Int) {
        guard generation == processGeneration else { return } // an old process we already replaced
        hasLiveProcess = false
        liveSystemPrompt = nil

        // Fail any in-flight turn cleanly (a cancelled one was already resumed; its
        // draining process just ended, which is fine). Mark synced either way so the
        // next request — or the respawn below — starts from a clean stream.
        if let request = activeRequest {
            activeRequest = nil
            request.timeoutWorkItem?.cancel()
            request.timeoutWorkItem = nil
            // The draining process ended, so the drain backstop is moot — cancel it.
            request.drainTimeoutWorkItem?.cancel()
            request.drainTimeoutWorkItem = nil
            isStreamSynced = true
            if !request.hasResumed {
                request.hasResumed = true
                // A turn that ended with no text WHILE safe-mode was active is almost
                // certainly the `--safe-mode` + stream-json empty-output bug — surface
                // the specific "turn the setting back on" guidance instead of the
                // generic snag. Any other unexpected end stays the generic error.
                let endedWithoutTextUnderSafeMode = ClaudePersistentSessionPolicy.isLikelySafeModeEmptyOutput(
                    safeModeActive: !useClaudeCustomizations,
                    producedAnyText: !request.accumulatedText.isEmpty
                )
                request.continuation.resume(
                    throwing: endedWithoutTextUnderSafeMode
                        ? SessionError.isolationModeUnsupported
                        : SessionError.processEndedUnexpectedly(standardError: collectedStandardError)
                )
            }
        } else {
            isStreamSynced = true
        }

        // Keep-warm self-heal: an unexpected exit (this is NOT our own terminate —
        // that bumps the generation so its EOF is ignored above) respawns a fresh
        // long-lived process so the next push-to-talk still hits a warm one. The
        // backoff counter prevents a hot loop if the CLI dies instantly.
        let shouldRespawn = ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: keepWarmForAppLifetime,
            consecutiveRespawnsWithoutSuccess: consecutiveAutoRespawnsWithoutSuccess,
            maxConsecutiveRespawns: maxConsecutiveAutoRespawns
        )
        guard shouldRespawn, let promptToRespawnWith = lastLaunchedSystemPrompt else { return }
        consecutiveAutoRespawnsWithoutSuccess += 1
        do {
            try spawnProcessOnStateQueue(systemPrompt: promptToRespawnWith)
            print("🔁 ClaudePersistentSession: respawned after unexpected exit (attempt \(consecutiveAutoRespawnsWithoutSuccess))")
        } catch {
            print("⚠️ ClaudePersistentSession: respawn after death failed: \(error)")
        }
    }

    // MARK: - Timeouts (stateQueue)

    private func armPerResponseTimeout(for request: ActiveRequest) {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handlePerResponseTimeout(requestID: request.requestID)
        }
        request.timeoutWorkItem = timeoutWorkItem
        stateQueue.asyncAfter(deadline: .now() + perResponseTimeoutSeconds, execute: timeoutWorkItem)
    }

    private func handlePerResponseTimeout(requestID: String) {
        guard let request = activeRequest, request.requestID == requestID, !request.hasResumed else {
            return
        }
        request.hasResumed = true
        activeRequest = nil
        request.continuation.resume(throwing: SessionError.responseTimedOut(seconds: perResponseTimeoutSeconds))
        // A turn that never produced a result means the process may be wedged —
        // kill it so the next request spawns a fresh, responsive one.
        terminateProcessOnStateQueue()
    }

    // MARK: - Idle teardown (stateQueue)

    private func armIdleTeardown() {
        // In keep-warm mode the process must survive for the whole app lifetime, so
        // idle teardown is never scheduled — the process is only ever reclaimed by
        // an explicit shutdown() (engine switch / app quit).
        guard ClaudePersistentSessionPolicy.shouldArmIdleTeardown(keepWarmForAppLifetime: keepWarmForAppLifetime) else {
            return
        }
        cancelIdleTeardown()
        let teardownWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only tear down if still idle and alive.
            if self.activeRequest == nil && self.hasLiveProcess {
                self.terminateProcessOnStateQueue()
            }
        }
        idleTeardownWorkItem = teardownWorkItem
        stateQueue.asyncAfter(deadline: .now() + idleTimeoutSeconds, execute: teardownWorkItem)
    }

    private func cancelIdleTeardown() {
        idleTeardownWorkItem?.cancel()
        idleTeardownWorkItem = nil
    }

    // MARK: - Stdin writes (writerQueue)

    private func writeToStandardInput(_ line: String) {
        // Capture the current handle on the state queue so a respawn can't swap it
        // mid-flight; the actual (possibly large) write happens off the state queue.
        let handle = standardInputHandle
        guard let handle, let data = line.data(using: .utf8) else { return }
        writerQueue.async {
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Broken pipe (the CLI already exited) surfaces via the reader's
                // EOF path as a clean error; nothing to do here but not crash.
                print("⚠️ ClaudePersistentSession: stdin write failed: \(error)")
            }
        }
    }
}
