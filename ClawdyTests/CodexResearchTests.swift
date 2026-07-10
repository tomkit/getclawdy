//
//  CodexResearchTests.swift
//  ClawdyTests
//
//  Codex research parity (Stage 3, v1 = single-turn execute, no plan/clarify). Mirrors
//  the Claude research tests for the Codex path:
//    1. Pure `CodexResearchArguments` vectors (execute: workspace-write + --add-dir +
//       web_search config + stdin; resume-follow-up: `exec resume <thread_id>`).
//    2. Pure `CodexResearchStreamParser` mapping into the shared `ResearchStreamLine`
//       vocabulary (thread.started / web_search / file_change / agent_message; unknown
//       lines ignored gracefully).
//    3. Capability flags + the immediate-proceed plan phase.
//    4. A single-turn EXECUTE lifecycle driven by a FAKE codex binary that emits the
//       codex event shapes and writes report.html, asserting the deliverable is produced
//       and the run completes.
//    5. Engine-by-kind selection through the real manager (Codex selected →
//       CodexResearchEngine + the codex binary), and the manifest tagged `codex`.
//
//  The Claude research path is untouched and its tests stay green.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - 1. Argument vectors (exact command lines)

struct CodexResearchArgumentsTests {

    @Test func executeArgumentsUseWorkspaceWriteScopedDirAndWebSearchAndStdin() {
        let args = CodexResearchArguments.makeExecuteArguments(outputDirectoryPath: "/tmp/run-1")

        #expect(args.first == "exec")
        // Runs in a workspace-write sandbox (NOT read-only) so it can Write report.html.
        let sandboxIndex = args.firstIndex(of: "-s")!
        #expect(args[sandboxIndex + 1] == "workspace-write")
        // Working root + writable grant both scoped to the per-run dir.
        let workingDirIndex = args.firstIndex(of: "-C")!
        #expect(args[workingDirIndex + 1] == "/tmp/run-1")
        let addDirIndex = args.firstIndex(of: "--add-dir")!
        #expect(args[addDirIndex + 1] == "/tmp/run-1")
        // The real web_search tool is enabled via a config override.
        let configIndex = args.firstIndex(of: "-c")!
        #expect(args[configIndex + 1] == "tools.web_search=true")
        // JSONL event stream + prompt on stdin (trailing "-").
        #expect(args.contains("--json"))
        #expect(args.last == "-")
        #expect(args.contains("--skip-git-repo-check"))
    }

    @Test func resumeFollowUpArgumentsContinueTheThreadWithNoReSandbox() {
        let args = CodexResearchArguments.makeResumeFollowUpArguments(threadID: "codex-thread-9")

        // `codex exec resume <thread_id> --json -`
        #expect(args[0] == "exec")
        #expect(args[1] == "resume")
        #expect(args[2] == "codex-thread-9")
        #expect(args.contains("--json"))
        #expect(args.last == "-")
        // A resumed turn INHERITS the first turn's sandbox / cwd — those flags must NOT
        // be re-specified (the CLI rejects them on resume).
        #expect(args.contains("-s") == false)
        #expect(args.contains("-C") == false)
        #expect(args.contains("--add-dir") == false)
    }
}

// MARK: - 2. Stream parsing → shared ResearchStreamLine

struct CodexResearchStreamMappingTests {

    @Test func mapsThreadStartedToSessionInitWithTheThreadID() {
        let line = #"{"type":"thread.started","thread_id":"codex-thread-1"}"#
        #expect(CodexResearchStreamParser.parse(line: line) == .sessionStarted(sessionID: "codex-thread-1"))
    }

    @Test func mapsCompletedWebSearchToASearchingProgressEvent() {
        let line = #"{"type":"item.completed","item":{"type":"web_search","query":"best standing desks 2026"}}"#
        #expect(CodexResearchStreamParser.parse(line: line) == .progress(.searchingWeb(query: "best standing desks 2026")))
    }

    @Test func webSearchWithNoQueryDegradesToAnEmptyQuery() {
        let line = #"{"type":"item.completed","item":{"type":"web_search"}}"#
        #expect(CodexResearchStreamParser.parse(line: line) == .progress(.searchingWeb(query: "")))
    }

    @Test func mapsFileChangeToWritingThePage() {
        let line = #"{"type":"file_change","kind":"add","path":"/tmp/run/report.html"}"#
        #expect(CodexResearchStreamParser.parse(line: line) == .progress(.writingPage))
    }

    @Test func mapsCompletedAgentMessageToTheTerminalResultText() {
        let line = #"{"type":"item.completed","item":{"type":"agent_message","text":"done, wrote the page"}}"#
        #expect(CodexResearchStreamParser.parse(line: line) == .result(text: "done, wrote the page", isError: false))
    }

