//
//  ResearchFollowUpTests.swift
//  ClawdyTests
//
//  SLICE C — voice-native FOLLOW-UP + LINEAGE. Proves, against a REAL per-session
//  `claude` process (a fake binary that models the verified 2.1.198 behavior), that:
//    1. a FOCUSED research session's utterance routes to that session's own
//       `followUp(...)` thread — NOT into a brand-new session (`startSession`);
//    2. with NO focus, the manager does NOT route a follow-up (the warm quick-answer
//       / new-research path stays in charge);
//    3. two rapid follow-ups on one session SERIALIZE (FIFO queue) — never a
//       concurrent `--resume` on the single `<id>.jsonl`;
//    4. opening a completed report FOCUSES its session (lineage bind);
//    5. a follow-up that REWRITES report.html reports a rewrite (drives the view
//       reload) while a pure QUESTION writes nothing;
//    6. the concise reply is routed to the spoken-answer callback.
//
//  Pure argument/decision helpers are asserted separately (no process launched).
//

import Testing
import Foundation
import AppKit
@testable import Clawdy

// MARK: - Fake research `claude` binary with follow-up modeling

/// The session id the fake always echoes and keys its per-CWD marker by, passed as the
/// pre-minted `--session-id` so the minted id and the echoed id agree (as the real CLI
/// echoes `--session-id` verbatim).
private let followUpFakeSessionID = "sess-followup-1"

/// A fake `claude` that supports the full plan → execute → FOLLOW-UP lifecycle:
///   - plan   (`--permission-mode plan`, no `--resume`): persists a per-CWD session
///     marker and emits a "proceeding" result (or clarify on NEEDS_CLARIFY),
///   - resume (`--resume <id>`): if the marker is absent, fails like the real CLI;
///     otherwise it inspects the `-p` USER MESSAGE (the channel that survives resume):
///       * if it contains `ITERATE_WRITE`, it writes report.html to the absolute path
///         embedded in the message and confirms (an ITERATE follow-up / initial
///         execute), then sleeps briefly so the mtime provably advances,
///       * if it contains `QUESTION_ONLY`, it writes NOTHING and just answers (a pure
///         question follow-up),
///       * otherwise (the initial execute's default "proceed" message) it writes
///         report.html — the normal deliverable path.
///     A `HANGRESUME` message execs `sleep` so a resume turn can be held in flight.
private func makeFollowUpFakeClaudeBinary() throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-followup-1"}"#
    let proceedResult = #"{"type":"result","result":"here is the plan, proceeding now","is_error":false}"#
    let executeResult = #"{"type":"result","result":"done, wrote report.html","is_error":false}"#
    let iterateResult = #"{"type":"result","result":"i updated the section you asked about","is_error":false}"#
    let questionResult = #"{"type":"result","result":"the fastest desk raises in about nine seconds.","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    task=""
    resume=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        -p) task="$a" ;;
        --resume) resume="$a" ;;
      esac
      prev="$a"
    done
    emit '\(initLine)'
    case "$task" in
      *HANGRESUME*) exec sleep 600 ;;
    esac
    if [ -z "$resume" ]; then
      case "$task" in
        *INITIALFAIL*)
          # The INITIAL run fails at the plan phase (never produces a deliverable) —
          # this run is genuinely `.failed` and MUST record `.failed`, proving the
          # follow-up fix didn't over-correct the initial-failure path.
          emit "{\\"type\\":\\"result\\",\\"result\\":\\"initial plan failure\\",\\"is_error\\":true}"
          echo "initial failure" 1>&2
          exit 1 ;;
      esac
      echo "plan" > "session-\(followUpFakeSessionID).marker"
      emit '\(proceedResult)'
    else
      if [ ! -f "session-$resume.marker" ]; then
        emit "{\\"type\\":\\"result\\",\\"result\\":\\"No conversation found with session ID: $resume\\",\\"is_error\\":true}"
        echo "No conversation found with session ID: $resume" 1>&2
        exit 1
      fi
      outpath=$(printf '%s' "$task" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
      case "$task" in
        *FAILRESUME*)
          # A resume turn that FAILS transiently (a network blip / non-zero exit) even
          # though the marker exists — writes NOTHING and exits non-zero so the engine
          # throws `phaseFailed`. Used to prove a follow-up failure never downgrades a
          # completed session.
          emit "{\\"type\\":\\"result\\",\\"result\\":\\"transient network error\\",\\"is_error\\":true}"
          echo "transient failure" 1>&2
          exit 1 ;;
        *QUESTION_ONLY*)
          emit '\(questionResult)' ;;
        *ITERATE_WRITE*)
          if [ -n "$outpath" ]; then printf '<!doctype html><html><body><h1>iterated</h1></body></html>' > "$outpath"; fi
          # brief pause so the rewrite's mtime provably advances past the prior write
          sleep 1
          emit '\(iterateResult)' ;;
        *)
          if [ -n "$outpath" ]; then printf '<!doctype html><html><body><h1>report</h1></body></html>' > "$outpath"; fi
          emit '\(executeResult)' ;;
      esac
    fi
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}


/// Distinct monotonic ids EXCEPT the first, which is aligned to the fake's marker so
/// the first session actually resumes and completes.
private final class FollowUpSessionIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String]
    private var nextIndex = 0
    init(_ scripted: [String]) { self.scripted = scripted }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        if !scripted.isEmpty { return scripted.removeFirst() }
        nextIndex += 1
        return "sess-followup-extra-\(nextIndex)"
    }
}

