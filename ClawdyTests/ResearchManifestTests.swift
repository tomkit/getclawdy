//
//  ResearchManifestTests.swift
//  ClawdyTests
//
//  Covers SLICE A0's keystone additions for the future resume/History features:
//   - the STABLE per-session directory derivation from a pre-minted session id,
//   - the `~/.claude/projects/...` transcript-path derivation (Claude Code's
//     empirically-verified `/`,`.`,space → `-` sanitization),
//   - the injectable `ResearchManifestStore` lifecycle writes (start → outcome, and
//     the read-only root-session record).
//
//  All pure/injectable — no live `claude` process — so they run headlessly.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Stable per-session directory derivation

struct ResearchStableDirectoryTests {

    /// The per-session directory is derived deterministically from the session id
    /// under `<Application Support>/Clawdy/research/<sessionId>/` — the durable home
    /// that replaces the old throwaway `/var/folders/.../clawdy-research/<uuid>`.
    @Test func sessionOutputDirectoryIsDerivedFromTheSessionIDUnderClawdyResearch() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        let sessionID = "44f7cc5d-16b2-4efd-b41a-5aba67c976d3"

        let researchRoot = ClaudeResearchEngine.researchSupportDirectory(applicationSupportDirectory: base)
        #expect(researchRoot.path == "/Users/x/Library/Application Support/Clawdy/research")

        let sessionDirectory = ClaudeResearchEngine.sessionOutputDirectory(
            sessionID: sessionID,
            applicationSupportDirectory: base
        )
        #expect(sessionDirectory.path == "/Users/x/Library/Application Support/Clawdy/research/\(sessionID)")
        // Two different ids derive to two different, non-colliding directories.
        let otherDirectory = ClaudeResearchEngine.sessionOutputDirectory(
            sessionID: "other-id",
            applicationSupportDirectory: base
        )
        #expect(otherDirectory.path != sessionDirectory.path)
    }

    /// `makeSessionOutputDirectory` actually creates the derived directory on disk.
    @Test func makeSessionOutputDirectoryCreatesTheDerivedDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-appsupport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let sessionID = UUID().uuidString.lowercased()
        let created = try ClaudeResearchEngine.makeSessionOutputDirectory(
            sessionID: sessionID,
            applicationSupportDirectory: base
        )
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory) == true)
        #expect(isDirectory.boolValue == true)
        #expect(created.path == ClaudeResearchEngine.sessionOutputDirectory(sessionID: sessionID, applicationSupportDirectory: base).path)
    }

    /// The transcript path mirrors Claude Code's on-disk layout, sanitizing each
    /// `/`, `.`, and space in the working directory to `-` (verified against claude
    /// 2.1.198). This is exactly what the History UI will read.
    @Test func transcriptPathMatchesClaudeCodeSanitizedProjectLayout() {
        let sessionID = "44f7cc5d-16b2-4efd-b41a-5aba67c976d3"
        let workingDirectory = "/Users/tomkit/Library/Application Support/Clawdy/research/\(sessionID)"
        let transcriptPath = ClaudeResearchEngine.claudeTranscriptPath(
            sessionID: sessionID,
            workingDirectoryPath: workingDirectory,
            homeDirectoryPath: "/Users/tomkit"
        )
        #expect(transcriptPath == "/Users/tomkit/.claude/projects/-Users-tomkit-Library-Application-Support-Clawdy-research-\(sessionID)/\(sessionID).jsonl")
    }

    /// The sanitizer replaces `/`, `.`, and whitespace and preserves everything else
    /// (letters, digits, and a UUID's hyphens).
    @Test func projectDirectoryNameSanitizationReplacesSlashesDotsAndSpaces() {
        let sanitized = ClaudeResearchEngine.sanitizedProjectDirectoryName(
            forWorkingDirectoryPath: "/a/probe.dot dir-7f45"
        )
        #expect(sanitized == "-a-probe-dot-dir-7f45")
    }
}

// MARK: - Manifest store lifecycle

/// A mutable clock so tests can advance time and assert `updatedAt` moves while
/// `createdAt` is preserved.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { self.current = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

struct ResearchManifestStoreTests {

    private func makeTempManifestURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-manifest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    @Test func recordingAResearchStartWritesARunningEntry() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        store.recordResearchSessionStarted(
            sessionId: "sess-1",
            title: "photos of aomori",
            task: "find photos of aomori and build a gallery",
            workingDir: "/support/Clawdy/research/sess-1",
            transcriptPath: "/home/.claude/projects/-support-Clawdy-research-sess-1/sess-1.jsonl"
        )