    @Test func ignoresTurnCompletedAndBlankAndUnknownLinesGracefully() {
        // turn.completed carries usage but no routing text — the process exit is the done
        // signal, so it maps to nothing (and must not clobber captured agent text).
        #expect(CodexResearchStreamParser.parse(line: #"{"type":"turn.completed","usage":{}}"#) == .ignored)
        #expect(CodexResearchStreamParser.parse(line: #"{"type":"turn.started"}"#) == .ignored)
        #expect(CodexResearchStreamParser.parse(line: #"{"type":"item.started","item":{"type":"web_search"}}"#) == .ignored)
        #expect(CodexResearchStreamParser.parse(line: "") == .ignored)
        #expect(CodexResearchStreamParser.parse(line: "not json") == .ignored)
        // An unknown item type inside item.completed is ignored, not a crash.
        #expect(CodexResearchStreamParser.parse(line: #"{"type":"item.completed","item":{"type":"reasoning"}}"#) == .ignored)
    }
}

// MARK: - 3. Capabilities + immediate-proceed plan phase

struct CodexResearchEngineCapabilityTests {

    @Test func codexResearchEngineConformsWithBothCapabilitiesFalse() {
        let engine: ResearchEngine = CodexResearchEngine(binaryPath: "/usr/bin/true")
        #expect(engine.supportsPreMintedSessionID == false)
        #expect(engine.supportsPlanPhase == false)
    }

    @Test func planPhaseReturnsReadyToExecuteImmediatelyWithoutLaunchingAnything() async throws {
        // Point at a binary that would FAIL if it were ever launched — the plan phase must
        // not launch anything, so this still returns readyToExecute with the passed id.
        let engine = CodexResearchEngine(binaryPath: "/nonexistent/codex-should-not-run")
        let planResult = try await engine.runPlanPhase(
            task: "research desks",
            sessionID: "client-run-1",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            onProgress: { _ in }
        )
        #expect(planResult.sessionID == "client-run-1")
        #expect(planResult.outcome == .readyToExecute)
    }
}

// MARK: - 4. Single-turn execute lifecycle against a fake codex binary

