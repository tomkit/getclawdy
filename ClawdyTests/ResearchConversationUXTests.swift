//
//  ResearchConversationUXTests.swift
//  ClawdyTests
//
//  The research CONVERSATION / toast UX slice:
//   • ITEM 5 — the FAILED (.error) toast is a PERSISTENT, actionable, red terminal state:
//       it is NOT auto-scheduled for removal (unlike .stopped), it exposes a dismiss action
//       (that REMOVES the session — not marking it "dismissed" in the manifest), and an
//       error TAP opens its detail panel so the failure is readable in place.
//   • ITEM 7 — chat alignment: user → trailing (right), assistant + tool plumbing → leading
//       (left), and only conversation messages render as bubbles.
//   • ITEM 8 — a TYPED follow-up submitted from the chat composer takes the SAME per-session
//       FIFO path a spoken follow-up does (enqueue behind an in-flight turn; never a
//       concurrent `--resume`), and an empty draft is ignored.
//

import Testing
import Foundation
import AppKit
@testable import Clawdy

// MARK: - Helpers


/// A manager whose `claude` never resolves, so `startSession` fails PREFLIGHT synchronously
/// and the session lands in the `.error` overlay phase immediately — the cleanest way to
/// exercise the failed-toast lifecycle with no process.
@MainActor
private func makeErrorStateManager() -> ResearchSessionManager {
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("convux-error-manifest-\(UUID().uuidString).json")
    return ResearchSessionManager(
        resolveClaudeBinaryPath: { nil },
        manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

/// A fake `claude` supporting the plan → execute → follow-up lifecycle, mirroring the
/// verified 2.1.198 behavior: plan persists a per-CWD marker + proceeds; a `--resume` turn
/// answers (QUESTION_ONLY) or hangs (HANGRESUME) or writes report.html (default/ITERATE).
private let conversationFakeSessionID = "sess-convux-1"

private func makeConversationFakeClaudeBinary() throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-convux-1"}"#
    let proceedResult = #"{"type":"result","result":"here is the plan, proceeding now","is_error":false}"#
    let executeResult = #"{"type":"result","result":"done, wrote report.html","is_error":false}"#
    let questionResult = #"{"type":"result","result":"the answer is forty-two.","is_error":false}"#

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
      echo "plan" > "session-\(conversationFakeSessionID).marker"
      emit '\(proceedResult)'
    else
      if [ ! -f "session-$resume.marker" ]; then
        emit "{\\"type\\":\\"result\\",\\"result\\":\\"No conversation found with session ID: $resume\\",\\"is_error\\":true}"
        exit 1
      fi
      outpath=$(printf '%s' "$task" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
      case "$task" in
        *QUESTION_ONLY*) emit '\(questionResult)' ;;
        *) if [ -n "$outpath" ]; then printf '<!doctype html><html><body><h1>report</h1></body></html>' > "$outpath"; fi
           emit '\(executeResult)' ;;
      esac
    fi
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

@MainActor
private func makeConversationManager(binaryPath: String) -> ResearchSessionManager {
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("convux-appsupport-\(UUID().uuidString)", isDirectory: true)
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("convux-manifest-\(UUID().uuidString).json")
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
        generateSessionID: { conversationFakeSessionID },
        applicationSupportDirectory: temporaryApplicationSupport,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
        audioCuePlayer: SilentResearchAudioCuePlayer(),
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

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

// MARK: - ITEM 5 — the FAILED toast is persistent, actionable, and red

@MainActor
struct ResearchErrorToastTests {

    /// A FAILED (.error) session is NOT scheduled for auto-removal — it persists on screen
    /// (like `.done`) until the user reads or dismisses it, unlike a `.stopped` run which
    /// still lingers-then-removes.
    @Test func aFailedSessionIsNotScheduledForRemoval() {
        let manager = makeErrorStateManager()
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "a doomed research task")
        // Preflight failed synchronously → the overlay phase is `.error`.
        #expect(manager.sessionForTesting(id: sessionID)?.overlayPhase == .error)
        // …and crucially it was NOT scheduled for removal.
        #expect(manager.pendingRemovalCountForTesting == 0,
                "a failed pill must persist — never auto-scheduled for removal like a stopped one")
        #expect(manager.sessionOrderForTesting.contains(sessionID),
                "the failed session is still present in the stack")
    }

    /// CONTRAST: a `.stopped` run IS scheduled for auto-removal (the linger-then-hide the
    /// failed state deliberately does NOT get).
    @Test func aStoppedSessionIsScheduledForRemoval() async throws {
        let binary = try makeConversationFakeClaudeBinary()
        let manager = makeConversationManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "research and build a page")
        try await pollUntil(timeoutSeconds: 20, "session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        manager.stopSession(id: sessionID)
        #expect(manager.sessionForTesting(id: sessionID)?.overlayPhase == .stopped)
        #expect(manager.pendingRemovalCountForTesting == 1,
                "a stopped pill is scheduled for auto-removal")
    }

    /// The error pill exposes a DISMISS action that REMOVES the session outright (rather
    /// than marking it "dismissed" in the manifest — which would bury the "failed" status
    /// behind a "dismissed" tag in History).
    @Test func dismissingAFailedPillRemovesTheSessionWithoutMarkingItDismissed() {
        let manager = makeErrorStateManager()
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "a doomed research task")
        let session = manager.sessionForTesting(id: sessionID)!
        #expect(session.overlayPhase == .error)

        // The dismiss (×) control on the failed pill is wired through the view model.
        session.overlayViewModel.onDismiss?()

        #expect(manager.sessionForTesting(id: sessionID) == nil,
                "dismissing a failed pill removes the session entirely")
        #expect(manager.dismissedSessionIDsForTesting.contains(sessionID) == false,
                "a failed dismiss must NOT stamp the session 'dismissed' in the manifest")
    }

    /// The pure control set for `.error` offers a dismiss (×) and no Stop — the actionable,
    /// terminal control contract.
    @Test func errorControlSetExposesDismissAndNoStop() {
        let controls = ResearchToastControlSet.controls(forPhase: .error)
        #expect(controls.showsDismiss == true, "the failed pill exposes a dismiss action")
        #expect(controls.showsStop == false, "a failed run can't be stopped — it's already terminal")
    }

    /// The pure click-action mapping: an `.error` tap OPENS the detail panel (toggle, like a
    /// running pill) so the failure/transcript is readable in place — it is NOT a bare
    /// clear-focus like a `.stopped` pill.
    @Test func errorTapOpensDetailStoppedTapClearsFocus() {
        #expect(ResearchToastClickAction.action(forPhase: .error, isFocused: false) == .showDetail)
        #expect(ResearchToastClickAction.action(forPhase: .error, isFocused: true) == .hideDetail)
        #expect(ResearchToastClickAction.action(forPhase: .stopped, isFocused: false) == .clearFocus)
    }

    /// REAL PATH: tapping a failed pill focuses the session AND shows its detail panel, so
    /// the user can read the error / transcript in place.
    @Test func tappingAFailedPillOpensItsDetailPanel() {
        let manager = makeErrorStateManager()
        defer { manager.stopAll() }

        let sessionID = manager.startSession(taskDescription: "a doomed research task")
        #expect(manager.sessionForTesting(id: sessionID)?.overlayPhase == .error)
        #expect(manager.detailPanelVisibleForTesting == false)

        manager.handleCompactTapForTesting(id: sessionID)
        #expect(manager.focusedSessionID == sessionID, "a failed tap focuses the session")
        #expect(manager.detailPanelVisibleForTesting == true,
                "a failed tap opens the detail panel so the error is readable in place")

        // Re-tapping toggles the detail closed again.
        manager.handleCompactTapForTesting(id: sessionID)
        #expect(manager.detailPanelVisibleForTesting == false)
    }
}

