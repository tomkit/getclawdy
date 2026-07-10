//
//  ResearchLifecycleIsolationTests.swift
//  ClawdyTests
//
//  REAL-PATH regression tests proving the research subsystem and the warm
//  quick-answer session are LIFECYCLE-ISOLATED: a quick Ctrl+Option voice answer
//  (which cancels the warm turn) never cancels a running research run, and the
//  research Stop control (which SIGTERMs the research process) never touches the
//  warm session. Each side is a genuinely separate Process driven by its own fake
//  binary — the test exercises the real ClaudeResearchEngine / CLIProcessRunner
//  and ClaudePersistentSession plumbing, not just pure helpers.
//
//  Also covers the engine's two-phase behavior end-to-end (plan detects
//  clarification; plan→execute writes the HTML deliverable) against a fake claude.
//

import Testing
import Foundation
import Combine
import AppKit
@testable import Clawdy

// MARK: - Fakes

/// A fake `claude` stream-json binary for the WARM session: streams a delta then a
/// result for a normal turn, drains on a control_request interrupt, and withholds
/// the result for a HANG_UNTIL_INTERRUPT turn so it stays in-flight. (Mirrors the
/// warm-session lifecycle test's fake; duplicated here because that one is private.)
private func makeWarmFakeClaudeBinary() throws -> String {
    let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"streaming "}}}"#
    let finalResult = #"{"type":"result","result":"final answer","is_error":false}"#
    let interruptedResult = #"{"type":"result","result":"(interrupted)","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    while IFS= read -r line; do
      case "$line" in
        *control_request*) emit '\(interruptedResult)' ;;
        *HANG_UNTIL_INTERRUPT*) emit '\(delta)' ;;
        *DIE_NOW*) exit 1 ;;
        *) emit '\(delta)'; emit '\(finalResult)' ;;
      esac
    done
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// A fake `claude` binary for the RESEARCH subsystem. It parses argv to find the
/// `-p` prompt, the `--permission-mode`, the `--add-dir` output directory, and the
/// `--resume` session id, then:
///   - emits a system/init line (so the plan phase captures a session id),
///   - HANG  → execs `sleep` and stays alive until SIGTERM (the Stop / re-press path),
///   - plan  → PERSISTS the session as a per-CWD marker file (`session-<id>.marker`
///     in `pwd`) exactly like the real CLI keys sessions by project/working dir,
///     then emits a result with a question (NEEDS_CLARIFY) or a proceed plan,
///   - execute → models the REAL CLI: `--resume <id>` only resolves when the plan
///     session was persisted UNDER THE SAME WORKING DIRECTORY. If the per-CWD
///     `session-<id>.marker` is absent, it prints the real CLI's error shape
///     ("No conversation found with session ID: <id>") and exits 1 — the exact
///     failure that made every real research run end in `phaseFailed` before the
///     plan/execute-share-one-CWD fix. When the session resolves, it takes its
///     output path + "write the page" instruction from the `-p` USER MESSAGE (the
///     channel that survives `--resume`), writes the HTML to the ABSOLUTE path
///     embedded in that message, and records its working directory (a RELATIVE
///     write of `pwd -P`) so a test can prove the CWD is the scoped temp dir.
private func makeResearchFakeClaudeBinary() throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-fake-1"}"#
    let clarifyResult = #"{"type":"result","result":"what is your budget, and which region?","is_error":false}"#
    let proceedResult = #"{"type":"result","result":"here is the plan, proceeding now","is_error":false}"#
    let executeResult = #"{"type":"result","result":"done, wrote report.html","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    mode=""
    adddir=""
    task=""
    resume=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        --permission-mode) mode="$a" ;;
        --add-dir) adddir="$a" ;;
        -p) task="$a" ;;
        --resume) resume="$a" ;;
      esac
      prev="$a"
    done
    emit '\(initLine)'
    case "$task" in
      *HANG*) exec sleep 600 ;;
      *FAIL*) echo "forced plan failure" 1>&2; exit 1 ;;
    esac
    if [ -z "$resume" ]; then
      # PLAN: the real CLI persists the session under a project keyed by the CWD.
      # Model that by writing a per-CWD session marker; the execute phase's
      # --resume can only find it when it runs in the SAME working directory.
      echo "plan" > "session-sess-fake-1.marker"
      case "$task" in
        *NEEDS_CLARIFY*) emit '\(clarifyResult)' ;;
        *) emit '\(proceedResult)' ;;
      esac
    else
      # EXECUTE (--resume): fail EXACTLY like the real CLI when the session isn't
      # persisted under this CWD — this is the bug the shared-CWD fix addresses.
      if [ ! -f "session-$resume.marker" ]; then
        emit "{\\"type\\":\\"result\\",\\"result\\":\\"No conversation found with session ID: $resume\\",\\"is_error\\":true}"
        echo "No conversation found with session ID: $resume" 1>&2
        exit 1
      fi
      # record CWD (relative write proves CWD == output dir), and take the output
      # path + write instruction from the -p user message (survives resume).
      pwd -P > cwd_marker.txt
      outpath=$(printf '%s' "$task" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
      if [ -n "$outpath" ]; then
        printf '<!doctype html><html><body><h1>report</h1></body></html>' > "$outpath"
      fi
      emit '\(executeResult)'
    fi
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// Thread-safe flag the research Task flips when its body returns, so the test (on
/// another actor) can observe whether the research run is still in flight.
private final class TaskFinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

/// The fake research binary always echoes this session id in its init line (and
/// keys its per-CWD session marker by it), so the tests pass it as the pre-minted
/// `--session-id` to keep the minted id and the echoed id in agreement — exactly as
/// the real CLI behaves (it echoes `--session-id` back verbatim).
private let fakeResearchSessionID = "sess-fake-1"

/// Creates a throwaway stable-style per-session output directory under a UNIQUE
/// temp Application Support base, so each engine test gets an isolated, writable
/// working directory that both phases can share without colliding with any other
/// test or the real `~/Library/Application Support`.
private func makeScratchOutputDirectory(sessionID: String = fakeResearchSessionID) throws -> URL {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clawdy-appsupport-\(UUID().uuidString)", isDirectory: true)
    return try ClaudeResearchEngine.makeSessionOutputDirectory(
        sessionID: sessionID,
        applicationSupportDirectory: temporaryApplicationSupport
    )
}

private func pollUntilResearch(
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

// MARK: - Isolation tests

struct ResearchLifecycleIsolationTests {

    /// A quick Ctrl+Option answer cancels the WARM turn; that cancel must NOT cancel
    /// a research run that's already in flight (separate process / task / state).
    @Test func cancellingAQuickWarmTurnDoesNotCancelARunningResearchRun() async throws {
        // Research run (separate process) that hangs in its plan phase.
        let researchBinary = try makeResearchFakeClaudeBinary()
        let researchEngine = ClaudeResearchEngine(
            binaryPath: researchBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            planPhaseTimeoutSeconds: 60,
            executePhaseTimeoutSeconds: 60
        )
        let researchFinished = TaskFinishedFlag()
        let researchTask = Task { () -> Error? in
            defer { researchFinished.markFinished() }
            do {
                _ = try await researchEngine.runPlanPhase(task: "HANG please research forever", sessionID: fakeResearchSessionID, outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), onProgress: { _ in })
                return nil
            } catch {
                return error
            }
        }

        // Let the research process get going and stay in-flight.
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(researchFinished.hasFinished == false, "research run should still be in flight")

        // The warm quick-answer session, a SEPARATE process.
        let warmBinary = try makeWarmFakeClaudeBinary()
        let warmSession = ClaudePersistentSession(
            binaryPath: warmBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )
        defer { warmSession.shutdown() }

        // A warm turn that stays in-flight, then a re-press cancels it.
        let warmTurn = Task { () -> Error? in
            do {
                _ = try await warmSession.sendRequest(
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
        try await Task.sleep(nanoseconds: 400_000_000)
        warmTurn.cancel()
        let warmError = await warmTurn.value
        #expect(warmError is CancellationError)

        // THE ASSERTION: the warm cancel left the research run untouched — still running.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(researchFinished.hasFinished == false, "warm-turn cancel must NOT cancel the research run")

        // Now stop the research run itself (the Stop control / SIGTERM) and confirm
        // it WAS the thing keeping it alive — it now resolves with CancellationError.
        researchTask.cancel()
        let researchError = await researchTask.value
        #expect(researchError is CancellationError)
    }

    /// Stopping a research run (SIGTERM to its process) must NOT touch the warm
    /// session: the warm process stays alive and reusable, with no respawn.
    @Test func stoppingResearchDoesNotKillTheWarmSession() async throws {
        let warmBinary = try makeWarmFakeClaudeBinary()
        let warmSession = ClaudePersistentSession(
            binaryPath: warmBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )
        defer { warmSession.shutdown() }

        // Prove the warm session works before research starts.
        let firstWarm = try await warmSession.sendRequest(
            systemPrompt: "sys", userText: "hello", historyPrimerText: nil, images: [],
            onAccumulatedText: { _ in }
        )
        #expect(firstWarm == "final answer")
        let warmSpawnsBefore = warmSession.spawnCountForTesting

        // Start a research run (separate process) that hangs.
        let researchBinary = try makeResearchFakeClaudeBinary()
        let researchEngine = ClaudeResearchEngine(
            binaryPath: researchBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            planPhaseTimeoutSeconds: 60,
            executePhaseTimeoutSeconds: 60
        )
        let researchTask = Task { () -> Error? in
            do {
                _ = try await researchEngine.runPlanPhase(task: "HANG forever", sessionID: fakeResearchSessionID, outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), onProgress: { _ in })
                return nil
            } catch { return error }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Stop research (SIGTERM only its process).
        researchTask.cancel()
        let researchError = await researchTask.value
        #expect(researchError is CancellationError)

        // THE ASSERTION: the warm session is untouched — still live, same process
        // (no respawn), and serves the next turn normally.
        #expect(warmSession.hasLiveProcessForTesting == true)
        let secondWarm = try await warmSession.sendRequest(
            systemPrompt: "sys", userText: "still there?", historyPrimerText: nil, images: [],
            onAccumulatedText: { _ in }
        )
        #expect(secondWarm == "final answer")
        #expect(warmSession.spawnCountForTesting == warmSpawnsBefore, "warm process must NOT have respawned")
    }

    // MARK: - Engine two-phase behavior (plan / execute) against the fake

    @Test func planPhaseSurfacesClarifyingQuestionsWhenTheModelAsks() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let engine = ClaudeResearchEngine(binaryPath: researchBinary, homeDirectoryPath: NSTemporaryDirectory())
        let outputDirectory = try makeScratchOutputDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let planResult = try await engine.runPlanPhase(task: "NEEDS_CLARIFY about desks", sessionID: fakeResearchSessionID, outputDirectory: outputDirectory, onProgress: { _ in })
        #expect(planResult.sessionID == "sess-fake-1")
        #expect(planResult.outcome == .needsClarification(questions: "what is your budget, and which region?"))
    }

    @Test func planThenExecuteProducesTheHTMLDeliverable() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let engine = ClaudeResearchEngine(binaryPath: researchBinary, homeDirectoryPath: NSTemporaryDirectory())

        // Both phases MUST share this one output directory so the plan session the
        // execute phase resumes is persisted under the CWD execute resumes in.
        let outputDirectory = try makeScratchOutputDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let planResult = try await engine.runPlanPhase(task: "research desks and build a page", sessionID: fakeResearchSessionID, outputDirectory: outputDirectory, onProgress: { _ in })
        #expect(planResult.outcome == .readyToExecute)

        var sawWritingPage = false
        let deliverableURL = try await engine.runExecutePhase(
            sessionID: planResult.sessionID,
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { event in if event == .writingPage { sawWritingPage = true } }
        )
        #expect(deliverableURL.lastPathComponent == "report.html")
        #expect(FileManager.default.fileExists(atPath: deliverableURL.path) == true)
        let html = try String(contentsOf: deliverableURL, encoding: .utf8)
        #expect(html.contains("<h1>report</h1>"))
        // The fake doesn't emit a Write tool_use, so sawWritingPage stays false — the
        // deliverable presence is the real assertion. (Referenced to avoid warnings.)
        _ = sawWritingPage
    }

    /// Blocking #2 regression: the execute process must be launched with its working
    /// directory SCOPED TO THE PER-RUN TEMP DIR (not $HOME), so the file sandbox is
    /// scoped and a relative write lands there. The fake records `pwd -P` via a
    /// RELATIVE write; we assert that file materialized inside the output dir and
    /// holds the output dir's path. Fails before the fix (CWD was homeDirectoryPath,
    /// so the marker would land in $HOME and never appear in the output dir).
    @Test func executePhaseRunsWithWorkingDirectoryScopedToTheOutputDirNotHome() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        // Use a DISTINCT home so "not home" is unambiguous.
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("research-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let engine = ClaudeResearchEngine(binaryPath: researchBinary, homeDirectoryPath: fakeHome.path)

        let outputDirectory = try makeScratchOutputDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let planResult = try await engine.runPlanPhase(task: "research and build a page", sessionID: fakeResearchSessionID, outputDirectory: outputDirectory, onProgress: { _ in })

        _ = try await engine.runExecutePhase(
            sessionID: planResult.sessionID,
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { _ in }
        )

        // The relative `pwd -P` marker must have landed in the OUTPUT dir (proving
        // CWD == output dir), and must NOT exist in $HOME.
        let markerInOutputDir = outputDirectory.appendingPathComponent("cwd_marker.txt")
        #expect(FileManager.default.fileExists(atPath: markerInOutputDir.path) == true,
                "CWD marker must land in the scoped output dir (CWD must be the temp dir)")
        #expect(FileManager.default.fileExists(atPath: fakeHome.appendingPathComponent("cwd_marker.txt").path) == false,
                "CWD marker must NOT land in $HOME")

        // Canonicalize the macOS /var ⇄ /private/var symlink so `pwd -P` (which
        // resolves it) and the Swift URL path compare equal.
        func canonicalPath(_ path: String) -> String {
            path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        let recordedWorkingDirectory = canonicalPath(
            (try String(contentsOf: markerInOutputDir, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let expectedWorkingDirectory = canonicalPath(outputDirectory.path)
        #expect(recordedWorkingDirectory == expectedWorkingDirectory,
                "execute CWD must be the per-run temp dir, got: \(recordedWorkingDirectory)")
        #expect(recordedWorkingDirectory != canonicalPath(fakeHome.path))
    }

    /// Root cause of the live "research failed": Claude Code persists each session
    /// under a project keyed by the working directory, so `--resume <id>` only
    /// resolves in the SAME CWD the plan phase ran in. When the plan phase ran in a
    /// DIFFERENT directory than the execute phase, `--resume` failed with "No
    /// conversation found with session ID: …" (exit 1), which the engine surfaces as
    /// `ResearchError.phaseFailed`. This test reproduces exactly that mismatch and
    /// asserts the failure shape — it fails to even compile-pass if resume were CWD
    /// independent, and documents WHY plan + execute must share one directory.
    @Test func executeResumeFailsWhenItRunsInADifferentDirectoryThanThePlanPhase() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let engine = ClaudeResearchEngine(binaryPath: researchBinary, homeDirectoryPath: NSTemporaryDirectory())

        let planDirectory = try makeScratchOutputDirectory()
        let executeDirectory = try makeScratchOutputDirectory()
        defer {
            try? FileManager.default.removeItem(at: planDirectory)
            try? FileManager.default.removeItem(at: executeDirectory)
        }

        // Plan persists its session under planDirectory.
        let planResult = try await engine.runPlanPhase(task: "research and build a page", sessionID: fakeResearchSessionID, outputDirectory: planDirectory, onProgress: { _ in })
        #expect(planResult.outcome == .readyToExecute)

        // Execute resumes from a DIFFERENT directory — the session isn't there.
        var thrownError: Error?
        do {
            _ = try await engine.runExecutePhase(
                sessionID: planResult.sessionID,
                outputDirectory: executeDirectory,
                clarificationAnswers: nil,
                onProgress: { _ in }
            )
        } catch {
            thrownError = error
        }

        guard case ClaudeResearchEngine.ResearchError.phaseFailed(let standardError)? = thrownError else {
            Issue.record("expected ResearchError.phaseFailed from a cross-directory --resume, got: \(String(describing: thrownError))")
            return
        }
        #expect(standardError.contains("No conversation found with session ID"),
                "the failure must carry the real CLI's resume error shape")
        #expect(FileManager.default.fileExists(atPath: executeDirectory.appendingPathComponent("report.html").path) == false,
                "no deliverable is produced when the session can't be resumed")
    }
}