/// A fake `codex` binary that emits the codex `--json` event shapes for a single execute
/// turn and WRITES report.html to the absolute path embedded in the stdin prompt (falling
/// back to `<-C dir>/report.html`). It reads the prompt from stdin (the trailing `-`)
/// exactly as the real CLI does, and:
///   - records the RECEIVED stdin prompt to `<-C dir>/received_prompt.txt` so a test can
///     prove the research TASK reached Codex's stdin (BLOCKING 1);
///   - when `emitThreadStarted`, emits `thread.started` (the resume handle) AND (when
///     `writeRollout`) writes a `~/.codex/sessions/.../rollout-*-<thread_id>.jsonl`
///     transcript under $HOME so the late transcript-path resolution can find it (MINOR 4);
///   - when NOT `emitThreadStarted`, omits the event (models a drift where the deliverable
///     is still produced but no follow-up handle is captured — MINOR 3).
private func makeFakeCodexBinary(emitThreadStarted: Bool = true, writeRollout: Bool = true) throws -> String {
    let threadStarted = #"{"type":"thread.started","thread_id":"codex-thread-1"}"#
    let turnStarted = #"{"type":"turn.started"}"#
    let webSearch = #"{"type":"item.completed","item":{"type":"web_search","query":"aomori photos"}}"#
    let fileChange = #"{"type":"file_change","kind":"add"}"#
    let agentMessage = #"{"type":"item.completed","item":{"type":"agent_message","text":"done, wrote the page"}}"#
    let turnCompleted = #"{"type":"turn.completed","usage":{}}"#

    let threadStartedLine = emitThreadStarted ? "emit '\(threadStarted)'" : "# thread.started omitted"
    let rolloutLine = (emitThreadStarted && writeRollout) ? """
        rolloutdir="$HOME/.codex/sessions/2026/07/09"
        mkdir -p "$rolloutdir"
        printf '{"thread_id":"codex-thread-1"}\\n' > "$rolloutdir/rollout-2026-07-09T00-00-00-codex-thread-1.jsonl"
    """ : "# rollout omitted"

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    cdir=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        -C) cdir="$a" ;;
      esac
      prev="$a"
    done
    prompt=$(cat)
    printf '%s' "$prompt" > "$cdir/received_prompt.txt"
    \(threadStartedLine)
    emit '\(turnStarted)'
    emit '\(webSearch)'
    outpath=$(printf '%s' "$prompt" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
    if [ -z "$outpath" ]; then outpath="$cdir/report.html"; fi
    printf '<!doctype html><html><body><h1>codex report</h1></body></html>' > "$outpath"
    emit '\(fileChange)'
    emit '\(agentMessage)'
    emit '\(turnCompleted)'
    \(rolloutLine)
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// A fake `codex` that emits `thread.started` (the resume handle) and then HANGS,
/// modelling a run that starts a thread and is later killed by the execute timeout. It
/// lets the test prove the thread id is persisted the instant it's ingested — before the
/// hung run is terminated and `runExecutePhase` throws `timedOut`.
private func makeThreadStartedThenHangCodexBinary() throws -> String {
    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    prompt=$(cat)
    emit '{"type":"thread.started","thread_id":"codex-thread-1"}'
    # Hang well past the (short) execute timeout so the run is terminated and throws
    # AFTER thread.started was already emitted and ingested.
    sleep 30
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// A unique fake $HOME so the fake's `~/.codex/sessions/...` rollout write is isolated.
private func makeFakeCodexHome() throws -> String {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home.path
}

/// Creates an isolated per-run output directory under a unique temp Application Support
/// base, via the Codex engine's own (protocol) directory strategy.
private func makeCodexScratchOutputDirectory(engine: CodexResearchEngine, runID: String) throws -> URL {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-appsupport-\(UUID().uuidString)", isDirectory: true)
    return try engine.makeSessionOutputDirectory(
        sessionID: runID,
        applicationSupportDirectory: temporaryApplicationSupport
    )
}

// MARK: - Task folding into the execute prompt (BLOCKING 1)

struct CodexResearchExecutePromptTests {

    @Test func executePromptContainsTheRequestedTaskAlongsideTheOutputConstraints() {
        let prompt = CodexResearchEngine.composeExecutePrompt(
            task: "compare the three best standing desks under $1000",
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: nil
        )
        // The task Codex must research is present…
        #expect(prompt.contains("compare the three best standing desks under $1000"),
                "Codex must be told WHAT to research")
        // …alongside the report.html-writing constraint.
        #expect(prompt.contains("/tmp/run/report.html"))
        #expect(prompt.lowercased().contains("self-contained") || prompt.contains("inline <style>"))
    }
}

struct CodexResearchExecuteLifecycleTests {

    @Test func executePhaseResearchesWritesTheDeliverableAndCompletes() async throws {
        let codexBinary = try makeFakeCodexBinary()
        let engine = CodexResearchEngine(
            binaryPath: codexBinary,
            homeDirectoryPath: try makeFakeCodexHome(),
            executePhaseTimeoutSeconds: 60
        )
        let outputDirectory = try makeCodexScratchOutputDirectory(engine: engine, runID: "client-run-1")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        // v1: plan is an immediate proceed (and it must persist the task).
        let planResult = try await engine.runPlanPhase(
            task: "find photos of aomori and build a gallery",
            sessionID: "client-run-1",
            outputDirectory: outputDirectory,
            onProgress: { _ in }
        )
        #expect(planResult.outcome == .readyToExecute)

        var sawSearching = false
        var sawWriting = false
        let deliverableURL = try await engine.runExecutePhase(
            sessionID: planResult.sessionID,
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { event in
                if case .searchingWeb = event { sawSearching = true }
                if event == .writingPage { sawWriting = true }
            }
        )

        #expect(deliverableURL.lastPathComponent == "report.html")
        #expect(FileManager.default.fileExists(atPath: deliverableURL.path) == true)
        let html = try String(contentsOf: deliverableURL, encoding: .utf8)
        #expect(html.contains("<h1>codex report</h1>"))
        // The stream drove the coarse progress events the overlay consumes.
        #expect(sawSearching == true, "the web_search event must surface a searching-web progress event")
        #expect(sawWriting == true, "the file_change event must surface a writing-page progress event")

        // BLOCKING 1: the research TASK actually reached Codex's stdin prompt end-to-end.
        let receivedPrompt = try String(
            contentsOf: outputDirectory.appendingPathComponent("received_prompt.txt"),
            encoding: .utf8
        )
        #expect(receivedPrompt.contains("find photos of aomori and build a gallery"),
                "the research task must be folded into the codex stdin prompt")

        // MINOR 3: a captured thread_id makes the run FOLLOWABLE.
        #expect(engine.canResumeForFollowUp == true)

        // MINOR 4: after capturing the thread_id, the transcript path resolves to the
        // rollout file the run wrote under $HOME/.codex/sessions.
        let resolvedTranscript = engine.transcriptPath(sessionID: "client-run-1", outputDirectory: outputDirectory)
        #expect(resolvedTranscript?.hasSuffix("rollout-2026-07-09T00-00-00-codex-thread-1.jsonl") == true,
                "the codex transcript path must resolve to the rollout file once the thread_id is known")
    }

    /// MINOR 3: when the execute turn produces a deliverable but NO thread_id (a
    /// missing/drifted `thread.started`), the deliverable still works but the engine reports
    /// NON-followable, so no Send that would fail is offered.
    @Test func executeWithoutAThreadIDProducesTheDeliverableButIsNotFollowable() async throws {
        let codexBinary = try makeFakeCodexBinary(emitThreadStarted: false)
        let engine = CodexResearchEngine(
            binaryPath: codexBinary,
            homeDirectoryPath: try makeFakeCodexHome(),
            executePhaseTimeoutSeconds: 60
        )
        let outputDirectory = try makeCodexScratchOutputDirectory(engine: engine, runID: "client-run-2")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        _ = try await engine.runPlanPhase(task: "t", sessionID: "client-run-2", outputDirectory: outputDirectory, onProgress: { _ in })
        let deliverableURL = try await engine.runExecutePhase(
            sessionID: "client-run-2",
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { _ in }
        )
        // Deliverable/results still work…
        #expect(FileManager.default.fileExists(atPath: deliverableURL.path) == true)
        // …but the run is non-followable (no resume handle) and a follow-up throws.
        #expect(engine.canResumeForFollowUp == false)
        #expect(engine.transcriptPath(sessionID: "client-run-2", outputDirectory: outputDirectory) == nil)

        var followUpError: Error?
        do {
            _ = try await engine.runFollowUpPhase(
                sessionID: "client-run-2",
                outputDirectory: outputDirectory,
                followUpPrompt: "make it blue",
                onProgress: { _ in }
            )
        } catch {
            followUpError = error
        }
        guard case CodexResearchEngine.ResearchError.noThreadIDForFollowUp? = followUpError else {
            Issue.record("expected noThreadIDForFollowUp, got: \(String(describing: followUpError))")
            return
        }
    }
}