// MARK: - ITEM 7 — chat alignment mapping

struct ResearchChatBubbleAlignmentTests {

    /// The who-said-what alignment: only the USER's own messages sit on the trailing (right)
    /// edge; Clawdy's prose and the tool plumbing sit on the leading (left) edge.
    @Test func userIsTrailingEverythingElseIsLeading() {
        #expect(ResearchChatBubbleSide.side(for: .userMessage) == .trailing)
        #expect(ResearchChatBubbleSide.side(for: .assistantMessage) == .leading)
        #expect(ResearchChatBubbleSide.side(for: .toolCall) == .leading)
        #expect(ResearchChatBubbleSide.side(for: .toolResult) == .leading)
    }

    /// Only conversation MESSAGES render as chat bubbles; tool calls / results stay compact
    /// muted plumbing lines (never a bubble).
    @Test func onlyConversationMessagesRenderAsBubbles() {
        #expect(ResearchChatBubbleSide.rendersAsBubble(kind: .userMessage) == true)
        #expect(ResearchChatBubbleSide.rendersAsBubble(kind: .assistantMessage) == true)
        #expect(ResearchChatBubbleSide.rendersAsBubble(kind: .toolCall) == false)
        #expect(ResearchChatBubbleSide.rendersAsBubble(kind: .toolResult) == false)
    }
}

