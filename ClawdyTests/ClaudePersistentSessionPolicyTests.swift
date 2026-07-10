//
//  ClaudePersistentSessionPolicyTests.swift
//  ClawdyTests
//
//  Headless unit tests for the warm-session lifecycle DECISIONS (when to
//  respawn, when to prime a cold process with history, when to tear down an idle
//  process) and the capture-overlap ordering decision. The live process I/O is
//  not headless-testable, so the pure decision logic is isolated here.
//

import Testing
import Foundation
@testable import Clawdy

struct ClaudePersistentSessionPolicyTests {

    // MARK: - Spawn / respawn

    @Test func spawnsWhenNoLiveProcess() {
        #expect(ClaudePersistentSessionPolicy.shouldSpawnBeforeRequest(
            hasLiveProcess: false,
            isStreamSynced: true,
            liveSystemPrompt: "sys",
            requestedSystemPrompt: "sys"
        ) == true)
    }

    @Test func reusesWarmProcessForSamePromptWhenSynced() {
        #expect(ClaudePersistentSessionPolicy.shouldSpawnBeforeRequest(
            hasLiveProcess: true,
            isStreamSynced: true,
            liveSystemPrompt: "sys",
            requestedSystemPrompt: "sys"
        ) == false)
    }

    @Test func respawnsWhenStreamNotYetSyncedAfterCancel() {
        // A cancelled turn that hasn't drained leaves the stream unsynced — reuse
        // could interleave output, so respawn instead.
        #expect(ClaudePersistentSessionPolicy.shouldSpawnBeforeRequest(
            hasLiveProcess: true,
            isStreamSynced: false,
            liveSystemPrompt: "sys",
            requestedSystemPrompt: "sys"
        ) == true)
    }

    @Test func respawnsWhenSystemPromptChanges() {
        // The system prompt is a fixed launch flag (e.g. voice vs onboarding demo),
        // so a different prompt needs a fresh process.
        #expect(ClaudePersistentSessionPolicy.shouldSpawnBeforeRequest(
            hasLiveProcess: true,
            isStreamSynced: true,
            liveSystemPrompt: "voice-prompt",
            requestedSystemPrompt: "onboarding-prompt"
        ) == true)
    }

    // MARK: - Cold-start history priming

    @Test func primesHistoryOnlyOnFreshSpawnWithHistory() {
        #expect(ClaudePersistentSessionPolicy.shouldPrimeWithHistory(isFreshlySpawned: true, hasHistory: true) == true)
        // A warm process already remembers the session — don't re-send history.
        #expect(ClaudePersistentSessionPolicy.shouldPrimeWithHistory(isFreshlySpawned: false, hasHistory: true) == false)
        // Nothing to prime with.
        #expect(ClaudePersistentSessionPolicy.shouldPrimeWithHistory(isFreshlySpawned: true, hasHistory: false) == false)
    }

    // MARK: - Idle teardown

    @Test func tearsDownOnlyAtOrPastTheIdleTimeout() {
        #expect(ClaudePersistentSessionPolicy.shouldTearDownIdle(idleSeconds: 120, idleTimeoutSeconds: 120) == true)
        #expect(ClaudePersistentSessionPolicy.shouldTearDownIdle(idleSeconds: 121, idleTimeoutSeconds: 120) == true)
        #expect(ClaudePersistentSessionPolicy.shouldTearDownIdle(idleSeconds: 119, idleTimeoutSeconds: 120) == false)
    }

    // MARK: - Keep-warm: idle teardown disabled for the app-lifetime session

    @Test func idleTeardownDisabledWhenKeptWarmForAppLifetime() {
        // The long-lived (keep-warm) session must NEVER arm idle teardown — it stays
        // alive for the whole app lifetime and is only torn down explicitly.
        #expect(ClaudePersistentSessionPolicy.shouldArmIdleTeardown(keepWarmForAppLifetime: true) == false)
        // The legacy session still reclaims itself on idle.
        #expect(ClaudePersistentSessionPolicy.shouldArmIdleTeardown(keepWarmForAppLifetime: false) == true)
    }

    // MARK: - Keep-warm: respawn-on-death (self-heal)

    @Test func respawnsAfterUnexpectedDeathOnlyWhenKeptWarm() {
        // A keep-warm session self-heals after an unexpected death; a legacy session
        // waits for the next request to respawn lazily instead.
        #expect(ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: true,
            consecutiveRespawnsWithoutSuccess: 0,
            maxConsecutiveRespawns: 3
        ) == true)
        #expect(ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: false,
            consecutiveRespawnsWithoutSuccess: 0,
            maxConsecutiveRespawns: 3
        ) == false)
    }

    @Test func respawnBacksOffAfterTooManyConsecutiveFailures() {
        // Below the cap → keep self-healing.
        #expect(ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: true,
            consecutiveRespawnsWithoutSuccess: 2,
            maxConsecutiveRespawns: 3
        ) == true)
        // At/above the cap → stop hot-looping; the next real request surfaces the
        // genuine error to the user instead.
        #expect(ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: true,
            consecutiveRespawnsWithoutSuccess: 3,
            maxConsecutiveRespawns: 3
        ) == false)
        #expect(ClaudePersistentSessionPolicy.shouldRespawnAfterUnexpectedDeath(
            keepWarmForAppLifetime: true,
            consecutiveRespawnsWithoutSuccess: 4,
            maxConsecutiveRespawns: 3
        ) == false)
    }

    // MARK: - Keep-warm: cancelling one turn keeps the session alive

    @Test func cancellingOneTurnNeverTerminatesTheSharedSession() {
        // Cancelling a turn must interrupt only that turn (via control_request) and
        // leave the long-lived session ready for the next request.
        #expect(ClaudePersistentSessionPolicy.shouldTerminateProcessOnTurnCancel() == false)
    }

    // MARK: - Engine switch: tear down old, start new

    @Test func switchingToADifferentEngineTearsDownAndRestarts() {
        #expect(CoachEngineSwitchPlan.shouldTearDownPreviousAndStartNew(
            previousKind: .claudeCode,
            newKind: .codex
        ) == true)
        // First-ever selection (no previous engine) also starts the new session.
        #expect(CoachEngineSwitchPlan.shouldTearDownPreviousAndStartNew(
            previousKind: nil,
            newKind: .claudeCode
        ) == true)
    }

    @Test func reselectingTheSameEngineIsANoOp() {
        // Re-picking the already-selected engine must NOT tear down and respawn the
        // already-warm session.
        #expect(CoachEngineSwitchPlan.shouldTearDownPreviousAndStartNew(
            previousKind: .claudeCode,
            newKind: .claudeCode
        ) == false)
    }

    // MARK: - Capture overlap ordering

    @Test func reusesPendingCaptureOnlyWhenItExistsAndSucceeded() {
        #expect(ScreenCaptureOverlapPlan.source(hasPendingCapture: true, pendingCaptureSucceeded: true) == .reusePendingCapture)
        // Started at press but failed → capture fresh.
        #expect(ScreenCaptureOverlapPlan.source(hasPendingCapture: true, pendingCaptureSucceeded: false) == .captureFresh)
        // None was started (e.g. a non-overlapped path) → capture fresh.
        #expect(ScreenCaptureOverlapPlan.source(hasPendingCapture: false, pendingCaptureSucceeded: false) == .captureFresh)
    }
}