// MARK: - A queued follow-up on a now-non-followable completed Codex run is discarded

/// A fake `codex` that BLOCKS its execute turn until the test drops a `go` file into the
/// run's `-C` output directory, so a follow-up can be QUEUED while the run is still
/// executing. It then writes report.html and completes normally but DELIBERATELY never
/// emits `thread.started` — so the finished run is non-followable (no resume handle),
/// exactly the drift the drain guard must handle.
private func makeGatedNonFollowableCodexBinary() throws -> String {
    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    cdir=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        -C) cdir="$a" ;;
      esac
      prev="$a"
    done
    prompt=$(cat)
    emit '{"type":"turn.started"}'
    # Block until the test releases the gate, so a follow-up can be queued behind this
    # still-in-flight execute turn (session state == .executing).
    while [ ! -f "$cdir/go" ]; do sleep 0.05; done
    outpath=$(printf '%s' "$prompt" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
    if [ -z "$outpath" ]; then outpath="$cdir/report.html"; fi
    printf '<!doctype html><html><body><h1>codex report</h1></body></html>' > "$outpath"
    emit '{"type":"file_change","kind":"add"}'
    emit '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
    emit '{"type":"turn.completed","usage":{}}'
    # Deliberately NO thread.started → the finished run is NON-followable.
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

@MainActor
struct CodexResearchFollowUpDrainTests {

    /// A follow-up accepted (queued) while a Codex run is executing must NOT be started once
    /// the run COMPLETES WITHOUT a captured thread_id: the finished session is non-followable,
    /// so draining it would launch a doomed resume that fails with `noThreadIDForFollowUp`.
    /// The drain must re-check acceptance and discard the queued follow-up cleanly instead —
    /// leaving the completed run's good deliverable intact.
    @Test func aQueuedFollowUpOnANonFollowableCompletedCodexRunIsDiscardedNotStarted() async throws {
        let codexBinary = try makeGatedNonFollowableCodexBinary()
        let fixedSessionID = "codex-drain-guard-1"

        let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-drain-appsupport-\(UUID().uuidString)", isDirectory: true)
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-drain-manifest-\(UUID().uuidString).json")

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { nil },
            resolveResearchEngineSelection: { ResearchEngineSelection(kind: .codex, binaryPath: codexBinary) },
            makeEngine: { _, path in
                CodexResearchEngine(
                    binaryPath: path,
                    homeDirectoryPath: NSTemporaryDirectory(),
                    executePhaseTimeoutSeconds: 60
                )
            },
            generateSessionID: { fixedSessionID },
            applicationSupportDirectory: temporaryApplicationSupport,
            homeDirectoryPath: NSTemporaryDirectory(),
            manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "find photos and build a page")
        let session = manager.sessionForTesting(id: sessionID)!

        // Wait until the run is EXECUTING (the fake is blocked on the gate) so the follow-up
        // is genuinely ACCEPTED-and-QUEUED behind an in-flight turn, not refused up front.
        try await pollUntilCodex(timeoutSeconds: 20, "the codex run to reach executing") {
            session.state == .executing
        }

        let accepted = session.followUp(prompt: "make the header blue")
        #expect(accepted, "a follow-up during execute is accepted and queued behind the in-flight turn")
        #expect(session.queuedFollowUpCountForTesting == 1, "the follow-up is queued, not run concurrently")
        #expect(session.followUpTurnsStartedCountForTesting == 0, "no follow-up turn has started yet")

        // Release the gate: the execute turn writes the deliverable and completes WITHOUT a
        // thread_id, so the finished session is non-followable and the drain fires.
        let outputDirectory = ClaudeResearchEngine.sessionOutputDirectory(
            sessionID: fixedSessionID,
            applicationSupportDirectory: temporaryApplicationSupport
        )
        try Data().write(to: outputDirectory.appendingPathComponent("go"))

        try await pollUntilCodex(timeoutSeconds: 20, "the codex run to complete") {
            session.state == .completed
        }

        // The queued follow-up was DISCARDED by the drain's re-check — never started (so no
        // `noThreadIDForFollowUp` throw), and the completed run keeps its good deliverable.
        #expect(session.queuedFollowUpCountForTesting == 0, "the doomed follow-up must be discarded, not left queued")
        #expect(session.followUpTurnsStartedCountForTesting == 0, "no follow-up turn is started on a non-followable completed run")
        #expect(session.state == .completed, "the completed run must NOT be downgraded by a discarded follow-up")
        #expect(session.isFollowUpTurnRunningForTesting == false)
    }
}