@MainActor
private func makeFollowUpManager(
    binaryPath: String,
    firstSessionID: String = followUpFakeSessionID
) -> ResearchSessionManager {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("followup-appsupport-\(UUID().uuidString)", isDirectory: true)
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("followup-manifest-\(UUID().uuidString).json")
    let idGenerator = FollowUpSessionIDGenerator([firstSessionID])
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
        generateSessionID: idGenerator.next,
        applicationSupportDirectory: temporaryApplicationSupport,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

private func pollUntilFollowUp(
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

// MARK: - Pure decision / reply helpers (no process)

struct ResearchFollowUpPureTests {

    /// The follow-up user message leads with the SPOKEN follow-up verbatim (so the
    /// model answers exactly what was said) and folds in the "only edit if asked" +
    /// absolute-path constraints.
    @Test func followUpUserMessageLeadsWithTheSpokenPromptAndScopesEdits() {
        let message = ClaudeResearchEngine.composeFollowUpUserMessage(
            spokenFollowUp: "which of these desks is the quietest?",
            outputFileAbsolutePath: "/tmp/run/report.html"
        )
        #expect(message.hasPrefix("which of these desks is the quietest?"))
        #expect(message.contains("/tmp/run/report.html"))
        #expect(message.lowercased().contains("only modify the page if"))
        #expect(message.lowercased().contains("answer"))
    }

    /// The follow-up turn reuses the EXACT execute-phase arg vector (resume + narrow
    /// allowlist + scoped dir + budget; never `--bare`) — only message/system-prompt
    /// differ. We assert the vector the engine hands the runner is the execute one.
    @Test func followUpUsesTheExecutePhaseArgVector() {
        let args = ResearchArguments.makeExecuteArguments(
            sessionID: "sess-9",
            outputDirectoryPath: "/tmp/run",
            maxBudgetUSD: 5,
            userMessage: ClaudeResearchEngine.composeFollowUpUserMessage(
                spokenFollowUp: "tell me more",
                outputFileAbsolutePath: "/tmp/run/report.html"
            ),
            systemPrompt: ClaudeResearchEngine.followUpSystemPrompt,
            useClaudeCustomizations: true
        )
        #expect(args.contains("--resume"))
        #expect(args[args.firstIndex(of: "--resume")! + 1] == "sess-9")
        #expect(args.contains("acceptEdits"))
        #expect(args.contains("WebSearch"))
        #expect(args.contains("WebFetch"))
        #expect(args.contains("Write"))
        #expect(args.contains("--add-dir"))
        #expect(args[args.firstIndex(of: "--add-dir")! + 1] == "/tmp/run")
        #expect(args[args.firstIndex(of: "--max-budget-usd")! + 1] == "5")
        #expect(args.contains("--bare") == false)
        #expect(args.contains("bypassPermissions") == false)
    }

    /// The executor prompt instructs "only modify if asked; otherwise just answer".
    @Test func followUpSystemPromptOnlyEditsWhenAsked() {
        let prompt = ClaudeResearchEngine.followUpSystemPrompt.lowercased()
        #expect(prompt.contains("only modify the page if"))
        #expect(prompt.contains("answer"))
        #expect(prompt.contains("report.html"))
    }

    /// Rewrite detection from report.html's modification date: newly created or an
    /// advanced mtime → rewritten; unchanged or absent → not (a pure question).
    @Test func rewriteDetectionFromModificationDate() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        // Newly created this turn.
        #expect(ClaudeResearchEngine.deliverableWasRewritten(modificationDateBeforeTurn: nil, modificationDateAfterTurn: later) == true)
        // Advanced mtime (an in-place iterate replaced the inode).
        #expect(ClaudeResearchEngine.deliverableWasRewritten(modificationDateBeforeTurn: earlier, modificationDateAfterTurn: later) == true)
        // Unchanged (a pure question wrote nothing).
        #expect(ClaudeResearchEngine.deliverableWasRewritten(modificationDateBeforeTurn: earlier, modificationDateAfterTurn: earlier) == false)
        // File absent after (nothing to reload).
        #expect(ClaudeResearchEngine.deliverableWasRewritten(modificationDateBeforeTurn: earlier, modificationDateAfterTurn: nil) == false)
    }

    /// The spoken reply is a short fixed confirmation for an iterate (don't read the
    /// edit narration), and the model's own answer for a pure question.
    @Test func spokenReplyIsConfirmationForIterateAndAnswerForQuestion() {
        #expect(ResearchSession.followUpSpokenReply(modelAnswer: "i rewrote the whole comparison table and …", deliverableWasRewritten: true) == "Updated the page.")
        #expect(ResearchSession.followUpSpokenReply(modelAnswer: "it raises in nine seconds.", deliverableWasRewritten: false) == "it raises in nine seconds.")
        #expect(ResearchSession.followUpSpokenReply(modelAnswer: nil, deliverableWasRewritten: false) == "")
    }

    // MARK: - BLOCKING #1 — [FOLLOWUP] directive parsing + TTS suppression

    /// A `[FOLLOWUP]` directive is the ENTIRE reply and carries the restatement.
    @Test func parsesAFollowUpDirectiveAtTheStartOfTheReply() {
        let result = FollowUpDirective.parse(from: "[FOLLOWUP] make the page background darker")
        #expect(result.isFollowUpRequest == true)
        #expect(result.promptText == "make the page background darker")
    }

    /// A pointing/quick answer (with a POINT tag, or plain speech) is NOT a follow-up
    /// directive — so it stays a normal spoken/POINT answer even mid-sentence mentions.
    @Test func aPointingOrQuickAnswerIsNotAFollowUpDirective() {
        let pointing = FollowUpDirective.parse(from: "hit the blue submit button. [POINT:640,720:submit button]")
        #expect(pointing.isFollowUpRequest == false)
        #expect(pointing.promptText == nil)
        let midSentence = FollowUpDirective.parse(from: "i could do a [FOLLOWUP] but let's chat first.")
        #expect(midSentence.isFollowUpRequest == false)
    }

    /// The streaming pipeline suppresses TTS while the reply could still become a
    /// `[FOLLOWUP]` marker (so it's never spoken), and resumes for ordinary speech.
    @Test func suppressesTTSWhileTheStreamedTextCouldBecomeAFollowUpMarker() {
        #expect(FollowUpDirective.looksLikeFollowUpPrefix("[") == true)
        #expect(FollowUpDirective.looksLikeFollowUpPrefix("[FOLL") == true)
        #expect(FollowUpDirective.looksLikeFollowUpPrefix("[FOLLOWUP]") == true)
        #expect(FollowUpDirective.looksLikeFollowUpPrefix("[FOLLOWUP] darken it") == true)
        #expect(FollowUpDirective.looksLikeFollowUpPrefix("ah, gotcha.") == false)
    }
}

// MARK: - Routing + queue + lineage + refresh (real per-session process)

@MainActor
struct ResearchFollowUpRoutingTests {

    /// Drives a manager's first session all the way to `.completed` and returns it.
    private func startAndCompleteFirstSession(
        _ manager: ResearchSessionManager
    ) async throws -> ResearchSessionID {
        let sessionID = manager.startSession(taskDescription: "research desks and build a page")
        try await pollUntilFollowUp(timeoutSeconds: 20, "first session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        return sessionID
    }

    /// (1) A FOCUSED session's utterance routes to THAT session's `followUp` — the
    /// follow-up turn count increments and NO new session is spawned. FAILS BEFORE
    /// the slice: with no follow-up path, `followUpOnFocusedSession` wouldn't exist /
    /// would spawn or drop, and `followUpTurnsStartedCount` would stay 0.
    @Test func focusedUtteranceRoutesToFollowUpNotANewSession() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        let sessionCountBefore = manager.activeSessionCountForTesting

        // Focus it (as opening its report does) and speak a follow-up.
        manager.focus(id: sessionID)
        let routed = manager.followUpOnFocusedSession(prompt: "QUESTION_ONLY how fast does the top pick raise?")
        #expect(routed == true, "a focused utterance must route to the focused session")

        try await pollUntilFollowUp(timeoutSeconds: 20, "the follow-up turn to finish") {
            manager.sessionForTesting(id: sessionID)?.isFollowUpTurnRunningForTesting == false &&
            (manager.sessionForTesting(id: sessionID)?.followUpTurnsStartedCountForTesting ?? 0) >= 1
        }
        #expect(manager.sessionForTesting(id: sessionID)?.followUpTurnsStartedCountForTesting == 1,
                "the utterance ran as a follow-up on THIS session")
        #expect(manager.activeSessionCountForTesting == sessionCountBefore,
                "a follow-up must NOT spawn a new session")
        #expect(manager.sessionForTesting(id: sessionID)?.state == .completed)
    }

    /// (2) With NO focus, the manager does NOT route a follow-up — `false` is returned
    /// so `CompanionManager` falls through to the unchanged warm quick-answer /
    /// new-research path. No session runs a follow-up turn.
    @Test func unfocusedUtteranceDoesNotRouteToFollowUp() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.clearFocus()
        #expect(manager.focusedSessionID == nil)

        let routed = manager.followUpOnFocusedSession(prompt: "QUESTION_ONLY anything")
        #expect(routed == false, "with no focus, the follow-up path must NOT claim the utterance")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(manager.sessionForTesting(id: sessionID)?.followUpTurnsStartedCountForTesting == 0,
                "no follow-up turn runs when nothing is focused")
    }

    /// (3) Two rapid follow-ups on one session SERIALIZE via the FIFO queue: the first
    /// runs, the second ENQUEUES (never a concurrent `--resume`), then drains. FAILS
    /// BEFORE the slice: without the queue, both would launch concurrent resume turns
    /// on the one `<id>.jsonl`.
    @Test func twoRapidFollowUpsSerializeThroughThePerSessionQueue() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        // Fire two follow-ups back-to-back. The first must HANG (held in flight) so the
        // second provably has to queue rather than run concurrently.
        session.followUp(prompt: "HANGRESUME first follow-up")
        session.followUp(prompt: "QUESTION_ONLY second follow-up")

        // Synchronously after both calls: exactly one turn running, one queued — NOT
        // two concurrent resume turns.
        #expect(session.isFollowUpTurnRunningForTesting == true, "the first follow-up is in flight")
        #expect(session.queuedFollowUpCountForTesting == 1, "the second follow-up is queued, not concurrently resumed")
        #expect(session.followUpTurnsStartedCountForTesting == 1, "only one follow-up turn has started so far")

        // Let the first (hanging) turn keep running; the second must NOT have started.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(session.followUpTurnsStartedCountForTesting == 1, "the queued turn must not start while the first is in flight")
        #expect(session.queuedFollowUpCountForTesting == 1)

        // Stop the session to release the hung resume; the queue is abandoned (no
        // orphaned concurrent turn). (A stop clears the queue and cancels the process.)
        manager.stopSession(id: sessionID)
        #expect(session.queuedFollowUpCountForTesting == 0, "stopping abandons the queued follow-up — no orphaned resume")
    }

    /// (3b) When the first follow-up completes normally, the queued second one DRAINS
    /// (runs next) — proving one-at-a-time progress, not permanent stalling.
    @Test func aQueuedFollowUpDrainsAfterThePriorOneCompletes() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        // Two quick question follow-ups: both complete, serialized.
        session.followUp(prompt: "QUESTION_ONLY first")
        session.followUp(prompt: "QUESTION_ONLY second")
        #expect(session.queuedFollowUpCountForTesting == 1)

        try await pollUntilFollowUp(timeoutSeconds: 20, "both follow-ups to run") {
            session.followUpTurnsStartedCountForTesting == 2 &&
            session.queuedFollowUpCountForTesting == 0 &&
            session.isFollowUpTurnRunningForTesting == false
        }
        #expect(session.followUpTurnsStartedCountForTesting == 2, "the queued follow-up drained and ran")
        #expect(session.state == .completed)
    }

    /// (4) LINEAGE: tapping a completed pill opens its results AND focuses the session,
    /// so the next utterance continues that thread. FAILS BEFORE: `.done` tap opened
    /// results without focusing, so a follow-up couldn't be routed.
    @Test func openingResultsFocusesTheSessionForLineage() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        #expect(manager.focusedSessionID == nil, "not focused until the report is opened")

        // Simulate the .done pill tap through the real manager tap path.
        manager.handleCompactTapForTesting(id: sessionID)
        #expect(manager.focusedSessionID == sessionID, "opening a completed report focuses its session")

        // And there's a clear deselect path (the detail close → clearFocus).
        manager.clearFocus()
        #expect(manager.focusedSessionID == nil, "deselect returns to the fresh quick-answer / new-run path")
    }

    /// (5) A follow-up that REWRITES report.html triggers a view refresh; a pure
    /// QUESTION writes nothing → no refresh. Also checks the deliverable's content was
    /// replaced on iterate. FAILS BEFORE: no refresh hook existed.
    @Test func aFollowUpThatRewritesTheReportRefreshesTheViewAQuestionDoesNot() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        // A pure question — no rewrite, no refresh.
        session.followUp(prompt: "QUESTION_ONLY how tall does it go?")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the question follow-up to finish") {
            session.followUpTurnsStartedCountForTesting == 1 && session.isFollowUpTurnRunningForTesting == false
        }
        #expect(session.followUpViewRefreshCountForTesting == 0, "a pure question must not refresh the view")

        // An iterate — rewrites report.html, so the view refresh is requested.
        session.followUp(prompt: "ITERATE_WRITE please add a summary section")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the iterate follow-up to finish") {
            session.followUpTurnsStartedCountForTesting == 2 && session.isFollowUpTurnRunningForTesting == false
        }
        #expect(session.followUpViewRefreshCountForTesting == 1, "an iterate rewrite must request a view reload")
    }

    /// (6) The concise follow-up reply is routed to the spoken-answer callback the
    /// manager forwards to TTS: a question speaks the model's answer; an iterate speaks
    /// a short confirmation.
    @Test func theFollowUpReplyIsRoutedToTheSpokenAnswerCallback() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        // Capture spoken replies the way CompanionManager's TTS would receive them.
        let spokenBox = SpokenReplyBox()
        manager.onFollowUpSpokenAnswer = { reply in spokenBox.append(reply) }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        session.followUp(prompt: "QUESTION_ONLY how fast does the top pick raise?")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the question reply to be spoken") {
            spokenBox.count >= 1
        }
        #expect(spokenBox.last == "the fastest desk raises in about nine seconds.",
                "a question speaks the model's own concise answer")

        session.followUp(prompt: "ITERATE_WRITE add a summary")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the iterate confirmation to be spoken") {
            spokenBox.count >= 2
        }
        #expect(spokenBox.last == "Updated the page.", "an iterate speaks a short confirmation")
    }

    // MARK: - BLOCKING #1 — focused sessions must NOT swallow POINT (real routing)

    /// THE fix (BLOCKING #1): the real `CompanionManager.routeWarmReply` decision.
    /// A focused session must STILL emit POINT for a pointing question — pointing is
    /// ALWAYS a quick POINT answer, NEVER routed to a follow-up. FAILS BEFORE the fix,
    /// which hard short-circuited on `focusedSessionID != nil` before the warm/POINT
    /// path, so a focused "where do i click" was swallowed into the research thread.
    @Test func focusedPointingQuestionRoutesToPointNotFollowUp() {
        // A pointing reply (the warm agent emits POINT, never a directive) while a
        // research session is focused → the normal speak/POINT path, NOT a follow-up.
        let pointingReply = "click the blue submit button at the bottom. [POINT:640,720:submit button]"
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: pointingReply, isResearchSessionFocused: true)
                == .speakOrPoint,
            "a focused pointing question must POINT, never route to follow-up"
        )
        // A plain quick answer while focused is also NOT a follow-up.
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "the capital of japan is tokyo. [POINT:none]", isResearchSessionFocused: true)
                == .speakOrPoint
        )
    }

    /// POINT WINS, ALWAYS (B1 residual): a model-disobedient MIXED reply that both
    /// begins with a directive AND carries a [POINT:...] tag must STILL fire the blue
    /// cursor — pointing is unconditional, regardless of the [FOLLOWUP]/[RESEARCH]
    /// prefix or focus. FAILS BEFORE the precedence fix (prefix was checked first, so
    /// the [FOLLOWUP]-prefixed reply routed to .followUpFocusedSession and never
    /// pointed).
    @Test func focusedMixedFollowUpWithPointStillRoutesToPoint() {
        // [FOLLOWUP] + a POINT tag, while focused → POINT still wins.
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "[FOLLOWUP] click the submit button [POINT:640,720:submit button]",
                isResearchSessionFocused: true
            ) == .speakOrPoint,
            "a [FOLLOWUP]+POINT mixed reply must POINT, never route to follow-up"
        )
        // [RESEARCH] + a POINT tag, focused or not → POINT still wins.
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "[RESEARCH] compare desks [POINT:100,200:desk]",
                isResearchSessionFocused: true
            ) == .speakOrPoint,
            "a [RESEARCH]+POINT mixed reply must POINT, never route to research"
        )
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "[RESEARCH] compare desks [POINT:100,200:desk]",
                isResearchSessionFocused: false
            ) == .speakOrPoint,
            "unfocused mixed [RESEARCH]+POINT must POINT too"
        )
        // Sanity: a directive with NO point tag still routes as before.
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "[FOLLOWUP] darken it", isResearchSessionFocused: true)
                == .followUpFocusedSession
        )
    }

    /// Focused + a genuine continuation directive routes to the focused session's
    /// thread; focused + a brand-new go-gather ask still spawns a new research run.
    @Test func focusedContinuationRoutesToFollowUpAndNewTopicStartsResearch() {
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "[FOLLOWUP] darken the page background", isResearchSessionFocused: true)
                == .followUpFocusedSession
        )
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "[RESEARCH] find hotels in kyoto and build a page", isResearchSessionFocused: true)
                == .newResearch(task: "find hotels in kyoto and build a page")
        )
    }

    /// Unfocused behavior is UNCHANGED: a `[FOLLOWUP]`-looking reply never routes to a
    /// follow-up with nothing focused (we only honor it under focus), a POINT stays a
    /// POINT, and a `[RESEARCH]` still spawns a new run.
    @Test func unfocusedRoutingIsUnchanged() {
        // No session focused → a stray [FOLLOWUP] is never a follow-up route.
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "[FOLLOWUP] whatever", isResearchSessionFocused: false)
                == .speakOrPoint
        )
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "click here. [POINT:10,10:x]", isResearchSessionFocused: false)
                == .speakOrPoint
        )
        #expect(
            CompanionManager.routeWarmReply(fullResponseText: "[RESEARCH] compare standing desks", isResearchSessionFocused: false)
                == .newResearch(task: "compare standing desks")
        )
    }

    // MARK: - BLOCKING #2 — a stopped-but-focused session can't launch a new resume

    /// THE fix (BLOCKING #2): stopping a focused session CLEARS focus, and a stopped
    /// session REFUSES a follow-up — so it can never start a second concurrent
    /// `--resume` on the same session id. FAILS BEFORE: `stopSession` left focus set
    /// and `followUp` only checked engine/dir, so a stopped-yet-focused session was
    /// still voice-reachable to launch a new resume while its cancelled child drained.
    @Test func stoppingAFocusedSessionClearsFocusAndRefusesFollowUp() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        #expect(manager.focusedSessionID == sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        // Stop it (the manager path). Focus must clear so the UI deselects it.
        manager.stopSession(id: sessionID)
        #expect(session.state == .stopped)
        #expect(manager.focusedSessionID == nil, "stopping a focused session must clear focus (deselect)")

        // Even if a follow-up is attempted directly on the stopped session, it must be
        // REFUSED — no second concurrent resume turn starts.
        session.followUp(prompt: "QUESTION_ONLY are you still there?")
        #expect(session.followUpTurnsStartedCountForTesting == 0, "a stopped session must refuse a follow-up")
        #expect(session.queuedFollowUpCountForTesting == 0, "a stopped session must not even queue a follow-up")

        // And routing via the manager is a no-op now that focus is cleared.
        let routed = manager.followUpOnFocusedSession(prompt: "QUESTION_ONLY hello")
        #expect(routed == false, "with focus cleared there is nothing to follow up")
        #expect(session.followUpTurnsStartedCountForTesting == 0)
    }

    /// The pill's own Stop control calls `ResearchSession.stop()` DIRECTLY (bypassing
    /// `stopSession(id:)`); the central lifecycle handler must still clear focus, so
    /// that path can't leave a stopped session focused + follow-up-reachable either.
    @Test func theStopControlPathAlsoClearsFocusForAFocusedSession() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        #expect(manager.focusedSessionID == sessionID)

        // Simulate the pill's Stop button: it calls the session's stop() directly.
        manager.sessionForTesting(id: sessionID)!.stop()
        #expect(manager.focusedSessionID == nil, "the direct Stop path must clear focus via the lifecycle handler")
    }
}