// MARK: - ITEM 8 — typed follow-up takes the same per-session FIFO path

@MainActor
struct ResearchTypedFollowUpTests {

    private func startAndCompleteSession(_ manager: ResearchSessionManager) async throws -> ResearchSessionID {
        let sessionID = manager.startSession(taskDescription: "research and build a page")
        try await pollUntil(timeoutSeconds: 20, "session to complete") {
            manager.sessionForTesting(id: sessionID)?.state == .completed
        }
        return sessionID
    }

    /// A TYPED follow-up submitted through the chat composer's `onSubmitFollowUp` runs on
    /// THIS session's own thread — a real follow-up turn, not a new session.
    @Test func typedFollowUpRoutesToTheSameSessionAsAFollowUpTurn() async throws {
        let binary = try makeConversationFakeClaudeBinary()
        let manager = makeConversationManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteSession(manager)
        let session = manager.sessionForTesting(id: sessionID)!
        let sessionCountBefore = manager.activeSessionCountForTesting

        // Submit a typed follow-up exactly as the composer does.
        session.overlayViewModel.onSubmitFollowUp?("QUESTION_ONLY what is the typed answer?")

        try await pollUntil(timeoutSeconds: 20, "typed follow-up to finish") {
            session.isFollowUpTurnRunningForTesting == false &&
            session.followUpTurnsStartedCountForTesting >= 1
        }
        #expect(session.followUpTurnsStartedCountForTesting == 1,
                "the typed message ran as a follow-up on THIS session")
        #expect(manager.activeSessionCountForTesting == sessionCountBefore,
                "a typed follow-up must NOT spawn a new session")
    }

    /// Two rapid TYPED follow-ups SERIALIZE through the SAME per-session FIFO queue a spoken
    /// follow-up uses — the first runs (held in flight), the second ENQUEUES; never a
    /// concurrent `--resume` on the one transcript.
    @Test func typedFollowUpsSerializeThroughThePerSessionQueue() async throws {
        let binary = try makeConversationFakeClaudeBinary()
        let manager = makeConversationManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteSession(manager)
        let session = manager.sessionForTesting(id: sessionID)!

        // Fire two typed follow-ups back-to-back; the first hangs so the second must queue.
        session.overlayViewModel.onSubmitFollowUp?("HANGRESUME first typed")
        session.overlayViewModel.onSubmitFollowUp?("QUESTION_ONLY second typed")

        #expect(session.isFollowUpTurnRunningForTesting == true, "the first typed follow-up is in flight")
        #expect(session.queuedFollowUpCountForTesting == 1, "the second typed follow-up is queued, not concurrently resumed")
        #expect(session.followUpTurnsStartedCountForTesting == 1, "only one turn started")
    }

    /// An EMPTY / whitespace-only typed draft is ignored — no follow-up turn starts and
    /// nothing is queued.
    @Test func anEmptyTypedDraftIsIgnored() async throws {
        let binary = try makeConversationFakeClaudeBinary()
        let manager = makeConversationManager(binaryPath: binary)
        defer { manager.stopAll() }

        let sessionID = try await startAndCompleteSession(manager)
        let session = manager.sessionForTesting(id: sessionID)!

        session.overlayViewModel.onSubmitFollowUp?("    ")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(session.followUpTurnsStartedCountForTesting == 0, "an empty draft starts no follow-up")
        #expect(session.queuedFollowUpCountForTesting == 0, "an empty draft queues nothing")
    }
}