// MARK: - Transcript glob (MINOR 4)

struct CodexResearchTranscriptGlobTests {

    @Test func codexTranscriptPathFindsTheRolloutFileByThreadID() throws {
        let sessionsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-sessions-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let base = sessionsDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }

        // A rollout for the target thread plus an unrelated one that must NOT match.
        let target = sessionsDir.appendingPathComponent("rollout-2026-07-09T01-02-03-codex-thread-7.jsonl")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try "{}".write(to: sessionsDir.appendingPathComponent("rollout-2026-07-09T01-02-03-other-thread.jsonl"), atomically: true, encoding: .utf8)

        // Compare by the rollout filename suffix (the enumerator resolves the macOS
        // /var → /private/var symlink, so an exact absolute-path compare is brittle).
        let found = CodexResearchEngine.codexTranscriptPath(forThreadID: "codex-thread-7", sessionsDirectory: base)
        #expect(found?.hasSuffix("2026/07/09/rollout-2026-07-09T01-02-03-codex-thread-7.jsonl") == true)

        // A thread with no rollout resolves to nil (the "or nil until resolvable" contract).
        #expect(CodexResearchEngine.codexTranscriptPath(forThreadID: "nope", sessionsDirectory: base) == nil)
        // A missing sessions dir is also nil, not a crash.
        #expect(CodexResearchEngine.codexTranscriptPath(
            forThreadID: "codex-thread-7",
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent/codex/sessions")
        ) == nil)
    }
}

// MARK: - Stage A: thread_id recovery from a stored transcript path

struct CodexResearchThreadIDRecoveryTests {

    /// The FALLBACK recovery for pre-persistence runs: the Codex `thread_id` is extracted
    /// from a `rollout-<timestamp>-<thread_id>.jsonl` transcript path. The timestamp is
    /// anchored precisely so a thread id that itself contains hyphens (a UUID, or the test
    /// fixtures' `codex-thread-7`) is recovered whole.
    @Test func recoversThreadIDFromAValidRolloutTranscriptPath() {
        // A hyphenated (UUID-shaped) thread id is recovered in full.
        #expect(CodexResearchEngine.threadID(
            fromTranscriptPath: "/Users/x/.codex/sessions/2026/07/09/rollout-2026-07-09T01-02-03-0199f0a2-1b2c-4d5e-8f90-abcdef012345.jsonl"
        ) == "0199f0a2-1b2c-4d5e-8f90-abcdef012345")

        // The exact fixture the fake codex binary writes.
        #expect(CodexResearchEngine.threadID(
            fromTranscriptPath: "/home/.codex/sessions/2026/07/09/rollout-2026-07-09T00-00-00-codex-thread-1.jsonl"
        ) == "codex-thread-1")

        // A bare filename (no directory) works too — matching is on the last path component.
        #expect(CodexResearchEngine.threadID(
            fromTranscriptPath: "rollout-2025-05-14T12-34-56-codex-thread-7.jsonl"
        ) == "codex-thread-7")
    }

    /// Malformed / non-rollout paths recover nil rather than a garbage id.
    @Test func recoveryReturnsNilForMalformedOrNonRolloutPaths() {
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: "") == nil)
        // A Claude transcript (`<id>.jsonl`, no rollout prefix) must NOT match.
        #expect(CodexResearchEngine.threadID(
            fromTranscriptPath: "/home/.claude/projects/-wd/44f7cc5d-16b2-4efd-b41a.jsonl"
        ) == nil)
        // Right prefix/extension but no timestamp segment → nil.
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: "rollout-not-a-timestamp.jsonl") == nil)
        // Rollout with a timestamp but no trailing thread id → nil.
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: "rollout-2026-07-09T00-00-00.jsonl") == nil)
        // Wrong extension → nil.
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: "rollout-2026-07-09T00-00-00-codex-thread-1.txt") == nil)
    }

    /// A recovered id round-trips with `codexTranscriptPath`: build a path for a known id,
    /// then recover the SAME id back from it.
    @Test func recoveryIsTheInverseOfTheRolloutFilenameConvention() {
        let path = "/x/.codex/sessions/2026/07/09/rollout-2026-07-09T09-08-07-codex-thread-42.jsonl"
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: path) == "codex-thread-42")
    }
}