// MARK: - FRONTMOST-WINDOW follow-up routing (the reported bug's fix)
//
// The bug: while VIEWING a research results window (embedded WKWebView) and speaking
// feedback about that page, Clawdy started a NEW research run instead of continuing
// the EXISTING session that produced the page. Root cause: routing keyed on the
// ephemeral `focusedSessionID`, which the History-open path never sets and ordinary
// interactions clear. The fix keys on the FRONTMOST results window's bound session id
// (`ResearchResultsWindowRegistry`) and routes via `followUpOnSession(id:)`, which
// reconstructs a non-live (e.g. History-opened) session from the manifest so its
// existing claude thread is resumed rather than a fresh run spawned.

/// Seeds a manifest with a COMPLETED research entry (as if a past run finished and the
/// app moved on / relaunched) and returns a manager wired to that SAME store — without
/// running any live session first. Lets the History (not-live) reconstruction path be
/// exercised deterministically and with no plan/execute process.
@MainActor
private func makeManagerWithSeededCompletedSession(
    sessionID: String,
    binaryPath: String
) -> ResearchSessionManager {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("frontmost-appsupport-\(UUID().uuidString)", isDirectory: true)
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("frontmost-manifest-\(UUID().uuidString).json")
    let manifestStore = ResearchManifestStore(fileURL: temporaryManifestURL)

    // The stable per-session working dir the completed run used (created so a resume
    // has a valid CWD; the deliverable file itself need not exist for routing).
    let workingDirectory = temporaryApplicationSupport
        .appendingPathComponent("Clawdy/research/\(sessionID)", isDirectory: true)
    try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let deliverablePath = workingDirectory.appendingPathComponent("report.html").path
    let transcriptPath = workingDirectory.appendingPathComponent("transcript.jsonl").path

    manifestStore.recordResearchSessionStarted(
        sessionId: sessionID,
        title: "Standing desks",
        task: "compare standing desks and build a page",
        workingDir: workingDirectory.path,
        transcriptPath: transcriptPath
    )
    manifestStore.recordResearchSessionOutcome(
        sessionId: sessionID,
        status: .completed,
        deliverablePath: deliverablePath
    )

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
        generateSessionID: { UUID().uuidString.lowercased() },
        applicationSupportDirectory: temporaryApplicationSupport,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: manifestStore,
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

/// Serialized because several tests mutate the app-wide `ResearchResultsWindowRegistry.shared`
/// singleton (bindings + the injected window-order provider) and reset it in a defer;
/// running them in parallel would let one test's reset clear another's binding across an
/// `await`, masking real regressions.
@Suite(.serialized)
@MainActor
struct ResearchFrontmostFollowUpTests {

    /// The pure frontmost-wins rule the routing keys on: the session bound to the
    /// FRONTMOST results window is chosen, an unbound (non-results) window in front of
    /// it is skipped, and nothing resolves when no results window is on screen. This is
    /// what makes the follow-up target independent of transient click focus.
    @Test func frontmostResultsWindowSessionResolvesRegardlessOfOtherWindows() {
        let bindings = [101: "sess-A", 202: "sess-B"]
        // A non-results window (id 999, unbound) is frontmost, then the results window
        // for sess-B, then sess-A → the frontmost REGISTERED results window wins.
        #expect(
            ResearchResultsWindowRegistry.frontmostSessionID(
                inFrontToBackWindowNumbers: [999, 202, 101],
                bindings: bindings
            ) == "sess-B"
        )
        // sess-A's window is frontmost of the registered ones.
        #expect(
            ResearchResultsWindowRegistry.frontmostSessionID(
                inFrontToBackWindowNumbers: [101, 202],
                bindings: bindings
            ) == "sess-A"
        )
        // No results window on screen → no follow-up target (unchanged behavior).
        #expect(
            ResearchResultsWindowRegistry.frontmostSessionID(
                inFrontToBackWindowNumbers: [999, 998],
                bindings: bindings
            ) == nil
        )
        #expect(
            ResearchResultsWindowRegistry.frontmostSessionID(
                inFrontToBackWindowNumbers: [],
                bindings: bindings
            ) == nil
        )
    }

    /// bind/unbind maintains the on-screen results-window → session map that
    /// `frontmostSessionID()` reads; an invalid window number is ignored.
    @Test func registryBindAndUnbindTrackTheOnScreenResultsWindow() {
        let registry = ResearchResultsWindowRegistry()
        registry.bind(windowNumber: 7, sessionID: "sess-live")
        #expect(registry.bindingsForTesting[7] == "sess-live")
        registry.bind(windowNumber: 0, sessionID: "sess-nope")
        #expect(registry.bindingsForTesting[0] == nil, "a not-yet-on-screen window number is ignored")
        registry.unbind(windowNumber: 7)
        #expect(registry.bindingsForTesting[7] == nil)
    }

    /// THE FIX (reported bug): a page opened from HISTORY — whose research session is no
    /// longer live (its pill auto-hid, or the app relaunched) — is still followed up on
    /// its OWN thread. When its bound session id routes here, the manager RECONSTRUCTS
    /// the session from the manifest and starts a follow-up (`--resume`) turn on it,
    /// rather than spawning a brand-new research run.
    ///
    /// FAILS BEFORE the fix: routing only knew `followUpOnFocusedSession`, which needs a
    /// LIVE, focused session in `sessionsByID`; a History-opened (non-live) session
    /// wasn't reachable, so the utterance fell through to a new run. `followUpOnSession`
    /// and the manifest-reconstruction path did not exist.
    ///
    /// Synchronous by design: the follow-up turn is STARTED synchronously (its Task then
    /// runs the resume off the main actor), so this asserts the routing decision without
    /// waiting on or spawning a real research process — keeping the suite fast + stable.
    @Test func historyOpenedNonLiveSessionReconstructsAndRoutesFollowUpNotANewRun() {
        let sessionID = "sess-history-\(UUID().uuidString.lowercased())"
        let manager = makeManagerWithSeededCompletedSession(sessionID: sessionID, binaryPath: "/usr/bin/true")
        defer { manager.stopAll() }

        // Nothing live yet — only the manifest knows this completed session.
        #expect(manager.activeSessionCountForTesting == 0)
        #expect(manager.sessionForTesting(id: sessionID) == nil)

        // The History-opened page is frontmost (its window is bound to this id), so a
        // spoken follow-up routes to THIS session id.
        let routed = manager.followUpOnSession(id: sessionID, prompt: "QUESTION_ONLY which is the quietest?")
        #expect(routed == true, "a History-opened page must resolve back to its session, not start a new run")

        // Reconstructed under the SAME id and a follow-up turn started — NOT a new run
        // (which would mint a different id and run plan/execute).
        let session = manager.sessionForTesting(id: sessionID)
        #expect(session != nil, "the non-live session was reconstructed from the manifest")
        #expect(session?.sessionID == sessionID)
        #expect(manager.activeSessionCountForTesting == 1, "exactly one session — reconstructed, not a brand-new run")
        #expect(session?.followUpTurnsStartedCountForTesting == 1, "the utterance ran as a follow-up on the reconstructed session")
        #expect(session?.state == .executing, "the reconstructed session is running its follow-up turn")

        // LIVE branch: a SECOND utterance now routes to the SAME (now live) session and
        // serializes behind the in-flight turn (per-session FIFO) — never a second
        // session or a concurrent `--resume` on the one transcript.
        let routedSecond = manager.followUpOnSession(id: sessionID, prompt: "QUESTION_ONLY and the cheapest?")
        #expect(routedSecond == true)
        #expect(manager.activeSessionCountForTesting == 1, "the live branch reuses the session — no new run")
        #expect(session?.queuedFollowUpCountForTesting == 1, "the second utterance queued behind the first — FIFO, no concurrent resume")
        #expect(session?.followUpTurnsStartedCountForTesting == 1, "still one turn started; the second is queued")
    }

    /// A follow-up to an UNKNOWN session (no live session and no completed manifest
    /// entry) does NOT route — the caller falls back to the unchanged warm quick-answer /
    /// new-research path. Guards the reconstruction path against fabricating a session
    /// that never existed.
    @Test func followUpToAnUnknownSessionDoesNotRoute() {
        let manager = makeManagerWithSeededCompletedSession(
            sessionID: "sess-known-\(UUID().uuidString.lowercased())",
            binaryPath: "/usr/bin/true"
        )
        defer { manager.stopAll() }

        let routed = manager.followUpOnSession(id: "sess-never-existed", prompt: "QUESTION_ONLY hi")
        #expect(routed == false, "an unknown session id must not route (nothing to reconstruct)")
        #expect(manager.activeSessionCountForTesting == 0)
    }

    /// POINT ALWAYS WINS while a results window is frontmost: a pointing reply must fire
    /// the blue cursor and NOT route to a follow-up, even though the frontmost results
    /// window makes a follow-up target available (`isResearchSessionFocused == true` is
    /// the "a follow-up target exists" input the production path derives from the
    /// frontmost window). POINT precedence runs before any FOLLOWUP/RESEARCH routing; a
    /// genuine `[FOLLOWUP]` continuation (no POINT) still routes.
    @Test func pointingQuestionWhileResultsWindowFrontmostStillPoints() {
        // Frontmost results window present (a target exists) + a pointing reply → POINT.
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "click the blue submit button. [POINT:640,720:submit button]",
                isResearchSessionFocused: true
            ) == .speakOrPoint,
            "a pointing question while viewing a page must POINT, never follow up"
        )
        // A model-disobedient [FOLLOWUP] that ALSO carries a POINT tag → POINT still wins.
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "[FOLLOWUP] darken it [POINT:100,100:bg]",
                isResearchSessionFocused: true
            ) == .speakOrPoint
        )
        // A genuine continuation (no POINT) while viewing the page → follow-up route.
        #expect(
            CompanionManager.routeWarmReply(
                fullResponseText: "[FOLLOWUP] darken the page background",
                isResearchSessionFocused: true
            ) == .followUpFocusedSession
        )
    }

    // MARK: - Cross-review item 5: no stale registry binding after removal / dealloc

    /// BLOCKING (b): when a session is REMOVED (its terminal auto-hide fires), its
    /// results window must be torn down so the `ResearchResultsWindowRegistry` binding
    /// is dropped — otherwise a dropped session stays frontmost-and-bound and a later
    /// utterance misroutes to a session that is neither live nor reconstructable.
    ///
    /// FAILS BEFORE the fix: `removeSession` dropped the session from `sessionsByID` but
    /// left its still-visible results window bound, so `frontmostSessionID()` kept
    /// returning the dead id. PASSES AFTER: `removeSession` calls `teardown()`, which
    /// hides the window and unregisters the binding.
    @Test func aRemovedSessionsResultsWindowNoLongerLeavesAStaleBinding() async throws {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        // Complete a run, then open its results window (binds the registry to it).
        let sessionID = manager.startSession(taskDescription: "research desks and build a page")
        try await pollUntilFollowUp(timeoutSeconds: 20, "session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        manager.sessionForTesting(id: sessionID)?.openResults()
        #expect(ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains(sessionID),
                "opening results binds the on-screen window to its session")

        // The session's terminal auto-hide removal fires (driven synchronously here).
        manager.removeSessionForTesting(id: sessionID)

        #expect(manager.sessionForTesting(id: sessionID) == nil, "the session is no longer live")
        #expect(ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains(sessionID) == false,
                "a removed session must not leave a stale results-window binding")
        #expect(ResearchResultsWindowRegistry.shared.frontmostSessionID() != sessionID,
                "the frontmost resolver can never surface the removed session")
    }

    /// BLOCKING (a): if a results-window controller is deallocated WITHOUT an explicit
    /// hide/close (e.g. its owning session is dropped), its `deinit` must still drop the
    /// registry binding. FAILS BEFORE the fix: there was no deinit, so the binding
    /// survived the controller and leaked a stale frontmost session.
    @Test func controllerDeinitDropsItsRegistryBinding() async throws {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        let reportURL = try makeTemporaryReportHTML()
        var controller: ResearchResultsWindowController? = ResearchResultsWindowController.offscreenForTesting()
        controller!.show(htmlFileURL: reportURL, title: "report", sessionID: "sess-deinit")
        #expect(ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains("sess-deinit"),
                "showing the window binds it to its session")

        // Retain the WINDOW across the controller's dealloc so it stays open and its
        // `windowWillClose` cleanup can NOT fire — isolating `deinit` as the only path
        // that can drop the binding (a genuine fail-before/pass-after for the deinit).
        let retainedWindow = controller!.windowForTesting
        #expect(retainedWindow != nil, "the shown window must exist so we can hold it open")

        // Release the controller WITHOUT hide()/close — deinit alone must clean up.
        controller = nil
        try await pollUntilFollowUp(timeoutSeconds: 5, "deinit to unregister the binding") {
            ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains("sess-deinit") == false
        }
        #expect(ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains("sess-deinit") == false,
                "deinit unregisters the binding on dealloc even while its window stays open")

        // Keep the window reference alive until the assertions above have run, so the
        // controller's dealloc (not the window closing) is what dropped the binding.
        _ = retainedWindow
    }

    // MARK: - Cross-review item 7: production follow-up-target precedence

    /// NON-BLOCKING (7): the PRODUCTION `CompanionManager.resolveFollowUpTargetSessionID()`
    /// prefers the FRONTMOST results window's session over a DIFFERENT focused session —
    /// the actual focus-override behavior (exercising the real registry + the real
    /// `focusedSessionID`, not just the pure selector). With no results window frontmost,
    /// it falls back to focus (unchanged behavior).
    @Test func frontmostResultsWindowSessionOverridesADifferentFocusedSession() {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        let companionManager = CompanionManager()
        // Anchor the lazily-created research manager's overlay off-screen BEFORE first
        // touching it below (its init calls refreshOverlay() → recentsBadge.show()).
        companionManager.researchTestAnchorOriginOffset = offscreenResearchAnchorOffset
        // A focused session (the ephemeral click-focus signal) DIFFERENT from the page
        // the user is actually looking at.
        companionManager.researchSessionManagerForTesting.setFocusedSessionIDForTesting("sess-focused")

        // A frontmost results window bound to a different session, injected so the real
        // resolver reads a deterministic front-to-back order.
        ResearchResultsWindowRegistry.shared.bind(windowNumber: 7, sessionID: "sess-frontmost")
        ResearchResultsWindowRegistry.shared.orderedWindowNumbersProvider = { [7] }

        #expect(companionManager.resolveFollowUpTargetSessionIDForTesting() == "sess-frontmost",
                "the frontmost results window's session must override the focused session")

        // No results window frontmost → fall back to the focused session (unchanged path).
        ResearchResultsWindowRegistry.shared.orderedWindowNumbersProvider = { [] }
        #expect(companionManager.resolveFollowUpTargetSessionIDForTesting() == "sess-focused",
                "with no frontmost results window, the focused session is the fallback")
    }
}