// MARK: - Multi-session manager (Slice B: the concurrent-sessions spine)

/// Deterministic, monotonically-distinct session ids so each spawned session gets its
/// OWN id (and thus its own dictionary slot, output dir, and manifest key) without
/// relying on the forbidden `Date`/`UUID`-random paths being predictable.
private final class MonotonicResearchSessionIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        nextIndex += 1
        return "sess-manager-\(nextIndex)"
    }
}

/// Builds a `ResearchSessionManager` wired to a fake `claude` binary with hermetic
/// per-manager temp locations (never the shared Application Support / manifest) and a
/// distinct-id generator, so multi-session behavior can be exercised end-to-end
/// against real per-session processes.
/// A session-id generator that returns a scripted sequence first (to force a
/// collision or an id-aligned success run) and then falls back to distinct monotonic
/// ids, so a test can drive the manager's collision-remint path deterministically.
private final class ScriptedResearchSessionIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String]
    private let fallback = MonotonicResearchSessionIDGenerator()
    init(_ scripted: [String]) { self.scripted = scripted }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        if !scripted.isEmpty { return scripted.removeFirst() }
        return fallback.next()
    }
}

@MainActor
private func makeResearchSessionManager(
    binaryPath: String,
    generateSessionID: (() -> String)? = nil
) -> ResearchSessionManager {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("manager-appsupport-\(UUID().uuidString)", isDirectory: true)
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("manager-manifest-\(UUID().uuidString).json")
    let idGenerator = MonotonicResearchSessionIDGenerator()
    return ResearchSessionManager(
        resolveClaudeBinaryPath: { binaryPath },
        makeEngine: { _, path in
            ClaudeResearchEngine(
                binaryPath: path,
                homeDirectoryPath: NSTemporaryDirectory(),
                planPhaseTimeoutSeconds: 60,
                executePhaseTimeoutSeconds: 60
            )
        },
        generateSessionID: generateSessionID ?? { idGenerator.next() },
        applicationSupportDirectory: temporaryApplicationSupport,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

@MainActor
struct ResearchMultiSessionTests {

    /// A second `[RESEARCH]` directive while one is already running SPAWNS a second
    /// concurrent session — it is NOT rejected by any single-run guard (the old
    /// coordinator's `isRunning` no-op). Both sessions are live at once.
    @Test func secondDirectiveSpawnsAConcurrentSecondSessionInsteadOfBeingRejected() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)

        let firstID = manager.startSession(taskDescription: "HANG research one forever")
        let secondID = manager.startSession(taskDescription: "HANG research two forever")

        #expect(firstID != secondID, "each directive must mint a distinct session")
        #expect(manager.activeSessionCountForTesting == 2, "the second directive must not be rejected")

        // Let both processes actually spawn and stay in flight.
        try await pollUntilResearch(timeoutSeconds: 5, "both sessions to be planning") {
            manager.sessionForTesting(id: firstID)?.state == .planning &&
            manager.sessionForTesting(id: secondID)?.state == .planning
        }
        #expect(manager.sessionForTesting(id: firstID)?.isActive == true)
        #expect(manager.sessionForTesting(id: secondID)?.isActive == true)

        manager.stopAll()
    }

    /// N sessions run isolated: STOPPING one session leaves the others running and the
    /// warm quick-answer session completely untouched (no respawn).
    @Test func stoppingOneSessionLeavesTheOthersAndTheWarmSessionUntouched() async throws {
        // The warm session, a genuinely separate process.
        let warmBinary = try makeWarmFakeClaudeBinary()
        let warmSession = ClaudePersistentSession(
            binaryPath: warmBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )
        defer { warmSession.shutdown() }
        let firstWarm = try await warmSession.sendRequest(
            systemPrompt: "sys", userText: "hello", historyPrimerText: nil, images: [],
            onAccumulatedText: { _ in }
        )
        #expect(firstWarm == "final answer")
        let warmSpawnsBefore = warmSession.spawnCountForTesting

        // Three concurrent hanging research sessions.
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }
        let idA = manager.startSession(taskDescription: "HANG session A")
        let idB = manager.startSession(taskDescription: "HANG session B")
        let idC = manager.startSession(taskDescription: "HANG session C")
        try await pollUntilResearch(timeoutSeconds: 5, "all three planning") {
            manager.sessionForTesting(id: idA)?.state == .planning &&
            manager.sessionForTesting(id: idB)?.state == .planning &&
            manager.sessionForTesting(id: idC)?.state == .planning
        }

        // Stop ONLY session A.
        manager.stopSession(id: idA)
        #expect(manager.sessionForTesting(id: idA)?.state == .stopped)

        // B and C are untouched — still in flight.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.sessionForTesting(id: idB)?.isActive == true, "stopping A must not stop B")
        #expect(manager.sessionForTesting(id: idC)?.isActive == true, "stopping A must not stop C")

        // The warm session is untouched — same process, still serves a turn.
        #expect(warmSession.hasLiveProcessForTesting == true)
        let secondWarm = try await warmSession.sendRequest(
            systemPrompt: "sys", userText: "still there?", historyPrimerText: nil, images: [],
            onAccumulatedText: { _ in }
        )
        #expect(secondWarm == "final answer")
        #expect(warmSession.spawnCountForTesting == warmSpawnsBefore, "warm process must NOT have respawned")
    }

    /// A session that FAILS must not affect a concurrent running session — failure is
    /// isolated to the one run.
    @Test func aFailingSessionDoesNotAffectAConcurrentRunningSession() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }

        let hangID = manager.startSession(taskDescription: "HANG keep running")
        let failID = manager.startSession(taskDescription: "FAIL right away")

        try await pollUntilResearch(timeoutSeconds: 5, "the failing session to fail") {
            manager.sessionForTesting(id: failID)?.state == .failed
        }
        #expect(manager.sessionForTesting(id: failID)?.state == .failed)

        // The hanging session is untouched by its sibling's failure.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.sessionForTesting(id: hangID)?.isActive == true,
                "a sibling's failure must not disturb a running session")
    }

    /// A quick Ctrl+Option warm answer (which cancels the warm turn) cancels NEITHER
    /// of two concurrent research sessions — the multi-session extension of the
    /// original single-run isolation guarantee.
    @Test func aQuickWarmTurnCancelCancelsNeitherOfTwoResearchSessions() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }
        let idA = manager.startSession(taskDescription: "HANG research A")
        let idB = manager.startSession(taskDescription: "HANG research B")
        try await pollUntilResearch(timeoutSeconds: 5, "both planning") {
            manager.sessionForTesting(id: idA)?.state == .planning &&
            manager.sessionForTesting(id: idB)?.state == .planning
        }

        // A warm turn that stays in flight, then a re-press cancels it.
        let warmBinary = try makeWarmFakeClaudeBinary()
        let warmSession = ClaudePersistentSession(
            binaryPath: warmBinary,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true
        )
        defer { warmSession.shutdown() }
        let warmTurn = Task { () -> Error? in
            do {
                _ = try await warmSession.sendRequest(
                    systemPrompt: "sys", userText: "please answer HANG_UNTIL_INTERRUPT",
                    historyPrimerText: nil, images: [], onAccumulatedText: { _ in }
                )
                return nil
            } catch { return error }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        warmTurn.cancel()
        #expect(await warmTurn.value is CancellationError)

        // BOTH research sessions survive the warm cancel.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.sessionForTesting(id: idA)?.isActive == true)
        #expect(manager.sessionForTesting(id: idB)?.isActive == true)
    }

    /// Focus state sets and clears and is OBSERVABLE via the manager's `@Published`
    /// `focusedSessionID` — the read-only prerequisite the next (voice) slice consumes.
    @Test func focusStateSetsAndClearsAndIsObservable() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }

        // Record every emission of the observable focus id.
        var observedFocusIDs: [ResearchSessionID?] = []
        let cancellable = manager.$focusedSessionID.sink { observedFocusIDs.append($0) }
        defer { cancellable.cancel() }

        let idA = manager.startSession(taskDescription: "HANG focus A")
        _ = manager.startSession(taskDescription: "HANG focus B")

        #expect(manager.focusedSessionID == nil, "no session is focused initially")

        manager.focus(id: idA)
        #expect(manager.focusedSessionID == idA)

        manager.clearFocus()
        #expect(manager.focusedSessionID == nil)

        // The Combine publisher emitted the initial nil, then idA, then nil again.
        #expect(observedFocusIDs.contains(idA), "focus change must be observable")
        #expect(observedFocusIDs.last == .some(nil), "the clear must be observable")
    }

    /// The manager drives the stacked overlay: one session behaves like today (a
    /// single pill, no overflow); beyond three it collapses to 3 pills + a "+N more"
    /// overflow count.
    @Test func stackedOverlayShowsPillsAndCollapsesBeyondThree() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }
        let overlay = manager.stackedOverlayForTesting

        // One session → one pill, no overflow (looks like the old single overlay).
        _ = manager.startSession(taskDescription: "HANG only one")
        #expect(overlay.renderedPillCountForTesting == 1)
        #expect(overlay.renderedHiddenCountForTesting == 0)

        // Four sessions, collapsed → 3 pills + "+1 more".
        _ = manager.startSession(taskDescription: "HANG two")
        _ = manager.startSession(taskDescription: "HANG three")
        _ = manager.startSession(taskDescription: "HANG four")
        #expect(manager.activeSessionCountForTesting == 4)
        #expect(overlay.renderedPillCountForTesting == 3, "collapse to at most three visible pills")
        #expect(overlay.renderedHiddenCountForTesting == 1, "the fourth folds into +1 more")
    }

    /// BLOCKING 1 (real manager path): expanding a >3 stack renders all pills PLUS a
    /// reachable "show less" control, and toggling collapses back to first-3 + "+N
    /// more" — both directions across the 3↔4 boundary. Before the fix the expanded
    /// state emitted no control row, so "show less" was unreachable.
    @Test func managerExpandCollapseTogglesTheReachableControlRow() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        let manager = makeResearchSessionManager(binaryPath: researchBinary)
        defer { manager.stopAll() }
        let overlay = manager.stackedOverlayForTesting
        for index in 1...4 { _ = manager.startSession(taskDescription: "HANG \(index)") }

        // Collapsed: 3 pills + "+1 more".
        #expect(overlay.renderedPillCountForTesting == 3)
        #expect(overlay.renderedControlRowForTesting == .showMore(hiddenCount: 1))

        // Expand → all 4 pills + a REACHABLE "show less".
        manager.toggleStackExpansionForTesting()
        #expect(overlay.renderedPillCountForTesting == 4)
        #expect(overlay.renderedControlRowForTesting == .showLess,
                "expanded manager stack must render a reachable collapse control")

        // Collapse again → back to 3 + "+1 more".
        manager.toggleStackExpansionForTesting()
        #expect(overlay.renderedPillCountForTesting == 3)
        #expect(overlay.renderedControlRowForTesting == .showMore(hiddenCount: 1))
    }

    /// BLOCKING 2: `stopAll()` is a FULL teardown — with a mix of an active session, a
    /// COMPLETED session (whose results window persists), a focused session, and a
    /// pending auto-hide timer, everything is cleared: no sessions, no order, no focus,
    /// no pending removal work item, and the overlay windows are hidden.
    @Test func stopAllFullyTearsDownActiveCompletedAndPendingState() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        // Align the FIRST minted id with the fake's session marker so that run resumes
        // and COMPLETES; later sessions fall back to distinct monotonic ids.
        let scriptedGenerator = ScriptedResearchSessionIDGenerator([fakeResearchSessionID])
        let manager = makeResearchSessionManager(binaryPath: researchBinary, generateSessionID: scriptedGenerator.next)
        let overlay = manager.stackedOverlayForTesting

        // A run that completes (deliverable + persistent results window).
        let completedID = manager.startSession(taskDescription: "research desks and build a page")
        try await pollUntilResearch(timeoutSeconds: 20, "the first session to complete") {
            manager.sessionForTesting(id: completedID)?.state == .completed
        }

        // A second run that stays active, then is stopped — scheduling an auto-hide timer.
        let activeID = manager.startSession(taskDescription: "HANG keep going")
        try await pollUntilResearch(timeoutSeconds: 5, "the second session to be planning") {
            manager.sessionForTesting(id: activeID)?.state == .planning
        }
        manager.stopSession(id: activeID)
        #expect(manager.sessionForTesting(id: activeID)?.state == .stopped)
        #expect(manager.pendingRemovalCountForTesting >= 1, "stopping a session schedules an auto-hide removal")

        // Focus the completed session. (A DONE session is lineage-focused but its
        // detail/progress panel is intentionally NOT shown — see the click double-open
        // fix — so the panel may never be created here; teardown must still be clean.)
        manager.focus(id: completedID)
        #expect(manager.focusedSessionID == completedID)
        #expect(manager.activeSessionCountForTesting == 2)

        // FULL teardown.
        manager.stopAll()

        #expect(manager.activeSessionCountForTesting == 0, "no sessions survive teardown")
        #expect(manager.sessionOrderForTesting.isEmpty, "insertion order is cleared")
        #expect(manager.focusedSessionID == nil, "focus is cleared")
        #expect(manager.isStackExpandedForTesting == false, "expansion is reset")
        #expect(manager.pendingRemovalCountForTesting == 0, "no leaked auto-hide/removal work item")
        #expect(overlay.toastPanelCountForTesting == 0, "every toast window is torn down")
        // The detail panel is not on screen (never shown for a done focused session, or
        // hidden by teardown if it had been).
        #expect(overlay.detailPanelForTesting?.isVisible != true, "the detail panel is not visible")
    }

    /// BLOCKING 3: a colliding id generator (returns a dup, then the same dup again,
    /// then a unique id) must NOT let a second session clobber the first — the manager
    /// re-mints past the collision so both sessions coexist addressably.
    @Test func collidingSessionIDsAreRemintedSoBothSessionsCoexist() async throws {
        let researchBinary = try makeResearchFakeClaudeBinary()
        // 1st session → "dup"; 2nd session → "dup" (collision) then re-mint → "unique".
        let scriptedGenerator = ScriptedResearchSessionIDGenerator(["dup", "dup", "unique"])
        let manager = makeResearchSessionManager(binaryPath: researchBinary, generateSessionID: scriptedGenerator.next)
        defer { manager.stopAll() }

        let firstID = manager.startSession(taskDescription: "HANG first")
        let firstSession = manager.sessionForTesting(id: firstID)
        let secondID = manager.startSession(taskDescription: "HANG second")

        #expect(firstID == "dup")
        #expect(secondID == "unique", "a colliding id must be re-minted to a unique one")
        #expect(firstID != secondID)
        #expect(manager.activeSessionCountForTesting == 2, "the collision must not clobber the first session")

        // BOTH coexist addressably; the first session object was not orphaned/replaced.
        #expect(manager.sessionForTesting(id: "dup") != nil)
        #expect(manager.sessionForTesting(id: "unique") != nil)
        #expect(manager.sessionForTesting(id: firstID) === firstSession, "the first session must be the same, un-clobbered object")
        #expect(manager.sessionForTesting(id: firstID)?.isActive == true)
        #expect(manager.sessionForTesting(id: secondID)?.isActive == true)
    }
}