// MARK: - Stage A: the execute turn PERSISTS the captured thread_id to the manifest

struct CodexResearchThreadIDPersistenceTests {

    /// The root cause fix: the Codex `thread_id` the execute turn captures is written to the
    /// run's manifest entry (not just held in memory), keyed by the client run id. Drive the
    /// real execute turn against the fake codex binary with an injected temp manifest store,
    /// and assert the entry gained `codexThreadId`.
    @Test func executeTurnPersistsTheCapturedThreadIDToTheManifest() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-threadid-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let manifestStore = ResearchManifestStore(fileURL: temporaryManifestURL)

        // Index the run the way the session does at start (status .running, no thread id yet).
        manifestStore.recordResearchSessionStarted(
            sessionId: "client-run-1", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: "", engineKind: .codex
        )
        #expect(manifestStore.loadSessions().first { $0.sessionId == "client-run-1" }?.codexThreadId == nil)

        let codexBinary = try makeFakeCodexBinary()
        let engine = CodexResearchEngine(
            binaryPath: codexBinary,
            homeDirectoryPath: try makeFakeCodexHome(),
            executePhaseTimeoutSeconds: 60,
            manifestStore: manifestStore
        )
        let outputDirectory = try makeCodexScratchOutputDirectory(engine: engine, runID: "client-run-1")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        _ = try await engine.runPlanPhase(task: "t", sessionID: "client-run-1", outputDirectory: outputDirectory, onProgress: { _ in })
        _ = try await engine.runExecutePhase(
            sessionID: "client-run-1",
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { _ in }
        )

        // The fake emits `thread.started` with `codex-thread-1` — it must now be persisted.
        let entry = manifestStore.loadSessions().first { $0.sessionId == "client-run-1" }
        #expect(entry?.codexThreadId == "codex-thread-1",
                "the execute turn must persist the captured Codex thread id to the manifest")
    }

    /// THE BLOCKING FIX: a run that emits `thread.started` and then TIMES OUT (so
    /// `runExecutePhase` THROWS instead of returning) must STILL have persisted the thread
    /// id — the resume handle survives the partial-run case this stage exists for. Uses a
    /// fake codex that emits thread.started then hangs past a short execute timeout.
    @Test func aThreadIDCapturedBeforeATimeoutIsStillPersistedWhenTheRunThrows() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-timeout-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let manifestStore = ResearchManifestStore(fileURL: temporaryManifestURL)
        manifestStore.recordResearchSessionStarted(
            sessionId: "client-run-timeout", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: "", engineKind: .codex
        )

        let codexBinary = try makeThreadStartedThenHangCodexBinary()
        let engine = CodexResearchEngine(
            binaryPath: codexBinary,
            homeDirectoryPath: try makeFakeCodexHome(),
            // A SHORT timeout so the hung fake is terminated and the run throws timedOut.
            executePhaseTimeoutSeconds: 2,
            manifestStore: manifestStore
        )
        let outputDirectory = try makeCodexScratchOutputDirectory(engine: engine, runID: "client-run-timeout")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        _ = try await engine.runPlanPhase(task: "t", sessionID: "client-run-timeout", outputDirectory: outputDirectory, onProgress: { _ in })

        // The run THROWS (timed out) — the persist must have already happened during ingestion.
        var runError: Error?
        do {
            _ = try await engine.runExecutePhase(
                sessionID: "client-run-timeout",
                outputDirectory: outputDirectory,
                clarificationAnswers: nil,
                onProgress: { _ in }
            )
        } catch {
            runError = error
        }
        #expect(runError != nil, "a run that hangs past its timeout must throw")

        let entry = manifestStore.loadSessions().first { $0.sessionId == "client-run-timeout" }
        #expect(entry?.codexThreadId == "codex-thread-1",
                "a thread id captured before a timeout must survive the throw as a persisted resume handle")
        // In-memory capture is likewise set, so the engine reports the run as followable.
        #expect(engine.canResumeForFollowUp == true)
    }

    /// When the execute turn produces a deliverable but NO thread id (a drifted/missing
    /// `thread.started`), nothing is persisted — `codexThreadId` stays nil.
    @Test func executeWithoutAThreadIDPersistsNoThreadID() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-nothreadid-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let manifestStore = ResearchManifestStore(fileURL: temporaryManifestURL)
        manifestStore.recordResearchSessionStarted(
            sessionId: "client-run-2", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: "", engineKind: .codex
        )

        let codexBinary = try makeFakeCodexBinary(emitThreadStarted: false)
        let engine = CodexResearchEngine(
            binaryPath: codexBinary,
            homeDirectoryPath: try makeFakeCodexHome(),
            executePhaseTimeoutSeconds: 60,
            manifestStore: manifestStore
        )
        let outputDirectory = try makeCodexScratchOutputDirectory(engine: engine, runID: "client-run-2")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        _ = try await engine.runPlanPhase(task: "t", sessionID: "client-run-2", outputDirectory: outputDirectory, onProgress: { _ in })
        _ = try await engine.runExecutePhase(
            sessionID: "client-run-2",
            outputDirectory: outputDirectory,
            clarificationAnswers: nil,
            onProgress: { _ in }
        )

        #expect(manifestStore.loadSessions().first { $0.sessionId == "client-run-2" }?.codexThreadId == nil,
                "no thread id captured → nothing persisted")
    }
}