// MARK: - Overlay UX polish (double-open fix + dismiss-vs-stop), real per-session path

@MainActor
struct ResearchOverlayUXRealPathTests {

    /// Drives a manager's first session to `.completed` and returns its id.
    private func startAndCompleteFirstSession(
        _ manager: ResearchSessionManager
    ) async throws -> ResearchSessionID {
        let sessionID = manager.startSession(taskDescription: "research desks and build a page")
        try await pollUntilFollowUp(timeoutSeconds: 20, "first session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        return sessionID
    }

    /// The DONE default-click contract, real path: tapping a DONE pill opens the HISTORY
    /// window EXACTLY ONCE (the new default — the live results page is now reached via the
    /// dedicated "view results" button, not the card click), sets lineage focus so a spoken
    /// follow-up over the page routes to THIS thread, and must NOT open the results page NOR
    /// pop the detail/progress panel (that pairing was the double-open).
    ///
    /// The "History genuinely opened" side is proven OBSERVABLY: `openHistory(...)` bumps
    /// `openHistoryCallCountForTesting` and records `lastOpenedHistorySessionIDForTesting`.
    /// So exactly-one call for this id after the click proves the open fired once — if it
    /// were dropped from the done-click path, the count would be 0 and this FAILS.
    @Test func doneTapOpensHistoryExactlyOnceAndLineageFocusesWithoutResultsOrDetailPanel() async throws {
        ResearchResultsWindowRegistry.shared.resetForTesting()
        defer { ResearchResultsWindowRegistry.shared.resetForTesting() }

        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        #expect(manager.detailPanelVisibleForTesting == false)
        #expect(manager.openHistoryCallCountForTesting == 0,
                "History should not be open before the done click")

        manager.handleCompactTapForTesting(id: sessionID)

        // openHistory() genuinely fired EXACTLY ONCE for THIS session — the new default
        // click destination.
        #expect(manager.openHistoryCallCountForTesting == 1,
                "a done click must open the History window exactly once")
        #expect(manager.lastOpenedHistorySessionIDForTesting == sessionID,
                "History opened focused on the clicked session")
        // The results page is NOT opened by the default click (it lives behind the
        // dedicated "view results" button now).
        #expect(manager.sessionForTesting(id: sessionID)?.openResultsCallCountForTesting == 0,
                "a done default click must NOT open the results window")
        #expect(ResearchResultsWindowRegistry.shared.bindingsForTesting.values.contains(sessionID) == false,
                "no results window is bound by the default click")

        // Lineage focus is set (so a follow-up over the page routes to this thread)…
        #expect(manager.focusedSessionID == sessionID)
        // …but the detail/progress panel is NOT shown — exactly one window (History) opened.
        #expect(manager.detailPanelVisibleForTesting == false,
                "a done tap must not also open the detail panel (the double-open)")
    }

    /// ITEM 2 — DISMISS (×) is NOT stop. Dismissing a LIVE run's pill hides it from the
    /// overlay stack but leaves the run going (state unchanged, still tracked, still in
    /// flight). Stopping it, by contrast, cancels the run (`.stopped`). This proves the
    /// two intents are distinct.
    @Test func dismissingALiveRunHidesThePillButDoesNotStopIt() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        manager.focus(id: sessionID)
        let session = manager.sessionForTesting(id: sessionID)!

        // Put the session into a genuinely LIVE follow-up turn that hangs in flight.
        session.followUp(prompt: "HANGRESUME keep working")
        #expect(session.isFollowUpTurnRunningForTesting == true)
        #expect(session.state == .executing)
        #expect(manager.renderedPillCountForTesting == 1, "the live pill is on the stack")

        // DISMISS the pill — hide chrome only.
        manager.dismissSession(id: sessionID)

        // The pill is gone from the overlay, but the RUN is untouched: still live, still
        // tracked, NOT stopped.
        #expect(manager.renderedPillCountForTesting == 0, "dismiss removes the pill from the stack")
        #expect(manager.dismissedSessionIDsForTesting.contains(sessionID))
        #expect(manager.sessionForTesting(id: sessionID) != nil, "the session is still tracked")
        #expect(session.state == .executing, "dismiss must NOT cancel the run")
        #expect(session.isFollowUpTurnRunningForTesting == true, "the live turn keeps running after dismiss")

        // A dismissed focused session also drops focus (its detail panel closes).
        #expect(manager.focusedSessionID == nil)
    }

    /// The contrast: STOP genuinely cancels the run (`.stopped`) — the other side of the
    /// dismiss-vs-stop distinction.
    @Test func stoppingARunCancelsItUnlikeDismiss() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let manager = makeFollowUpManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteFirstSession(manager)
        let session = manager.sessionForTesting(id: sessionID)!

        manager.stopSession(id: sessionID)
        #expect(session.state == .stopped, "stop cancels the run")
        // Stop does not add the session to the dismissed set — a different mechanism.
        #expect(manager.dismissedSessionIDsForTesting.contains(sessionID) == false)
    }
}