        let sessions = store.loadSessions()
        #expect(sessions.count == 1)
        let entry = sessions[0]
        #expect(entry.sessionId == "sess-1")
        #expect(entry.kind == .research)
        #expect(entry.status == .running)
        #expect(entry.title == "photos of aomori")
        #expect(entry.task == "find photos of aomori and build a gallery")
        #expect(entry.workingDir == "/support/Clawdy/research/sess-1")
        #expect(entry.transcriptPath == "/home/.claude/projects/-support-Clawdy-research-sess-1/sess-1.jsonl")
        #expect(entry.deliverablePath == nil)
        #expect(entry.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(entry.updatedAt == entry.createdAt)
    }

    @Test func completionRecordsDeliverableBumpsUpdatedAtAndPreservesCreatedAt() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 2_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        store.recordResearchSessionStarted(
            sessionId: "sess-2", title: "t", task: "task",
            workingDir: "/wd", transcriptPath: "/tp"
        )
        clock.advance(by: 45)
        store.recordResearchSessionOutcome(
            sessionId: "sess-2",
            status: .completed,
            deliverablePath: "/wd/report.html"
        )

        let entry = store.loadSessions().first { $0.sessionId == "sess-2" }
        #expect(entry?.status == .completed)
        #expect(entry?.deliverablePath == "/wd/report.html")
        #expect(entry?.createdAt == Date(timeIntervalSince1970: 2_000))
        #expect(entry?.updatedAt == Date(timeIntervalSince1970: 2_045))
    }

    @Test func failureAndStopRecordTerminalStatusWithoutADeliverable() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: { Date(timeIntervalSince1970: 3_000) })

        store.recordResearchSessionStarted(sessionId: "fail-1", title: "t", task: "x", workingDir: "/wd", transcriptPath: "/tp")
        store.recordResearchSessionOutcome(sessionId: "fail-1", status: .failed, deliverablePath: nil)
        #expect(store.loadSessions().first { $0.sessionId == "fail-1" }?.status == .failed)
        #expect(store.loadSessions().first { $0.sessionId == "fail-1" }?.deliverablePath == nil)

        store.recordResearchSessionStarted(sessionId: "stop-1", title: "t", task: "x", workingDir: "/wd", transcriptPath: "/tp")
        store.recordResearchSessionOutcome(sessionId: "stop-1", status: .stopped, deliverablePath: nil)
        #expect(store.loadSessions().first { $0.sessionId == "stop-1" }?.status == .stopped)
    }

    /// Belt-and-suspenders guard (Fix 2): a session already recorded `.completed` (with a
    /// real deliverable) must NEVER be regressed BACK to `.failed`/`.stopped` by any
    /// caller — the `.completed` status + `deliverablePath` are preserved. This protects
    /// the durable manifest even if a later transient failure (e.g. a follow-up turn)
    /// mistakenly tries to record a terminal failure on a good deliverable.
    @Test func aCompletedEntryIsNotRegressedToFailedOrStopped() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 7_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        store.recordResearchSessionStarted(
            sessionId: "done-1", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: "/tp"
        )
        clock.advance(by: 10)
        store.recordResearchSessionOutcome(
            sessionId: "done-1", status: .completed, deliverablePath: "/wd/report.html"
        )

        // A later `.failed` regression is REJECTED — status + deliverable are preserved.
        clock.advance(by: 20)
        store.recordResearchSessionOutcome(sessionId: "done-1", status: .failed, deliverablePath: nil)
        let afterFailAttempt = store.loadSessions().first { $0.sessionId == "done-1" }
        #expect(afterFailAttempt?.status == .completed, "a completed run must not regress to .failed")
        #expect(afterFailAttempt?.deliverablePath == "/wd/report.html", "the deliverable path must be preserved")

        // A `.stopped` regression is likewise REJECTED.
        store.recordResearchSessionOutcome(sessionId: "done-1", status: .stopped, deliverablePath: nil)
        let afterStopAttempt = store.loadSessions().first { $0.sessionId == "done-1" }
        #expect(afterStopAttempt?.status == .completed, "a completed run must not regress to .stopped")
        #expect(afterStopAttempt?.deliverablePath == "/wd/report.html")

        // A legitimate re-completion is UNAFFECTED (still completed, new deliverable adopted).
        store.recordResearchSessionOutcome(
            sessionId: "done-1", status: .completed, deliverablePath: "/wd/report-v2.html"
        )
        let afterRecomplete = store.loadSessions().first { $0.sessionId == "done-1" }
        #expect(afterRecomplete?.status == .completed)
        #expect(afterRecomplete?.deliverablePath == "/wd/report-v2.html",
                "a legitimate re-completion still adopts the newer deliverable")
    }

    /// Fix 3: `recordRootSession` preserves the original `createdAt` under a SINGLE locked
    /// read-modify-write (`upsertPreservingCreatedAt`) — refreshing a root id keeps its
    /// createdAt while bumping updatedAt, with no cross-lock read-then-write gap.
    @Test func recordRootSessionPreservesCreatedAtUnderTheSingleLockPath() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 8_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        store.recordRootSession(
            sessionId: "root-x", title: "Quick answers",
            workingDir: "/home", transcriptPath: "/home/.claude/projects/-home/root-x.jsonl"
        )
        let originalCreatedAt = store.loadSessions().first { $0.sessionId == "root-x" }?.createdAt
        #expect(originalCreatedAt == Date(timeIntervalSince1970: 8_000))

        clock.advance(by: 250)
        store.recordRootSession(
            sessionId: "root-x", title: "Quick answers",
            workingDir: "/home", transcriptPath: "/home/.claude/projects/-home/root-x.jsonl"
        )
        let refreshed = store.loadSessions().first { $0.sessionId == "root-x" }
        #expect(refreshed?.createdAt == originalCreatedAt, "createdAt must be preserved across a refresh")
        #expect(refreshed?.updatedAt == Date(timeIntervalSince1970: 8_250), "updatedAt is bumped to now")
        #expect(store.loadSessions().count == 1, "the refresh replaces the entry in place")
    }

    @Test func recordingAnOutcomeForAnUnknownSessionIsANoOp() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: { Date(timeIntervalSince1970: 4_000) })

        store.recordResearchSessionOutcome(sessionId: "ghost", status: .completed, deliverablePath: "/x")
        #expect(store.loadSessions().isEmpty)
    }

    @Test func rootSessionIsRecordedAsActiveAndPreservesCreatedAtOnRefresh() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 5_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        store.recordRootSession(
            sessionId: "root-1",
            title: "Quick answers",
            workingDir: "/home",
            transcriptPath: "/home/.claude/projects/-home/root-1.jsonl"
        )
        let firstCreatedAt = store.loadSessions().first { $0.sessionId == "root-1" }?.createdAt

        clock.advance(by: 100)
        // The same root id observed again (e.g. after inspecting the stream twice)
        // updates updatedAt but keeps the original createdAt.
        store.recordRootSession(
            sessionId: "root-1",
            title: "Quick answers",
            workingDir: "/home",
            transcriptPath: "/home/.claude/projects/-home/root-1.jsonl"
        )
        let rootEntry = store.loadSessions().first { $0.sessionId == "root-1" }
        #expect(rootEntry?.kind == .root)
        #expect(rootEntry?.status == .active)
        #expect(rootEntry?.createdAt == firstCreatedAt)
        #expect(rootEntry?.updatedAt == Date(timeIntervalSince1970: 5_100))
        // Root and research entries coexist keyed by their distinct session ids.
        #expect(store.loadSessions().count == 1)
    }

    /// Stage A of Codex research parity: the Codex `thread_id` (the resume handle,
    /// discovered post-hoc) is PERSISTED onto the run's entry via `recordCodexThreadID`
    /// and reads back through a fresh store instance — closing the "in-memory only" gap.
    /// The write touches ONLY `codexThreadId`, leaving status/updatedAt/transcriptPath
    /// untouched, and survives a later outcome write; an empty id or an unknown session is
    /// a no-op.
    @Test func codexThreadIDIsPersistedTouchesNothingElseAndRoundTripsAcrossStoreInstances() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let clock = MutableClock(Date(timeIntervalSince1970: 9_000))
        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)

        let originalTranscriptPath = "/home/.codex/sessions/2026/07/09/rollout-2026-07-09T00-00-00-codex-thread-1.jsonl"
        store.recordResearchSessionStarted(
            sessionId: "codex-run-1", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: originalTranscriptPath, engineKind: .codex
        )
        // A SECOND session recorded after, so we can prove the write doesn't reorder the list.
        clock.advance(by: 5)
        store.recordResearchSessionStarted(
            sessionId: "codex-run-2", title: "t2", task: "y",
            workingDir: "/wd2", transcriptPath: "/tp2", engineKind: .codex
        )
        let orderBefore = store.loadSessions().map { $0.sessionId }
        // A fresh Codex run has no thread id yet, and the field defaults to nil.
        #expect(store.loadSessions().first { $0.sessionId == "codex-run-1" }?.codexThreadId == nil)

        // Persisting the captured thread id sets ONLY that field: status, updatedAt,
        // createdAt, and transcriptPath are ALL unchanged (mirroring the transcript-path
        // writer), and the list order is preserved.
        clock.advance(by: 30)
        store.recordCodexThreadID(sessionId: "codex-run-1", threadID: "0199f0a2-codex-thread")
        let afterThreadWrite = store.loadSessions().first { $0.sessionId == "codex-run-1" }
        #expect(afterThreadWrite?.codexThreadId == "0199f0a2-codex-thread")
        #expect(afterThreadWrite?.status == .running, "recording the thread id must not change status")
        #expect(afterThreadWrite?.createdAt == Date(timeIntervalSince1970: 9_000), "recording the thread id must not change createdAt")
        #expect(afterThreadWrite?.updatedAt == Date(timeIntervalSince1970: 9_000), "recording the thread id must not bump updatedAt")
        #expect(afterThreadWrite?.transcriptPath == originalTranscriptPath, "recording the thread id must not change transcriptPath")
        #expect(store.loadSessions().map { $0.sessionId } == orderBefore, "recording the thread id must not reorder the list")

        // A later outcome write preserves the persisted thread id.
        store.recordResearchSessionOutcome(sessionId: "codex-run-1", status: .completed, deliverablePath: "/wd/report.html")
        #expect(store.loadSessions().first { $0.sessionId == "codex-run-1" }?.codexThreadId == "0199f0a2-codex-thread")

        // It round-trips through a brand-new store pointed at the same file.
        let reader = ResearchManifestStore(fileURL: fileURL, dateProvider: clock.now)
        #expect(reader.loadSessions().first { $0.sessionId == "codex-run-1" }?.codexThreadId == "0199f0a2-codex-thread")

        // Guards: an empty id and an unknown session are both no-ops (no crash, no new entry).
        store.recordCodexThreadID(sessionId: "codex-run-1", threadID: "")
        #expect(store.loadSessions().first { $0.sessionId == "codex-run-1" }?.codexThreadId == "0199f0a2-codex-thread")
        store.recordCodexThreadID(sessionId: "ghost", threadID: "whatever")
        #expect(store.loadSessions().contains { $0.sessionId == "ghost" } == false)
    }

    /// Backward-compat: a manifest.json written BEFORE `codexThreadId` existed (the key is
    /// absent from every entry) must still decode — the field reads as nil — so upgrading
    /// the app never drops a user's on-disk History. The pre-change thread id is still
    /// recoverable from the stored rollout transcript path via the fallback helper.
    @Test func aPreChangeManifestWithNoCodexThreadIDKeyStillDecodesWithNil() throws {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A hand-written pre-change document: NO `codexThreadId` key anywhere.
        let legacyManifestJSON = """
        {
          "version": 1,
          "sessions": [
            {
              "sessionId": "legacy-codex",
              "kind": "research",
              "title": "old run",
              "task": "x",
              "status": "completed",
              "createdAt": "2026-07-09T00:00:00Z",
              "updatedAt": "2026-07-09T00:01:00Z",
              "workingDir": "/wd",
              "transcriptPath": "/home/.codex/sessions/2026/07/09/rollout-2026-07-09T00-00-00-codex-thread-1.jsonl",
              "deliverablePath": "/wd/report.html"
            }
          ]
        }
        """
        try legacyManifestJSON.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ResearchManifestStore(fileURL: fileURL)
        let entry = store.loadSessions().first { $0.sessionId == "legacy-codex" }
        #expect(entry != nil, "a pre-change manifest must still decode")
        #expect(entry?.codexThreadId == nil, "an absent codexThreadId key decodes as nil")
        // The other fields decode intact.
        #expect(entry?.status == .completed)
        #expect(entry?.deliverablePath == "/wd/report.html")
        // The fallback recovery reads the thread id straight out of the stored path.
        #expect(CodexResearchEngine.threadID(fromTranscriptPath: entry?.transcriptPath ?? "") == "codex-thread-1")
    }

    @Test func manifestPersistsAcrossStoreInstances() {
        let fileURL = makeTempManifestURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let writer = ResearchManifestStore(fileURL: fileURL, dateProvider: { Date(timeIntervalSince1970: 6_000) })
        writer.recordResearchSessionStarted(sessionId: "persist-1", title: "t", task: "x", workingDir: "/wd", transcriptPath: "/tp")

        // A brand-new store pointed at the same file reads the persisted entry.
        let reader = ResearchManifestStore(fileURL: fileURL, dateProvider: { Date(timeIntervalSince1970: 6_000) })
        #expect(reader.loadSessions().first?.sessionId == "persist-1")
    }
}
