//
//  ResearchEngineSeamTests.swift
//  ClawdyTests
//
//  Stage 2 of Codex research parity is a PURE REFACTOR that introduces a
//  `ResearchEngine` protocol seam (so a future `CodexResearchEngine` can be slotted in
//  behind it) plus an OPTIONAL, backward-compatible `engineKind` field on the manifest.
//  These tests lock in the two invariants that make it safe:
//
//   1. The one existing engine, `ClaudeResearchEngine`, conforms to the new
//      `ResearchEngine` protocol and reports its capability flags
//      (`supportsPreMintedSessionID == true`, `supportsPlanPhase == true`).
//   2. A manifest written BEFORE the `engineKind` field existed still decodes — the
//      absent key reads as nil — while a freshly-written entry carries the Claude value.
//
//  All pure/injectable — no live `claude` process — so they run headlessly.
//

import Testing
import Foundation
@testable import Clawdy

struct ResearchEngineSeamTests {

    // MARK: - Protocol conformance + capability flags

    /// `ClaudeResearchEngine` satisfies the `ResearchEngine` seam and reports both
    /// capability flags as true (it pre-mints a `--session-id` and has a plan phase),
    /// so `ResearchSession` can hold it as the protocol existential with no behavior
    /// change.
    @Test func claudeResearchEngineConformsToResearchEngineWithBothCapabilitiesTrue() {
        let engine: ResearchEngine = ClaudeResearchEngine(binaryPath: "/usr/bin/true")
        #expect(engine.supportsPreMintedSessionID == true)
        #expect(engine.supportsPlanPhase == true)
    }

    // MARK: - Manifest backward-compat for the new optional `engineKind`

    /// An OLD manifest JSON (written before `engineKind` existed) must still decode
    /// through the real store: the missing key reads as nil, and every pre-existing
    /// field is preserved. Backward compatibility is mandatory — a decode failure would
    /// silently drop the user's entire research History.
    @Test func aManifestEntryWithoutEngineKindStillDecodesAsNil() {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-manifest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        // A manifest exactly as an OLDER build would have written it: no `engineKind`
        // key on the entry (and no `dismissed` key either, another later-added optional).
        let legacyManifestJSON = """
        {
          "version": 1,
          "sessions": [
            {
              "sessionId": "legacy-1",
              "kind": "research",
              "title": "old run",
              "task": "an old research task",
              "status": "completed",
              "createdAt": "2024-01-02T03:04:05Z",
              "updatedAt": "2024-01-02T03:05:05Z",
              "workingDir": "/wd/legacy-1",
              "transcriptPath": "/tp/legacy-1.jsonl",
              "deliverablePath": "/wd/legacy-1/report.html"
            }
          ]
        }
        """
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? legacyManifestJSON.data(using: .utf8)?.write(to: fileURL)

        let store = ResearchManifestStore(fileURL: fileURL)
        let sessions = store.loadSessions()

        #expect(sessions.count == 1, "a legacy manifest without engineKind must still decode")
        let entry = sessions.first
        #expect(entry?.sessionId == "legacy-1")
        #expect(entry?.status == .completed)
        #expect(entry?.deliverablePath == "/wd/legacy-1/report.html")
        // The whole point: the absent field decodes to nil, not a crash.
        #expect(entry?.engineKind == nil)
        // And the other later-added optional (`dismissed`) is likewise nil-safe.
        #expect(entry?.dismissed == nil)
    }

    /// A freshly-written research entry now carries the Claude engine kind, so new runs
    /// are tagged going forward (while old untagged entries stay nil per the test above).
    @Test func aFreshlyRecordedResearchEntryIsTaggedWithTheClaudeEngineKind() {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdy-manifest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = ResearchManifestStore(fileURL: fileURL, dateProvider: { Date(timeIntervalSince1970: 9_000) })
        store.recordResearchSessionStarted(
            sessionId: "fresh-1", title: "t", task: "x",
            workingDir: "/wd", transcriptPath: "/tp"
        )

        let entry = store.loadSessions().first { $0.sessionId == "fresh-1" }
        #expect(entry?.engineKind == CoachEngineKind.claudeCode.rawValue)
    }
}