// MARK: - Stage C: a finished Codex run is reconstructable ONLY with a resume handle

@MainActor
struct CodexResearchReconstructionTests {

    /// A completed CODEX run that captured NO thread_id (and whose transcript path yields
    /// none) is NOT reconstructable: there is no resume handle for `codex exec resume`, so
    /// offering it would attempt a resume with nothing to continue. Claude + legacy (nil)
    /// entries stay reconstructable regardless. (The WITH-thread_id case is covered by
    /// `CodexResearchReconstructionResumeTests` in ResearchFollowUpTests.)
    @Test func aCompletedCodexRunWithoutAThreadIDIsNotReconstructable() throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-reconstruct-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let store = ResearchManifestStore(fileURL: temporaryManifestURL)

        // A completed Codex run with NO thread id + empty transcript path (no resume handle),
        // and a completed Claude run, both with deliverables.
        store.recordResearchSessionStarted(
            sessionId: "codex-done", title: "t", task: "x",
            workingDir: "/wd/codex", transcriptPath: "", engineKind: .codex
        )
        store.recordResearchSessionOutcome(sessionId: "codex-done", status: .completed, deliverablePath: "/wd/codex/report.html")
        store.recordResearchSessionStarted(
            sessionId: "claude-done", title: "t", task: "x",
            workingDir: "/wd/claude", transcriptPath: "/tp/claude.jsonl", engineKind: .claudeCode
        )
        store.recordResearchSessionOutcome(sessionId: "claude-done", status: .completed, deliverablePath: "/wd/claude/report.html")

        // A manager that CAN resolve a codex binary — so the ONLY thing blocking the Codex
        // run's reconstruction is the missing resume handle, not a missing binary.
        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { "/usr/bin/true" },
            resolveResearchBinaryPath: { _ in "/usr/bin/true" },
            manifestStore: store,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        // The Codex entry has no resume handle → not reconstructable, and a follow-up is
        // refused rather than starting a resume with no thread.
        #expect(manager.canReconstructFinishedSession(forSessionID: "codex-done") == false,
                "a completed Codex run with no thread_id must not be reconstructable")
        #expect(manager.followUpOnSession(id: "codex-done", prompt: "hi") == false,
                "a follow-up on a thread-less finished Codex run must be refused")
        // …while the Claude entry stays reconstructable, and legacy (nil) too.
        #expect(manager.canReconstructFinishedSession(forSessionID: "claude-done") == true)

        // The pure engine-kind gate now ACCEPTS Codex (thread-id availability is enforced
        // separately by `canReconstructFinishedSession`): Claude, legacy (nil), and Codex
        // are all supported engine kinds for reconstruction.
        #expect(ResearchSessionManager.isReconstructableEngineKind(CoachEngineKind.claudeCode.rawValue) == true)
        #expect(ResearchSessionManager.isReconstructableEngineKind(nil) == true)
        #expect(ResearchSessionManager.isReconstructableEngineKind(CoachEngineKind.codex.rawValue) == true)
    }

    /// The pure resume-handle resolver, exercised directly (no manager): Claude resumes by
    /// its own session id; a Codex run resumes by its persisted `codexThreadId`; a
    /// pre-persistence Codex run recovers the id from its rollout transcript path; a Codex
    /// run with neither has no handle.
    @Test func resumeHandleResolvesPerEngineAndFallsBackToTheTranscriptPath() {
        func entry(engineKind: CoachEngineKind?, sessionId: String, transcriptPath: String, codexThreadId: String?) -> ResearchManifestEntry {
            ResearchManifestEntry(
                sessionId: sessionId, kind: .research, title: "t", task: "x",
                status: .completed, createdAt: Date(), updatedAt: Date(),
                workingDir: "/wd", transcriptPath: transcriptPath, deliverablePath: "/wd/report.html",
                engineKind: engineKind?.rawValue, codexThreadId: codexThreadId
            )
        }

        // Claude → the session id itself.
        #expect(ResearchSessionManager.resumeHandle(for:
            entry(engineKind: .claudeCode, sessionId: "claude-sess", transcriptPath: "/tp/claude.jsonl", codexThreadId: nil)) == "claude-sess")
        // Legacy (nil engineKind) is treated as Claude → the session id.
        #expect(ResearchSessionManager.resumeHandle(for:
            entry(engineKind: nil, sessionId: "legacy-sess", transcriptPath: "", codexThreadId: nil)) == "legacy-sess")
        // Codex with a persisted thread id → that thread id.
        #expect(ResearchSessionManager.resumeHandle(for:
            entry(engineKind: .codex, sessionId: "codex-run", transcriptPath: "", codexThreadId: "codex-thread-42")) == "codex-thread-42")
        // Codex with NO persisted thread id but a rollout transcript path → recovered id.
        #expect(ResearchSessionManager.resumeHandle(for:
            entry(engineKind: .codex, sessionId: "codex-run", transcriptPath: "/x/rollout-2026-07-09T00-00-00-recovered-thread.jsonl", codexThreadId: nil)) == "recovered-thread")
        // Codex with neither → no handle.
        #expect(ResearchSessionManager.resumeHandle(for:
            entry(engineKind: .codex, sessionId: "codex-run", transcriptPath: "", codexThreadId: nil)) == nil)
    }
}