/// Writes a tiny self-contained report.html to a unique temp dir so a results-window
/// controller has a real file:// URL to load.
private func makeTemporaryReportHTML() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("frontmost-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("report.html")
    try "<!doctype html><html><body><h1>report</h1></body></html>".write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

/// A tiny main-actor-agnostic sink so the spoken-answer closure (called on the main
/// actor) can be observed by the test without data races.
private final class SpokenReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []
    func append(_ reply: String) { lock.lock(); replies.append(reply); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
    var last: String? { lock.lock(); defer { lock.unlock() }; return replies.last }
}

// MARK: - FOLLOW-UP FAILURE must not downgrade a COMPLETED session (data-loss fix)
//
// A finished research run (`.completed`, a good on-disk report.html) that later takes a
// FOLLOW-UP turn which THROWS (a transient network blip, a budget/timeout, a CLI
// non-zero exit) must NOT be downgraded to `.failed`: doing so clobbered the good
// deliverable's durable state (red error pill, no "view results", every future
// follow-up refused, dimmed in History). The fix restores the terminal `.completed`
// state, writes NO manifest downgrade, keeps the run followable, and still surfaces the
// transient failure. These tests cover BOTH the voice and the typed follow-up entry
// points, and prove the INITIAL-run failure path still records `.failed` (no
// over-correction).

/// Builds a follow-up manager wired to a CALLER-OWNED manifest store + app-support dir,
/// so a test can assert the durable manifest entry directly (the shared
/// `makeFollowUpManager` hides its store).
@MainActor
private func makeFollowUpManagerWithInjectedStore(
    binaryPath: String,
    manifestStore: ResearchManifestStore,
    applicationSupportDirectory: URL,
    firstSessionID: String = followUpFakeSessionID
) -> ResearchSessionManager {
    let idGenerator = FollowUpSessionIDGenerator([firstSessionID])
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
        generateSessionID: idGenerator.next,
        applicationSupportDirectory: applicationSupportDirectory,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: manifestStore,
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

@MainActor
struct ResearchFollowUpFailureTests {

    /// A completed manager + injected store, driven to `.completed`. Returns the pieces a
    /// downgrade test needs: the session id, the live session, and the caller-owned store.
    private func makeCompletedSession() async throws -> (
        manager: ResearchSessionManager,
        store: ResearchManifestStore,
        sessionID: ResearchSessionID,
        session: ResearchSession
    ) {
        let binary = try makeFollowUpFakeClaudeBinary()
        let applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffail-appsupport-\(UUID().uuidString)", isDirectory: true)
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffail-manifest-\(UUID().uuidString).json")
        let store = ResearchManifestStore(fileURL: manifestURL)
        let manager = makeFollowUpManagerWithInjectedStore(
            binaryPath: binary,
            manifestStore: store,
            applicationSupportDirectory: applicationSupport
        )
        let sessionID = manager.startSession(taskDescription: "research desks and build a page")
        try await pollUntilFollowUp(timeoutSeconds: 20, "first session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        return (manager, store, sessionID, manager.sessionForTesting(id: sessionID)!)
    }

    /// A failing VOICE follow-up on a completed session must NOT downgrade it: the
    /// in-memory state stays `.completed`, the manifest entry stays `.completed` with its
    /// deliverablePath, the run stays reconstructable/followable, and a SUBSEQUENT
    /// follow-up is still accepted — while the transient failure is still surfaced.
    @Test func aFailingVoiceFollowUpKeepsACompletedSessionCompletedAndFollowable() async throws {
        let (manager, store, sessionID, session) = try await makeCompletedSession()
        defer { manager.stopAll() }

        // Baseline: the finished run is recorded `.completed` + a deliverable.
        let entryBefore = store.loadSessions().first { $0.sessionId == sessionID }
        #expect(entryBefore?.status == .completed)
        #expect(entryBefore?.deliverablePath != nil)
        let deliverablePathBefore = entryBefore?.deliverablePath

        // Surface signal: the transient-failure line routed to the spoken-answer callback.
        let spokenBox = SpokenReplyBox()
        manager.onFollowUpSpokenAnswer = { reply in spokenBox.append(reply) }

        // A VOICE follow-up that fails transiently on the completed session.
        manager.focus(id: sessionID)
        let routed = manager.followUpOnFocusedSession(prompt: "FAILRESUME transient blip")
        #expect(routed == true, "a focused completed session must accept the follow-up")

        try await pollUntilFollowUp(timeoutSeconds: 20, "the failing follow-up to settle") {
            session.isFollowUpTurnRunningForTesting == false &&
            session.followUpTurnsStartedCountForTesting >= 1
        }

        // In-memory state RESTORED to `.completed` (never `.failed`).
        #expect(session.state == .completed,
                "a transient follow-up failure must not downgrade a completed session")

        // Durable manifest UNCHANGED: still `.completed` with its deliverablePath.
        let entryAfter = store.loadSessions().first { $0.sessionId == sessionID }
        #expect(entryAfter?.status == .completed, "the durable manifest status must stay .completed")
        #expect(entryAfter?.deliverablePath == deliverablePathBefore,
                "the deliverable path must be preserved (no downgrade write)")

        // Still followable/reconstructable.
        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == true,
                "the run must stay reconstructable/followable after a transient failure")

        // The failure was SURFACED (not silently swallowed).
        #expect(spokenBox.last == ResearchSession.followUpTransientFailureSpokenMessage,
                "the transient follow-up failure must be surfaced to the user")

        // A SUBSEQUENT follow-up is still accepted and runs to completion.
        let secondRouted = session.followUp(prompt: "QUESTION_ONLY are you still here?")
        #expect(secondRouted == true, "a subsequent follow-up must still be accepted")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the recovery follow-up to finish") {
            session.followUpTurnsStartedCountForTesting == 2 &&
            session.isFollowUpTurnRunningForTesting == false
        }
        #expect(session.state == .completed)
    }

    /// The TYPED follow-up composer (`onSubmitFollowUp`) takes the SAME path, so a failing
    /// typed follow-up must also leave the completed session `.completed` + followable.
    @Test func aFailingTypedFollowUpAlsoKeepsACompletedSessionCompleted() async throws {
        let (manager, store, sessionID, session) = try await makeCompletedSession()
        defer { manager.stopAll() }

        let deliverablePathBefore = store.loadSessions().first { $0.sessionId == sessionID }?.deliverablePath
        #expect(deliverablePathBefore != nil)

        // The TYPED composer path: enqueue a failing follow-up through the view model's
        // submit closure (the same closure the chat composer is wired to).
        session.overlayViewModel.onSubmitFollowUp?("FAILRESUME typed blip")

        try await pollUntilFollowUp(timeoutSeconds: 20, "the typed failing follow-up to settle") {
            session.isFollowUpTurnRunningForTesting == false &&
            session.followUpTurnsStartedCountForTesting >= 1
        }

        #expect(session.state == .completed,
                "a failing typed follow-up must not downgrade a completed session")
        let entryAfter = store.loadSessions().first { $0.sessionId == sessionID }
        #expect(entryAfter?.status == .completed)
        #expect(entryAfter?.deliverablePath == deliverablePathBefore)
        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == true)
    }

    /// No over-correction: an INITIAL run failure (never produced a deliverable) STILL
    /// records `.failed`. Only a follow-up-on-completed failure is protected.
    @Test func anInitialRunFailureStillRecordsFailed() async throws {
        let binary = try makeFollowUpFakeClaudeBinary()
        let applicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffail-init-appsupport-\(UUID().uuidString)", isDirectory: true)
        let manifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffail-init-manifest-\(UUID().uuidString).json")
        let store = ResearchManifestStore(fileURL: manifestURL)
        let manager = makeFollowUpManagerWithInjectedStore(
            binaryPath: binary,
            manifestStore: store,
            applicationSupportDirectory: applicationSupport
        )
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "INITIALFAIL research desks")
        try await pollUntilFollowUp(timeoutSeconds: 20, "the initial run to fail") {
            manager.sessionForTesting(id: sessionID)?.state == .failed
        }
        #expect(manager.sessionForTesting(id: sessionID)?.state == .failed)

        // The initial-failure path DOES record `.failed` in the manifest (unchanged).
        let entry = store.loadSessions().first { $0.sessionId == sessionID }
        #expect(entry?.status == .failed, "an initial run that produced no deliverable must record .failed")
        #expect(entry?.deliverablePath == nil)
    }
}

