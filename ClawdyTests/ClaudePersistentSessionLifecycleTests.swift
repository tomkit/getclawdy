//
//  ClaudePersistentSessionLifecycleTests.swift
//  ClawdyTests
//
//  REAL-PATH regression tests for the riskiest concurrency/lifecycle races of the
//  app-lifetime warm session — they exercise the actual ClaudePersistentSession /
//  CompanionManager code paths (driving a fake `claude` stream-json binary), not
//  just the pure policy helpers. Covers:
//    1. Engine switch mid-turn cancels the in-flight turn EXACTLY ONCE with
//       CancellationError and never leaks/hangs the continuation (regression for
//       the "shutdown without cancel" blocking bug — fails before the fix, passes
//       after).
//    2. Cancelling one turn interrupts ONLY that turn and leaves the SAME warm
//       process alive and reusable for the next request (no respawn).
//    3. An UNEXPECTED process death self-heals via a respawn, while a DELIBERATE
//       teardown (generation bump) does NOT respawn.
//
//  The fake binary emits stream-json on stdout one line per `/bin/echo` (a
//  separate process that flushes on exit) so the session's reader sees each line
//  promptly despite pipe buffering — the same real Process plumbing production uses.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Fake `claude` stream-json binary

/// Writes an executable shell script that emulates `claude -p --input-format
/// stream-json`: it reads NDJSON user/control lines on stdin and emits stream-json
/// result/delta lines on stdout, branching on markers embedded in the user text so
/// a test can request a hang, a crash, or a normal completion. Returns its path.
private func makeFakeClaudeStreamJSONBinary() throws -> String {
    // Each output line goes through external `/bin/echo` so it flushes immediately
    // to the pipe (a long-lived shell's builtin stdout would stay buffered).
    let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"streaming "}}}"#
    let finalResult = #"{"type":"result","result":"final answer","is_error":false}"#
    let interruptedResult = #"{"type":"result","result":"(interrupted)","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    # Fake claude stream-json process for lifecycle regression tests.
    #
    # FAITHFUL to the real `claude` 2.1.198 regression: passing `--safe-mode`
    # alongside `--input-format stream-json` makes the real CLI exit 0 with EMPTY
    # stdout (it never reads the NDJSON turn and never emits a `result`). The old
    # stub ignored its argv entirely, so it MASKED this — a real-path test spawning
    # through the shipped arg vector "passed" even while the live CLI produced
    # nothing. Model the breakage here: if `--safe-mode` is in argv, read nothing
    # and exit 0, exactly as the real binary does, so the warm path's EOF-with-no-
    # result failure reproduces in tests.
    for arg in "$@"; do
      if [ "$arg" = "--safe-mode" ]; then
        exit 0
      fi
    done
    emit() { /bin/echo "$1"; }
    drop_interrupt=0
    while IFS= read -r line; do
      case "$line" in
        *control_request*)
          if [ "$drop_interrupt" = "1" ]; then
            # Model a WEDGED-BUT-ALIVE child that DROPPED the interrupt: emit no
            # terminal result and keep reading, so the cancelled turn NEVER drains on
            # its own. Only the session's cancel-drain timeout can reclaim it.
            :
          else
            # Interrupt: drain the in-flight turn with a terminal result, stay alive.
            emit '\(interruptedResult)'
          fi
          ;;
        *HANG_AND_DROP_INTERRUPT*)
          # Stream a delta, latch "ignore the next interrupt", and withhold the
          # result — so a subsequent control_request is silently dropped (above).
          drop_interrupt=1
          emit '\(delta)'
          ;;
        *HANG_UNTIL_INTERRUPT*)
          # Stream a delta but WITHHOLD the result so the turn stays in-flight
          # until the test cancels it (which sends control_request, handled above).
          emit '\(delta)'
          ;;
        *DIE_NOW*)
          # Simulate an unexpected crash: exit without ever emitting a result.
          exit 1
          ;;
        *)
          # A normal turn: stream a delta, then the authoritative final result.
          emit '\(delta)'
          emit '\(finalResult)'
          ;;
      esac
    done
    """

    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// Polls `condition` until true or the timeout elapses (then records an issue).
/// Used to await async state transitions that land on the session's state queue.
private func pollUntil(
    timeoutSeconds: Double,
    _ description: String,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition() {
        if Date() >= deadline {
            Issue.record("timed out after \(timeoutSeconds)s waiting for: \(description)")
            return
        }
        try await Task.sleep(nanoseconds: 40_000_000)
    }
}

// MARK: - Session-level real-path tests (cancel-keeps-alive, respawn-vs-teardown)

struct ClaudePersistentSessionLifecycleTests {

    /// REGRESSION (warm quick-answer path): the SHIPPED `claude` argument vector must
    /// actually produce output when spawned as a real Process. Drives the true warm
    /// path — `ClaudeCodeEngine.analyzeImageStreaming` → `ClaudePersistentSession`
    /// spawn using `ClaudeCodeEngine.makeArguments` — against a stub that faithfully
    /// models the real 2.1.198 breakage (`--safe-mode` + stream-json → exit 0, empty
    /// stdout).
    ///
    /// BEFORE the fix the shipped args included `--safe-mode`, so the stub (like the
    /// real CLI) emitted nothing, the warm process hit EOF with no `result`, and the
    /// call threw `processEndedUnexpectedly` — surfacing as the "hit a snag" toast.
    /// This test FAILS then. AFTER dropping `--safe-mode` the same real path returns
    /// the spoken answer, so it PASSES. This is the coverage the old arg-agnostic stub
    /// could never provide.
    @Test func warmQuickAnswerPathProducesOutputWithShippedArguments() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        let engine = ClaudeCodeEngine(binaryPath: binaryPath, homeDirectoryPath: NSTemporaryDirectory())
        defer { engine.shutdown() }

        let (spokenAnswer, _) = try await engine.analyzeImageStreaming(
            images: [],
            systemPrompt: "you are clawdy",
            conversationHistory: [],
            userPrompt: "what is the capital of japan",
            onTextChunk: { _ in }
        )

        // A normal spoken answer must come back. Before the fix this threw
        // (empty stdout → EOF → processEndedUnexpectedly) and the app spoke the
        // error fallback instead of answering.
        #expect(spokenAnswer == "final answer")
    }

    /// #2 — Cancelling one in-flight turn interrupts ONLY that turn (its
    /// continuation resumes once with CancellationError) and leaves the SAME warm
    /// process alive and reusable for a subsequent request, with no respawn.
    @Test func cancellingOneTurnKeepsTheSharedSessionWarmAndReusable() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        let session = ClaudePersistentSession(
            binaryPath: binaryPath,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )
        defer { session.shutdown() }

        // Turn 1: the fake withholds the result, so the turn stays in-flight.
        let turn1 = Task { () -> Error? in
            do {
                _ = try await session.sendRequest(
                    systemPrompt: "sys",
                    userText: "please answer HANG_UNTIL_INTERRUPT",
                    historyPrimerText: nil,
                    images: [],
                    onAccumulatedText: { _ in }
                )
                return nil
            } catch {
                return error
            }
        }

        // Let the turn reach in-flight, then cancel it (a re-press / engine switch).
        try await Task.sleep(nanoseconds: 500_000_000)
        turn1.cancel()
        let turn1Error = await turn1.value
        #expect(turn1Error is CancellationError)

        // The interrupted turn drains (fake emits a result on the interrupt),
        // leaving the SAME warm process synced and reusable rather than respawned.
        try await Task.sleep(nanoseconds: 250_000_000)
        try await pollUntil(timeoutSeconds: 5, "interrupted turn to drain (stream re-synced)") {
            session.isStreamSyncedForTesting
        }
        let spawnsAfterCancel = session.spawnCountForTesting
        #expect(session.hasLiveProcessForTesting == true)

        // Turn 2: a normal turn must succeed on the SAME warm process — proven by
        // the spawn count NOT increasing (reuse, not respawn).
        let turn2Text = try await session.sendRequest(
            systemPrompt: "sys",
            userText: "what is on screen",
            historyPrimerText: nil,
            images: [],
            onAccumulatedText: { _ in }
        )
        #expect(turn2Text == "final answer")
        #expect(session.spawnCountForTesting == spawnsAfterCancel)
    }

    /// P3 — A cancelled turn whose interrupt is DROPPED (the child stays alive but
    /// never emits the terminal `result`) must not wedge the warm session forever.
    /// The bounded cancel-drain timeout reclaims the wedged process — terminating and
    /// (in keep-warm mode) respawning it — so the session self-heals within the bound
    /// and the next turn succeeds on a fresh warm process, rather than staying stuck
    /// unsynced with `activeRequest` set and no timeout armed.
    @Test func cancelledTurnThatNeverDrainsRecoversViaDrainTimeout() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        // A short drain timeout so the test doesn't wait the production 6s.
        let session = ClaudePersistentSession(
            binaryPath: binaryPath,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 30,
            cancelDrainTimeoutSeconds: 1.5,
            keepWarmForAppLifetime: true
        )
        defer { session.shutdown() }

        // Turn 1: the fake latches "drop the next interrupt" and withholds the result,
        // so once cancelled the turn can NEVER drain on its own.
        let turn1 = Task { () -> Error? in
            do {
                _ = try await session.sendRequest(
                    systemPrompt: "sys",
                    userText: "please answer HANG_AND_DROP_INTERRUPT",
                    historyPrimerText: nil,
                    images: [],
                    onAccumulatedText: { _ in }
                )
                return nil
            } catch {
                return error
            }
        }

        // Let the turn reach in-flight, then cancel it. The caller resumes immediately
        // with CancellationError even though the child will swallow the interrupt.
        try await Task.sleep(nanoseconds: 500_000_000)
        let spawnsBeforeTimeout = session.spawnCountForTesting
        turn1.cancel()
        let turn1Error = await turn1.value
        #expect(turn1Error is CancellationError)

        // The interrupt is dropped, so the stream stays UNSYNCED — it will not drain
        // by itself. Only the drain-timeout backstop can reclaim it.
        #expect(session.isStreamSyncedForTesting == false)

        // Within the drain-timeout window the session must self-heal: terminate the
        // wedged child and respawn a fresh warm process (spawn count increments), and
        // the stream re-syncs so the next turn is servable.
        try await pollUntil(timeoutSeconds: 5, "session to self-heal after cancel-drain timeout") {
            session.spawnCountForTesting > spawnsBeforeTimeout
                && session.hasLiveProcessForTesting
                && session.isStreamSyncedForTesting
        }
        #expect(session.spawnCountForTesting > spawnsBeforeTimeout)
        #expect(session.hasLiveProcessForTesting == true)
        #expect(session.isStreamSyncedForTesting == true)

        // A normal turn now succeeds on the recovered warm process.
        let recoveredText = try await session.sendRequest(
            systemPrompt: "sys",
            userText: "what is on screen",
            historyPrimerText: nil,
            images: [],
            onAccumulatedText: { _ in }
        )
        #expect(recoveredText == "final answer")
    }

    /// P3 / BLOCKING (shutdown race) — an intentional `shutdown()` WHILE a cancelled
    /// turn's drain backstop is armed must NOT let that backstop later fire and respawn
    /// a fresh warm process. Before the fix, `shutdown()` bumped the generation (so the
    /// killed child's EOF was ignored) but left the drain timer armed, so it fired and
    /// restarted the deliberately-dead session. After the fix `shutdown()` disarms the
    /// backstop (and a generation guard is a second line of defense), so the process
    /// stays down.
    @Test func shutdownDuringCancelDrainDoesNotRespawn() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        // A short drain window so the test doesn't wait the production 6s.
        let session = ClaudePersistentSession(
            binaryPath: binaryPath,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 30,
            cancelDrainTimeoutSeconds: 1.0,
            keepWarmForAppLifetime: true
        )

        // Turn 1: latch drop-the-interrupt so the cancelled turn never drains on its
        // own — this ARMS the drain backstop.
        let turn1 = Task { () -> Error? in
            do {
                _ = try await session.sendRequest(
                    systemPrompt: "sys",
                    userText: "please answer HANG_AND_DROP_INTERRUPT",
                    historyPrimerText: nil,
                    images: [],
                    onAccumulatedText: { _ in }
                )
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        turn1.cancel()
        _ = await turn1.value

        // Intentional teardown WHILE the backstop is armed.
        let spawnsBeforeShutdown = session.spawnCountForTesting
        session.shutdown()
        try await pollUntil(timeoutSeconds: 3, "process to be torn down by shutdown()") {
            session.hasLiveProcessForTesting == false
        }

        // Wait well past the 1s drain window: the backstop must NOT fire and respawn a
        // fresh warm process after an intentional shutdown — the session stays down.
        try await Task.sleep(nanoseconds: 1_800_000_000)
        #expect(session.hasLiveProcessForTesting == false, "an intentional shutdown must stay down")
        #expect(session.spawnCountForTesting == spawnsBeforeShutdown, "the drain backstop must not respawn after shutdown")
    }

    /// #3 — An UNEXPECTED process death (the fake exits mid-turn) self-heals via a
    /// proactive respawn, and the respawned process serves the next turn; then a
    /// DELIBERATE shutdown() (which bumps the generation so the stale EOF is
    /// ignored) terminates the process WITHOUT triggering any respawn.
    @Test func unexpectedDeathRespawnsButIntentionalShutdownDoesNot() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        let session = ClaudePersistentSession(
            binaryPath: binaryPath,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )

        // A turn whose fake process crashes mid-turn (exit 1, no result). The
        // request fails cleanly; because this is keep-warm, the session must
        // self-heal by spawning a fresh process (matching-generation EOF → respawn).
        var crashTurnError: Error?
        do {
            _ = try await session.sendRequest(
                systemPrompt: "sys",
                userText: "trigger DIE_NOW",
                historyPrimerText: nil,
                images: [],
                onAccumulatedText: { _ in }
            )
        } catch {
            crashTurnError = error
        }
        #expect(crashTurnError != nil)

        try await pollUntil(timeoutSeconds: 5, "session to self-heal (respawn) after unexpected death") {
            session.spawnCountForTesting >= 2 && session.hasLiveProcessForTesting
        }
        #expect(session.spawnCountForTesting >= 2)
        #expect(session.hasLiveProcessForTesting == true)

        // The respawned process serves the next turn normally.
        let recoveredText = try await session.sendRequest(
            systemPrompt: "sys",
            userText: "normal turn now",
            historyPrimerText: nil,
            images: [],
            onAccumulatedText: { _ in }
        )
        #expect(recoveredText == "final answer")

        // An INTENTIONAL teardown must terminate the process and NOT respawn.
        let spawnsBeforeShutdown = session.spawnCountForTesting
        session.shutdown()
        try await pollUntil(timeoutSeconds: 3, "process to be torn down by shutdown()") {
            session.hasLiveProcessForTesting == false
        }
        // Give any (incorrect) respawn a window to happen, then assert none did.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(session.hasLiveProcessForTesting == false)
        #expect(session.spawnCountForTesting == spawnsBeforeShutdown)
    }
}

// MARK: - Engine-switch regression (Blocking #1): cancel-before-shutdown ordering

/// Thread-safe record of how the in-flight turn resolved, written from the turn's
/// background Task and read from the test's main actor.
private final class TurnResolutionRecorder: @unchecked Sendable {
    enum Resolution: Equatable { case completed, cancelled, otherError }
    private let lock = NSLock()
    private var resolutions: [Resolution] = []

    func record(_ resolution: Resolution) {
        lock.lock(); defer { lock.unlock() }
        resolutions.append(resolution)
    }

    func snapshot() -> [Resolution] {
        lock.lock(); defer { lock.unlock() }
        return resolutions
    }
}

@MainActor
struct CompanionManagerEngineSwitchTests {

    /// Awaits `task` but gives up after `timeoutSeconds` so the BEFORE-fix case (a
    /// hung/leaked continuation) fails cleanly instead of hanging the whole suite.
    /// Returns true if the task resolved in time.
    private func taskResolved(_ task: Task<Void, Never>, withinSeconds timeoutSeconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let firstToFinish = await group.next() ?? false
            group.cancelAll()
            return firstToFinish
        }
    }

    /// #1 — Switching the selected engine while a turn is streaming must cancel the
    /// in-flight turn BEFORE shutting the old engine's session down, so the
    /// continuation resumes EXACTLY ONCE with CancellationError and never hangs.
    ///
    /// This drives the real `setSelectedEngine` teardown path (via the test seam,
    /// which runs the exact same `cancelInFlightTurnAndShutDownActiveEngineSession`
    /// the live switch uses) against a real ClaudeCodeEngine + warm session backed
    /// by the fake binary. BEFORE the fix (shutdown without cancel) the killed
    /// process never resumes the continuation, so the turn hangs and this FAILS;
    /// AFTER the fix it resolves immediately with CancellationError and PASSES.
    @Test func switchingEngineMidTurnCancelsInFlightTurnExactlyOnce() async throws {
        let binaryPath = try makeFakeClaudeStreamJSONBinary()
        let engine = ClaudeCodeEngine(binaryPath: binaryPath, homeDirectoryPath: NSTemporaryDirectory())
        let companionManager = CompanionManager()
        let recorder = TurnResolutionRecorder()

        // An in-flight turn the fake withholds the result for (stays streaming).
        let inFlightTurn = Task {
            do {
                _ = try await engine.analyzeImageStreaming(
                    images: [],
                    systemPrompt: "sys",
                    conversationHistory: [],
                    userPrompt: "please answer HANG_UNTIL_INTERRUPT",
                    onTextChunk: { _ in }
                )
                recorder.record(.completed)
            } catch is CancellationError {
                recorder.record(.cancelled)
            } catch {
                recorder.record(.otherError)
            }
        }

        // Let the turn reach in-flight (delta streamed, result withheld).
        try await Task.sleep(nanoseconds: 500_000_000)

        // Run the real engine-switch teardown: cancel the in-flight turn, THEN
        // shut the old engine's session down.
        companionManager.testRunEngineSwitchTeardown(injectingEngine: engine, inFlightTurn: inFlightTurn)

        // Must resolve quickly (not hang) and exactly once, with CancellationError.
        let resolvedInTime = await taskResolved(inFlightTurn, withinSeconds: 5)
        #expect(resolvedInTime, "in-flight turn never resolved — its continuation hung (Blocking #1)")
        #expect(recorder.snapshot() == [.cancelled])
    }
}
