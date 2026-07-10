//
//  ResearchTranscriptFeedTests.swift
//  ClawdyTests
//
//  Headless coverage for the DETAIL panel's thin-wrapper transcript feed: the
//  mapping from Claude Code's OWN session `.jsonl` (searches / fetches / writes /
//  messages) into the `TranscriptTurn`s the detail view renders. Read-only, fenced,
//  and exercised against a temp transcript exactly like the History transcript tests.
//

import Testing
import Foundation
@testable import Clawdy

struct ResearchTranscriptFeedTests {

    /// A representative research-run transcript: a user task, an assistant tool_use
    /// (WebSearch), its tool_result, and a final assistant message. The feed must map
    /// each into an ordered, readable turn the detail panel can show.
    @Test func mapsNativeSessionTranscriptIntoDetailTurns() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-research-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("\(UUID().uuidString).jsonl")
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"research the best espresso machines"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"WebSearch","input":{"query":"best espresso machines 2026"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Top picks: ..."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I wrote the report."}]}}
        """
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let turns = ResearchTranscriptFeed.loadTurns(
            transcriptPath: fileURL.path,
            allowedRoots: [rootURL.path]
        )

        #expect(turns.count == 4)
        // 1: the user's task.
        #expect(turns[0].kind == .userMessage)
        #expect(turns[0].text == "research the best espresso machines")
        // 2: the tool call — carries the tool name in `detail` and the query in `text`,
        // so the detail panel shows the real search claude ran.
        #expect(turns[1].kind == .toolCall)
        #expect(turns[1].detail == "WebSearch")
        #expect(turns[1].text.contains("best espresso machines"))
        // 3: the collapsed tool result.
        #expect(turns[2].kind == .toolResult)
        // 4: the assistant's closing message.
        #expect(turns[3].kind == .assistantMessage)
        #expect(turns[3].text == "I wrote the report.")
    }

    /// Before claude has written anything (or the path is out of fence), the feed
    /// returns [] so the detail view falls back to the synthetic status steps.
    @Test func returnsEmptyForUnwrittenTranscriptSoDetailFallsBack() {
        let missingPath = NSTemporaryDirectory() + "clawdy-research-feed-missing-\(UUID().uuidString).jsonl"
        #expect(ResearchTranscriptFeed.loadTurns(transcriptPath: missingPath).isEmpty)
    }

    /// The feed honors the security fence — a real file OUTSIDE the allowed roots is
    /// rejected (treated as missing), since the transcript path comes from the
    /// user-writable manifest and must not be trusted to read arbitrary files.
    @Test func rejectsATranscriptOutsideTheAllowedRoots() throws {
        let outsideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-outside-\(UUID().uuidString).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"secret"}}"#
            .write(to: outsideURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        // An allowed root that does NOT contain the file → out of fence → [].
        let unrelatedRoot = NSTemporaryDirectory() + "clawdy-fence-\(UUID().uuidString)"
        #expect(ResearchTranscriptFeed.loadTurns(
            transcriptPath: outsideURL.path,
            allowedRoots: [unrelatedRoot]
        ).isEmpty)
    }
}

// MARK: - Final-refresh task lifecycle (no publish after teardown)

@MainActor
struct ResearchTranscriptFeedLifecycleTests {

    private func makeSession() -> ResearchSession {
        ResearchSession(
            sessionID: "feed-lifecycle-\(UUID().uuidString.lowercased())",
            taskDescription: "t",
            resolveEngineSelection: { nil },
            testAnchorOriginOffset: offscreenResearchAnchorOffset
        )
    }

    /// teardown() must cancel a final transcript read that is still in flight, so no
    /// publish lands on the view model after the subsystem is torn down. We pre-seed the
    /// view model with a sentinel, kick a final read, then teardown BEFORE the read's
    /// task runs; awaiting it must leave the sentinel untouched (the cancelled read
    /// never published). Before the fix (untracked task + unconditional publish), the
    /// read would overwrite the sentinel with the parsed result.
    @Test func teardownCancelsPendingFinalTranscriptRefresh() async {
        let session = makeSession()
        let sentinel = [TranscriptTurn(id: 0, kind: .assistantMessage, text: "sentinel", detail: nil)]
        session.overlayViewModel.transcriptTurns = sentinel

        // Kick the final read (its task is scheduled but hasn't run — we still hold the
        // main actor), then capture it and tear down so it's cancelled before it runs.
        session.primeAndFinalizeTranscriptFeedForTesting(
            transcriptPath: NSTemporaryDirectory() + "clawdy-feed-\(UUID().uuidString).jsonl"
        )
        let finalTask = session.transcriptFinalRefreshTaskForTesting
        session.teardown()

        // Let the cancelled task run to completion; it must NOT publish.
        await finalTask?.value
        #expect(session.overlayViewModel.transcriptTurns == sentinel)
    }
}