// MARK: - 5. Engine-by-kind selection through the real manager + manifest tag

private final class MonotonicCodexSessionIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        nextIndex += 1
        return "codex-run-\(nextIndex)"
    }
}

@MainActor
struct CodexResearchManagerSelectionTests {

    /// When the selected coach engine is Codex, the manager resolves the CODEX binary and
    /// builds a `CodexResearchEngine` (proven by capturing the (kind, path) the makeEngine
    /// factory is called with). This is the engine-by-kind selection seam.
    @Test func codexSelectedResolvesCodexEngineAndBinary() async throws {
        let codexBinary = try makeFakeCodexBinary()
        let capturedSelection = CapturedSelectionBox()
        let idGenerator = MonotonicCodexSessionIDGenerator()

        let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-mgr-appsupport-\(UUID().uuidString)", isDirectory: true)
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-mgr-manifest-\(UUID().uuidString).json")
        let manifestStore = ResearchManifestStore(fileURL: temporaryManifestURL)

        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { nil },
            resolveResearchEngineSelection: { ResearchEngineSelection(kind: .codex, binaryPath: codexBinary) },
            makeEngine: { kind, path in
                capturedSelection.record(kind: kind, path: path)
                return CodexResearchEngine(
                    binaryPath: path,
                    homeDirectoryPath: NSTemporaryDirectory(),
                    executePhaseTimeoutSeconds: 60
                )
            },
            generateSessionID: { idGenerator.next() },
            applicationSupportDirectory: temporaryApplicationSupport,
            homeDirectoryPath: NSTemporaryDirectory(),
            manifestStore: manifestStore,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "find photos of aomori and build a gallery")

        // The engine factory was called for the CODEX kind with the codex binary.
        #expect(capturedSelection.kind == .codex, "Codex selected must build a Codex engine")
        #expect(capturedSelection.path == codexBinary, "Codex selected must use the codex binary")

        // The single-turn run completes and produces the deliverable.
        try await pollUntilCodex(timeoutSeconds: 20, "the codex session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        #expect(manager.sessionForTesting(id: sessionID)?.state == .completed)

        // The manifest entry is tagged with the Codex engine kind.
        let entry = manifestStore.loadSessions().first { $0.sessionId == sessionID }
        #expect(entry?.engineKind == CoachEngineKind.codex.rawValue, "a Codex run must be tagged codex in the manifest")
        #expect(entry?.status == .completed)
        #expect(entry?.deliverablePath != nil)
    }
}

/// Thread-safe capture of the (kind, path) the injected makeEngine factory was called
/// with, so a test can prove the by-kind selection without introspecting the engine type.
private final class CapturedSelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _kind: CoachEngineKind?
    private var _path: String?
    func record(kind: CoachEngineKind, path: String) {
        lock.lock(); _kind = kind; _path = path; lock.unlock()
    }
    var kind: CoachEngineKind? { lock.lock(); defer { lock.unlock() }; return _kind }
    var path: String? { lock.lock(); defer { lock.unlock() }; return _path }
}

private func pollUntilCodex(
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