// MARK: - Stage C: a FINISHED Codex run reconstructs + resumes via the Codex engine

/// A spy `ResearchEngine` that records the resume handle it was SEEDED with (via
/// `adoptResumeHandle`) and the follow-up turns it was asked to run, so a test can prove a
/// RECONSTRUCTED Codex session resumes through the Codex engine with the CORRECT thread id
/// — without launching a real `codex` process. It reports itself followable only once a
/// resume handle has been seeded, exactly as `CodexResearchEngine.canResumeForFollowUp`
/// (thread_id != nil) does. `@unchecked Sendable` + a lock because `runFollowUpPhase` runs
/// off the main actor while the test reads the recorded state.
private final class RecordingReconstructResearchEngine: ResearchEngine, @unchecked Sendable {
    let supportsPreMintedSessionID: Bool
    let supportsPlanPhase: Bool

    private let stateLock = NSLock()
    private var seededResumeHandleStorage: String?
    private var followUpPromptsStorage: [String] = []

    init(supportsPreMintedSessionID: Bool, supportsPlanPhase: Bool) {
        self.supportsPreMintedSessionID = supportsPreMintedSessionID
        self.supportsPlanPhase = supportsPlanPhase
    }

    var seededResumeHandle: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return seededResumeHandleStorage
    }

    var followUpPrompts: [String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return followUpPromptsStorage
    }

    // Followable exactly when a resume handle has been seeded — mirrors Codex's
    // `capturedThreadID != nil` rule.
    var canResumeForFollowUp: Bool { seededResumeHandle != nil }

    func adoptResumeHandle(_ resumeHandle: String) {
        stateLock.lock(); seededResumeHandleStorage = resumeHandle; stateLock.unlock()
    }

    func makeSessionOutputDirectory(sessionID: String, applicationSupportDirectory: URL) throws -> URL {
        applicationSupportDirectory
    }

    func transcriptPath(sessionID: String, outputDirectory: URL) -> String? { nil }

    func runPlanPhase(
        task: String,
        sessionID: String,
        outputDirectory: URL,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> PlanPhaseResult {
        PlanPhaseResult(sessionID: sessionID, outcome: .readyToExecute)
    }

    func runExecutePhase(
        sessionID: String,
        outputDirectory: URL,
        clarificationAnswers: String?,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> URL {
        outputDirectory.appendingPathComponent("report.html")
    }

    func runFollowUpPhase(
        sessionID: String,
        outputDirectory: URL,
        followUpPrompt: String,
        onProgress: @escaping @MainActor @Sendable (ResearchProgressEvent) -> Void
    ) async throws -> FollowUpPhaseResult {
        stateLock.lock(); followUpPromptsStorage.append(followUpPrompt); stateLock.unlock()
        return FollowUpPhaseResult(spokenAnswer: "answered", deliverableWasRewritten: false, deliverableURL: nil)
    }
}

/// Captures the (kind, binaryPath) each `makeEngine` call was made with and the spy it
/// returned, so a reconstruction test can assert WHICH engine kind the manager rebuilt.
@MainActor
private final class ReconstructEngineFactoryBox {
    private(set) var lastKind: CoachEngineKind?
    private(set) var lastBinaryPath: String?
    private(set) var lastEngine: RecordingReconstructResearchEngine?

    func makeEngine(kind: CoachEngineKind, binaryPath: String) -> RecordingReconstructResearchEngine {
        let engine = RecordingReconstructResearchEngine(
            // Model the real capability flags per kind so the spy behaves like the engine it
            // stands in for (Codex: no pre-mint, no plan phase).
            supportsPreMintedSessionID: kind == .claudeCode,
            supportsPlanPhase: kind == .claudeCode
        )
        lastKind = kind
        lastBinaryPath = binaryPath
        lastEngine = engine
        return engine
    }
}

@MainActor
struct CodexResearchReconstructionResumeTests {

    /// THE Stage C outcome: a FINISHED Codex run with a persisted `codexThreadId` (a page
    /// opened from History whose session is no longer live, or after an app relaunch) is
    /// reconstructable, and a follow-up on it RESUMES via the CODEX engine seeded with that
    /// exact thread id — never a brand-new run and never a Claude resume.
    @Test func aCompletedCodexRunWithAThreadIDReconstructsAndResumesViaCodex() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-resume-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let store = ResearchManifestStore(fileURL: temporaryManifestURL)

        let sessionID = "codex-run-\(UUID().uuidString.lowercased())"
        let capturedThreadID = "codex-thread-\(UUID().uuidString.lowercased())"

        // A completed Codex run that captured a thread id (persisted as the resume handle).
        store.recordResearchSessionStarted(
            sessionId: sessionID, title: "Aomori photos", task: "find photos of Aomori and build a page",
            workingDir: "/wd/codex-run", transcriptPath: "", engineKind: .codex
        )
        store.recordResearchSessionOutcome(sessionId: sessionID, status: .completed, deliverablePath: "/wd/codex-run/report.html")
        store.recordCodexThreadID(sessionId: sessionID, threadID: capturedThreadID)

        let engineFactory = ReconstructEngineFactoryBox()
        let manager = ResearchSessionManager(
            // Claude isn't even installed here — reconstruction must still resolve the CODEX
            // binary for a Codex run, independent of the Claude path.
            resolveClaudeBinaryPath: { nil },
            resolveResearchBinaryPath: { kind in kind == .codex ? "/usr/bin/true" : nil },
            makeEngine: { kind, binaryPath in engineFactory.makeEngine(kind: kind, binaryPath: binaryPath) },
            manifestStore: store,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        // Reconstructable now that a thread id exists.
        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == true,
                "a completed Codex run WITH a thread_id must be reconstructable")
        #expect(manager.activeSessionCountForTesting == 0, "nothing live yet — only the manifest knows it")

        // A follow-up on the non-live page routes: reconstruct + start a resume turn.
        let routed = manager.followUpOnSession(id: sessionID, prompt: "QUESTION which one is oldest?")
        #expect(routed == true, "the finished Codex page must resolve back to its session and resume")

        // Reconstructed under the SAME id — not a brand-new run.
        let session = manager.sessionForTesting(id: sessionID)
        #expect(session != nil, "the non-live Codex session was reconstructed from the manifest")
        #expect(session?.sessionID == sessionID)
        #expect(manager.activeSessionCountForTesting == 1, "exactly one session — reconstructed, not a new run")
        #expect(session?.followUpTurnsStartedCountForTesting == 1, "the utterance ran as a follow-up turn")

        // The manager rebuilt the CODEX engine and seeded it with the EXACT persisted thread id.
        #expect(engineFactory.lastKind == .codex, "reconstruction must rebuild the Codex engine, not Claude")
        #expect(engineFactory.lastBinaryPath == "/usr/bin/true", "resolved via the codex binary")
        #expect(engineFactory.lastEngine?.seededResumeHandle == capturedThreadID,
                "the reconstructed Codex engine must be seeded with the persisted thread_id")

        // The follow-up turn actually reached the Codex engine's resume path with the prompt.
        try await pollUntilFollowUp(timeoutSeconds: 10, "the Codex resume turn to be invoked") {
            engineFactory.lastEngine?.followUpPrompts.isEmpty == false
        }
        #expect(engineFactory.lastEngine?.followUpPrompts.first?.contains("which one is oldest?") == true,
                "the follow-up prompt must reach the Codex engine's resume turn")
    }

    /// A pre-persistence Codex run (recorded before `codexThreadId` existed) is STILL
    /// reconstructable when its thread id is recoverable from the rollout transcript path —
    /// and the reconstructed Codex engine is seeded with that recovered id.
    @Test func aPrePersistenceCodexRunReconstructsFromTheRecoveredTranscriptThreadID() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-recover-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let store = ResearchManifestStore(fileURL: temporaryManifestURL)

        let sessionID = "codex-legacy-\(UUID().uuidString.lowercased())"
        // The thread id lives ONLY in the rollout transcript filename (no persisted field).
        let transcriptPath = "/home/.codex/sessions/2026/07/09/rollout-2026-07-09T00-00-00-recovered-thread-xyz.jsonl"

        store.recordResearchSessionStarted(
            sessionId: sessionID, title: "t", task: "x",
            workingDir: "/wd/legacy", transcriptPath: transcriptPath, engineKind: .codex
        )
        store.recordResearchSessionOutcome(sessionId: sessionID, status: .completed, deliverablePath: "/wd/legacy/report.html")
        // Deliberately NO recordCodexThreadID — this models a run indexed before that field.

        let engineFactory = ReconstructEngineFactoryBox()
        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { nil },
            resolveResearchBinaryPath: { kind in kind == .codex ? "/usr/bin/true" : nil },
            makeEngine: { kind, binaryPath in engineFactory.makeEngine(kind: kind, binaryPath: binaryPath) },
            manifestStore: store,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == true,
                "a pre-persistence Codex run with a recoverable transcript thread id must be reconstructable")
        #expect(manager.followUpOnSession(id: sessionID, prompt: "QUESTION continue") == true)
        #expect(engineFactory.lastKind == .codex)
        #expect(engineFactory.lastEngine?.seededResumeHandle == "recovered-thread-xyz",
                "the Codex engine must be seeded with the id recovered from the transcript path")
    }

    /// The Claude reconstruction path is byte-for-byte behaviorally UNCHANGED: a completed
    /// Claude run reconstructs, rebuilds the CLAUDE engine (seeded with its own session id,
    /// a no-op for Claude), and starts a follow-up turn — exactly as before Stage C.
    @Test func theClaudeReconstructionPathStaysUnchanged() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-reconstruct-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let store = ResearchManifestStore(fileURL: temporaryManifestURL)

        let sessionID = "claude-sess-\(UUID().uuidString.lowercased())"
        store.recordResearchSessionStarted(
            sessionId: sessionID, title: "Desks", task: "compare desks",
            workingDir: "/wd/claude", transcriptPath: "/tp/claude.jsonl", engineKind: .claudeCode
        )
        store.recordResearchSessionOutcome(sessionId: sessionID, status: .completed, deliverablePath: "/wd/claude/report.html")

        let engineFactory = ReconstructEngineFactoryBox()
        let manager = ResearchSessionManager(
            resolveClaudeBinaryPath: { "/usr/bin/true" },
            makeEngine: { kind, binaryPath in engineFactory.makeEngine(kind: kind, binaryPath: binaryPath) },
            manifestStore: store,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == true)
        let routed = manager.followUpOnSession(id: sessionID, prompt: "QUESTION_ONLY still there?")
        #expect(routed == true, "a completed Claude run must still reconstruct + resume")

        let session = manager.sessionForTesting(id: sessionID)
        #expect(session != nil)
        #expect(manager.activeSessionCountForTesting == 1)
        #expect(session?.followUpTurnsStartedCountForTesting == 1)
        // Rebuilds the CLAUDE engine, seeded with its own session id (Claude ignores it).
        #expect(engineFactory.lastKind == .claudeCode)
        #expect(engineFactory.lastEngine?.seededResumeHandle == sessionID,
                "Claude's resume handle is its own session id")
    }

    /// A finished Codex run that HAS a resume handle (thread_id) but whose PRODUCING engine's
    /// binary is NOT installed is NON-reconstructable: `canReconstructFinishedSession` is
    /// false, a follow-up refuses gracefully (no crash, no run started), and — critically —
    /// it must NOT fall through to the currently-SELECTED engine's binary (Claude here) and
    /// resume the wrong engine. Reconstruction resumes the engine that PRODUCED the run.
    @Test func aCompletedCodexRunWithAThreadIDButNoCodexBinaryIsNotReconstructable() async throws {
        let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-nobinary-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryManifestURL) }
        let store = ResearchManifestStore(fileURL: temporaryManifestURL)

        let sessionID = "codex-run-\(UUID().uuidString.lowercased())"
        // A completed Codex run WITH a captured thread id (so a resume handle IS available)…
        store.recordResearchSessionStarted(
            sessionId: sessionID, title: "t", task: "x",
            workingDir: "/wd/codex-run", transcriptPath: "", engineKind: .codex
        )
        store.recordResearchSessionOutcome(sessionId: sessionID, status: .completed, deliverablePath: "/wd/codex-run/report.html")
        store.recordCodexThreadID(sessionId: sessionID, threadID: "codex-thread-present")

        let engineFactory = ReconstructEngineFactoryBox()
        let manager = ResearchSessionManager(
            // Claude IS installed and is the selected engine's binary — the ONLY thing missing
            // is the codex binary. Reconstruction must still refuse (not resume via Claude).
            resolveClaudeBinaryPath: { "/usr/bin/true" },
            resolveResearchBinaryPath: { kind in kind == .codex ? nil : "/usr/bin/true" },
            makeEngine: { kind, binaryPath in engineFactory.makeEngine(kind: kind, binaryPath: binaryPath) },
            manifestStore: store,
            audioCuePlayer: SilentResearchAudioCuePlayer(),
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
        defer { manager.stopAll() }

        // A resume handle exists, but the codex binary does not → NOT reconstructable.
        #expect(manager.canReconstructFinishedSession(forSessionID: sessionID) == false,
                "a Codex run whose codex binary is unresolvable must not be reconstructable")
        // A follow-up refuses gracefully — no session reconstructed, no engine built.
        #expect(manager.followUpOnSession(id: sessionID, prompt: "QUESTION continue") == false,
                "the follow-up must refuse rather than resume the wrong engine")
        #expect(manager.sessionForTesting(id: sessionID) == nil, "no session was reconstructed")
        #expect(manager.activeSessionCountForTesting == 0)
        // Critically: it must NOT have fallen through to the (installed) Claude binary.
        #expect(engineFactory.lastEngine == nil, "no engine was built — never fell through to the Claude binary")
    }
}
