//
//  WarmRootSessionCaptureTests.swift
//  ClawdyTests
//
//  SLICE A0, item 4: the warm quick-answer `ClaudePersistentSession` captures its
//  OWN `session_id` from the stream's `system`/`init` line — READ-ONLY, for the
//  History manifest — WITHOUT changing how the warm session runs. These tests drive
//  a real `ClaudePersistentSession` against a fake `claude` that emits an init line,
//  and separately assert the warm command line is unaltered.
//

import Testing
import Foundation
@testable import Clawdy

/// A fake warm `claude` that emits a `system`/`init` line (carrying a session id) on
/// startup — exactly like the real CLI — then answers each stdin turn with a delta
/// and a result.
private func makeInitEmittingWarmFakeBinary(rootSessionID: String) throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"__ROOT_ID__"}"#
        .replacingOccurrences(of: "__ROOT_ID__", with: rootSessionID)
    let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi "}}}"#
    let finalResult = #"{"type":"result","result":"final answer","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    emit '\(initLine)'
    while IFS= read -r line; do
      emit '\(delta)'; emit '\(finalResult)'
    done
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// Thread-safe box the capture closure writes to from its background dispatch.
private final class CapturedIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ id: String) { lock.lock(); value = id; lock.unlock() }
    var captured: String? { lock.lock(); defer { lock.unlock() }; return value }
}

struct WarmRootSessionCaptureTests {

    /// The warm session captures its own `session_id` from the init line and fires
    /// the read-only hook with it — and it still serves the turn normally.
    @Test func warmSessionCapturesItsRootSessionIDFromTheInitLine() async throws {
        let rootSessionID = "warm-root-\(UUID().uuidString)"
        let binary = try makeInitEmittingWarmFakeBinary(rootSessionID: rootSessionID)
        let capturedBox = CapturedIDBox()

        let session = ClaudePersistentSession(
            binaryPath: binary,
            homeDirectoryPath: NSTemporaryDirectory(),
            perResponseTimeoutSeconds: 8,
            keepWarmForAppLifetime: true,
            onRootSessionCaptured: { id in capturedBox.set(id) }
        )
        defer { session.shutdown() }

        let answer = try await session.sendRequest(
            systemPrompt: "sys", userText: "hello", historyPrimerText: nil, images: [],
            onAccumulatedText: { _ in }
        )
        // The turn still completes normally — the capture is purely additive.
        #expect(answer == "final answer")

        // Poll briefly: the hook runs off the state queue.
        let deadline = Date().addingTimeInterval(2.0)
        while capturedBox.captured == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(capturedBox.captured == rootSessionID)
        #expect(session.capturedRootSessionIDForTesting == rootSessionID)
    }

    /// The capture must be READ-ONLY: the warm command line is byte-for-byte the same
    /// as before this slice — no `--session-id`, no `--resume`, and none of the
    /// research flags leaked in, while the real warm flags remain.
    @Test func warmCommandLineIsUnchangedByRootCapture() {
        let args = ClaudeCodeEngine.makeArguments(systemPrompt: "coach", useClaudeCustomizations: true)
        // The warm session must NOT pre-assign or resume a session id — capturing is
        // read-only and does not touch the launch flags.
        #expect(args.contains("--session-id") == false)
        #expect(args.contains("--resume") == false)
        // No research/tool flags bled into the warm path.
        #expect(args.contains("--allowedTools") == false)
        #expect(args.contains("--permission-mode") == false)
        #expect(args.contains("--add-dir") == false)
        // The real warm flags are still exactly as designed. `--safe-mode` is
        // deliberately absent (product decision: the user's customizations should
        // load on the warm path — safe-mode disables them; it also breaks
        // `--input-format stream-json` on claude 2.1.198); the root-session capture
        // must not have re-added it either.
        #expect(args.contains("--safe-mode") == false)
        #expect(args.contains("--input-format"))
        #expect(args.contains("stream-json"))
        let toolsIndex = args.firstIndex(of: "--tools")
        #expect(toolsIndex != nil)
        #expect(args[toolsIndex! + 1] == "")
        // Never `--bare` (subscription auth, not API key).
        #expect(args.contains("--bare") == false)
    }
}
