//
//  ResearchHistoryTests.swift
//  ClawdyTests
//
//  Covers SLICE D's pure History logic — no window, no live process, headless:
//   - `HistoryRowBuilder.makeRows`: manifest entries → sorted, display-ready rows
//     (newest-first, present AND past sessions, Root/Research kind badges, human
//     status labels, title fallback, deterministic relative timestamps).
//   - `TranscriptParser`: a Claude Code `.jsonl` → readable turns (user prompts,
//     assistant text, compact tool call/result), and graceful handling of
//     malformed lines and a missing transcript file.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - History rows

struct HistoryRowBuilderTests {

    /// A helper to build a manifest entry with sensible defaults for a test.
    private func makeEntry(
        sessionId: String,
        kind: ResearchSessionKind,
        title: String = "",
        task: String = "",
        status: ResearchSessionStatus,
        createdAt: Date,
        updatedAt: Date,
        deliverablePath: String? = nil
    ) -> ResearchManifestEntry {
        ResearchManifestEntry(
            sessionId: sessionId,
            kind: kind,
            title: title,
            task: task,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            workingDir: "/tmp/work/\(sessionId)",
            transcriptPath: "/tmp/work/\(sessionId)/\(sessionId).jsonl",
            deliverablePath: deliverablePath
        )
    }

    @Test func rowsAreSortedNewestFirstAndIncludeBothPresentAndPastSessions() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            // A finished (past) research run, oldest.
            makeEntry(sessionId: "old-research", kind: .research, title: "Old research",
                      status: .completed, createdAt: base, updatedAt: base),
            // The warm root session, active (present), middle.
            makeEntry(sessionId: "root", kind: .root, title: "Root",
                      status: .active, createdAt: base.addingTimeInterval(60),
                      updatedAt: base.addingTimeInterval(120)),
            // A currently-running (present) research run, newest.
            makeEntry(sessionId: "live-research", kind: .research, title: "Live research",
                      status: .running, createdAt: base.addingTimeInterval(200),
                      updatedAt: base.addingTimeInterval(300)),
        ]

        let rows = HistoryRowBuilder.makeRows(from: entries, now: base.addingTimeInterval(600))

        // All three present AND past sessions are listed (no status filtering).
        #expect(rows.count == 3)
        // Newest updatedAt first.
        #expect(rows.map(\.sessionId) == ["live-research", "root", "old-research"])
        // Running/active present sessions coexist with the completed past one.
        #expect(rows.contains { $0.status == .running })
        #expect(rows.contains { $0.status == .active })
        #expect(rows.contains { $0.status == .completed })
    }

    @Test func kindBadgesDistinguishRootFromResearch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(sessionId: "r", kind: .root, title: "Warm", status: .active,
                      createdAt: now, updatedAt: now),
            makeEntry(sessionId: "x", kind: .research, title: "Dig", status: .completed,
                      createdAt: now, updatedAt: now.addingTimeInterval(-10)),
        ]

        let rows = HistoryRowBuilder.makeRows(from: entries, now: now)
        let rootRow = rows.first { $0.sessionId == "r" }
        let researchRow = rows.first { $0.sessionId == "x" }

        #expect(rootRow?.kindBadge == "Root")
        #expect(researchRow?.kindBadge == "Research")
    }

    @Test func statusLabelsAreHumanReadableForEveryStatus() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let statuses: [ResearchSessionStatus] = [.running, .completed, .failed, .stopped, .active]
        let entries = statuses.enumerated().map { index, status in
            makeEntry(sessionId: "s\(index)", kind: .research, title: "T", status: status,
                      createdAt: now, updatedAt: now.addingTimeInterval(Double(-index)))
        }

        let rows = HistoryRowBuilder.makeRows(from: entries, now: now)
        let labelBySession = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.statusLabel) })

        #expect(labelBySession["s0"] == "Running")
        #expect(labelBySession["s1"] == "Completed")
        #expect(labelBySession["s2"] == "Failed")
        #expect(labelBySession["s3"] == "Stopped")
        #expect(labelBySession["s4"] == "Active")
    }

    @Test func titleFallsBackToTaskThenGenericWhenTitleBlank() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(sessionId: "has-title", kind: .research, title: "Explicit title",
                      task: "the task", status: .completed, createdAt: now, updatedAt: now),
            makeEntry(sessionId: "task-only", kind: .research, title: "   ",
                      task: "Investigate flakiness", status: .running,
                      createdAt: now, updatedAt: now.addingTimeInterval(-1)),
            makeEntry(sessionId: "root-blank", kind: .root, title: "", task: "",
                      status: .active, createdAt: now, updatedAt: now.addingTimeInterval(-2)),
        ]

        let rows = HistoryRowBuilder.makeRows(from: entries, now: now)
        let titleBySession = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.displayTitle) })

        #expect(titleBySession["has-title"] == "Explicit title")
        #expect(titleBySession["task-only"] == "Investigate flakiness")
        // A root entry now collapses into the grouped "Quick answers" row.
        #expect(titleBySession["root-blank"] == "Quick answers")
    }

    // MARK: - Warm/root grouping (ITEM 1)

    /// Every warm/root entry — one per app launch — collapses into a SINGLE "Quick
    /// answers" row (not one row per launch). The grouped row spans from the earliest
    /// root `createdAt` to the latest root `updatedAt`, and adopts the most recently
    /// active root entry's transcript so selecting it shows the current conversation.
    @Test func warmRootEntriesCollapseIntoASingleQuickAnswersRow() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            // Three separate warm "root" sessions (e.g. three app launches).
            makeEntry(sessionId: "root-oldest", kind: .root, title: "Root A", status: .active,
                      createdAt: base, updatedAt: base.addingTimeInterval(30)),
            makeEntry(sessionId: "root-newest", kind: .root, title: "Root C", status: .active,
                      createdAt: base.addingTimeInterval(500), updatedAt: base.addingTimeInterval(900)),
            makeEntry(sessionId: "root-middle", kind: .root, title: "Root B", status: .active,
                      createdAt: base.addingTimeInterval(200), updatedAt: base.addingTimeInterval(400)),
        ]

        let rows = HistoryRowBuilder.makeRows(from: entries, now: base.addingTimeInterval(1000))

        // Exactly ONE row for all three root sessions.
        let rootRows = rows.filter { $0.kind == .root }
        #expect(rootRows.count == 1)
        let grouped = rootRows[0]
        #expect(grouped.displayTitle == "Quick answers")
        #expect(grouped.kindBadge == "Root")
        // Spans earliest createdAt → latest updatedAt across all root entries.
        #expect(grouped.createdAt == base)
        #expect(grouped.updatedAt == base.addingTimeInterval(900))
        // Adopts the most-recently-active root session's identity/transcript.
        #expect(grouped.sessionId == "root-newest")
        #expect(grouped.transcriptPath == "/tmp/work/root-newest/root-newest.jsonl")
    }

    /// The grouped quick-answers row takes part in the SAME reverse-chronological (by
    /// last-updated) ordering as research runs — a research run that was active more
    /// recently than the newest quick answer sorts above it, and vice versa.
    @Test func groupedQuickAnswersRowParticipatesInReverseChronOrdering() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            // A research run updated most recently of all.
            makeEntry(sessionId: "research-fresh", kind: .research, title: "Fresh dig",
                      status: .completed, createdAt: base.addingTimeInterval(600),
                      updatedAt: base.addingTimeInterval(1200)),
            // Two root sessions; the most recent quick answer is at +800.
            makeEntry(sessionId: "root-a", kind: .root, title: "Root", status: .active,
                      createdAt: base, updatedAt: base.addingTimeInterval(300)),
            makeEntry(sessionId: "root-b", kind: .root, title: "Root", status: .active,
                      createdAt: base.addingTimeInterval(400), updatedAt: base.addingTimeInterval(800)),
            // An older research run, last active at +500.
            makeEntry(sessionId: "research-stale", kind: .research, title: "Stale dig",
                      status: .completed, createdAt: base.addingTimeInterval(100),
                      updatedAt: base.addingTimeInterval(500)),
        ]

        let rows = HistoryRowBuilder.makeRows(from: entries, now: base.addingTimeInterval(2000))

        // research-fresh (+1200) > Quick answers (+800) > research-stale (+500).
        #expect(rows.map(\.sessionId) == ["research-fresh", "root-b", "research-stale"])
        #expect(rows[1].displayTitle == "Quick answers")
    }

    /// With no root entries at all, there is no "Quick answers" row (grouping invents
    /// nothing) — only the research runs remain.
    @Test func noQuickAnswersRowWhenThereAreNoRootEntries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(sessionId: "r1", kind: .research, title: "One", status: .completed,
                      createdAt: now, updatedAt: now),
        ]
        let rows = HistoryRowBuilder.makeRows(from: entries, now: now)
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { $0.kind == .research })
    }

    @Test func relativeTimestampBucketsElapsedTimeDeterministically() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(HistoryRowBuilder.relativeTimestamp(from: reference, to: reference) == "just now")
        #expect(HistoryRowBuilder.relativeTimestamp(
            from: reference, to: reference.addingTimeInterval(5 * 60)) == "5 min ago")
        #expect(HistoryRowBuilder.relativeTimestamp(
            from: reference, to: reference.addingTimeInterval(2 * 3600)) == "2 hr ago")
        #expect(HistoryRowBuilder.relativeTimestamp(
            from: reference, to: reference.addingTimeInterval(86_400)) == "1 day ago")
        #expect(HistoryRowBuilder.relativeTimestamp(
            from: reference, to: reference.addingTimeInterval(3 * 86_400)) == "3 days ago")
        #expect(HistoryRowBuilder.relativeTimestamp(
            from: reference, to: reference.addingTimeInterval(14 * 86_400)) == "2 weeks ago")
    }

    @Test func emptyManifestYieldsNoRows() {
        #expect(HistoryRowBuilder.makeRows(from: [], now: Date()).isEmpty)
    }
}

// MARK: - Transcript parsing

struct TranscriptParserTests {

    @Test func wellFormedLinesBecomeReadableUserAndAssistantTurns() {
        // A minimal but representative transcript: a string user message, an
        // assistant text reply, and non-conversation records that must be ignored.
        let jsonl = """
        {"type":"mode","mode":"default"}
        {"type":"user","message":{"role":"user","content":"How do I center a div?"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Use flexbox."}]}}
        {"type":"system","subtype":"init"}
        """

        let turns = TranscriptParser.parse(jsonlContents: jsonl)

        #expect(turns.count == 2)
        #expect(turns[0].kind == .userMessage)
        #expect(turns[0].text == "How do I center a div?")
        #expect(turns[1].kind == .assistantMessage)
        #expect(turns[1].text == "Use flexbox.")
    }

    @Test func toolUseAndToolResultRenderAsCompactTurnsWithDetail() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\\nsecond line"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"total 0\\nfile.txt"}]}]}}
        """

        let turns = TranscriptParser.parse(jsonlContents: jsonl)

        #expect(turns.count == 2)
        #expect(turns[0].kind == .toolCall)
        #expect(turns[0].detail == "Bash")
        // Compact: only the first line of the command is previewed.
        #expect(turns[0].text == "ls -la")
        #expect(turns[1].kind == .toolResult)
        #expect(turns[1].text == "total 0")
    }

    @Test func thinkingAndImageBlocksAreNotRendered() {
        let jsonl = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret chain of thought"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"look at this"},{"type":"image","source":{"type":"base64","data":"AAAA"}}]}}
        """

        let turns = TranscriptParser.parse(jsonlContents: jsonl)

        // Thinking is dropped entirely; the image block is dropped but its sibling
        // text survives.
        #expect(turns.count == 1)
        #expect(turns[0].kind == .userMessage)
        #expect(turns[0].text == "look at this")
    }

    @Test func malformedLinesAreSkippedWithoutLosingGoodTurns() {
        let jsonl = """
        this is not json at all
        {"type":"user","message":{"role":"user","content":"good one"}}
        {"type":"user","message":{"role":"user","content":  // broken
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still here"}]}}
        """

        let turns = TranscriptParser.parse(jsonlContents: jsonl)

        #expect(turns.count == 2)
        #expect(turns[0].text == "good one")
        #expect(turns[1].text == "still here")
    }

    @Test func emptyOrWhitespaceOnlyContentYieldsNoTurns() {
        let jsonl = """

        {"type":"user","message":{"role":"user","content":"   "}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":""}]}}
        """

        #expect(TranscriptParser.parse(jsonlContents: jsonl).isEmpty)
    }

    @Test func emptyStringParsesToNoTurns() {
        #expect(TranscriptParser.parse(jsonlContents: "").isEmpty)
    }

    // MARK: File load

    @Test func loadResultReturnsFileMissingForAbsentTranscript() {
        let missingPath = NSTemporaryDirectory() + "clawdy-history-does-not-exist-\(UUID().uuidString).jsonl"
        #expect(TranscriptParser.loadResult(forFileAtPath: missingPath) == .fileMissing)
    }

    @Test func loadResultParsesAnExistingTranscriptFile() throws {
        // Stand up a temp directory that acts as an in-fence transcript root so this
        // legitimate, in-fence read parses exactly as before the fence was added.
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-history-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("\(UUID().uuidString).jsonl")
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi from disk"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]}}
        """
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = TranscriptParser.loadResult(
            forFileAtPath: fileURL.path,
            allowedRoots: [rootURL.path]
        )

        guard case let .parsed(turns) = result else {
            Issue.record("Expected .parsed, got \(result)")
            return
        }
        #expect(turns.count == 2)
        #expect(turns[0].text == "hi from disk")
        #expect(turns[1].text == "hi back")
    }
}

// MARK: - Read-side path fence (security regression)

struct HistoryPathFenceTests {

    /// Creates a directory that stands in for an allowed root (e.g. the Claude
    /// projects store), plus a sibling "outside" directory it must never reach.
    private func makeFenceFixture() throws -> (allowedRoot: URL, outsideDir: URL, cleanup: () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-fence-\(UUID().uuidString)", isDirectory: true)
        let allowedRoot = base.appendingPathComponent("allowed", isDirectory: true)
        let outsideDir = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        return (allowedRoot, outsideDir, { try? FileManager.default.removeItem(at: base) })
    }

    // MARK: isPathWithinAllowedRoots (the pure fence)

    @Test func inFencePathIsAccepted() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        let inside = fixture.allowedRoot.appendingPathComponent("sub/transcript.jsonl").path
        #expect(TranscriptParser.isPathWithinAllowedRoots(inside, roots: [fixture.allowedRoot.path]))
    }

    @Test func absoluteOutOfFencePathIsRejected() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        #expect(!TranscriptParser.isPathWithinAllowedRoots("/etc/passwd", roots: [fixture.allowedRoot.path]))
    }

    @Test func dotDotTraversalEscapingTheRootIsRejected() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        // Standardizes to <base>/outside/secret — outside the allowed root.
        let traversal = fixture.allowedRoot.appendingPathComponent("../outside/secret.jsonl").path
        #expect(!TranscriptParser.isPathWithinAllowedRoots(traversal, roots: [fixture.allowedRoot.path]))
    }

    @Test func siblingPrefixDirectoryIsNotMistakenForContainment() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        // "<...>/allowed-evil" shares a raw string prefix with "<...>/allowed" but is
        // a different directory — component-wise comparison must reject it.
        let sibling = fixture.allowedRoot.path + "-evil/file.jsonl"
        #expect(!TranscriptParser.isPathWithinAllowedRoots(sibling, roots: [fixture.allowedRoot.path]))
    }

    @Test func symlinkEscapingTheRootIsRejected() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        // A secret file outside the fence, and a symlink INSIDE the fence pointing at it.
        let secretURL = fixture.outsideDir.appendingPathComponent("secret.jsonl")
        try "top secret".write(to: secretURL, atomically: true, encoding: .utf8)
        let symlinkURL = fixture.allowedRoot.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: secretURL)

        #expect(!TranscriptParser.isPathWithinAllowedRoots(symlinkURL.path, roots: [fixture.allowedRoot.path]))
    }

    // MARK: loadResult end-to-end (transcript READ fence)

    @Test func loadResultRejectsAbsoluteOutOfFencePathAsMissing() throws {
        // /etc/passwd exists and is readable — WITHOUT the fence this would return
        // its contents. With the fence it must read as a missing transcript.
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        #expect(TranscriptParser.loadResult(
            forFileAtPath: "/etc/passwd",
            allowedRoots: [fixture.allowedRoot.path]
        ) == .fileMissing)
    }

    @Test func loadResultRejectsSymlinkEscapeAsMissingNotContents() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        let secretURL = fixture.outsideDir.appendingPathComponent("secret.jsonl")
        try #"{"type":"user","message":{"role":"user","content":"SECRET"}}"#
            .write(to: secretURL, atomically: true, encoding: .utf8)
        let symlinkURL = fixture.allowedRoot.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: secretURL)

        // The symlink is inside the fence but resolves outside — must NOT be read.
        #expect(TranscriptParser.loadResult(
            forFileAtPath: symlinkURL.path,
            allowedRoots: [fixture.allowedRoot.path]
        ) == .fileMissing)
    }

    @Test func loadResultRejectsDotDotTraversalAsMissingNotContents() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        let secretURL = fixture.outsideDir.appendingPathComponent("secret.jsonl")
        try #"{"type":"user","message":{"role":"user","content":"SECRET"}}"#
            .write(to: secretURL, atomically: true, encoding: .utf8)
        let traversalPath = fixture.allowedRoot.appendingPathComponent("../outside/secret.jsonl").path

        #expect(TranscriptParser.loadResult(
            forFileAtPath: traversalPath,
            allowedRoots: [fixture.allowedRoot.path]
        ) == .fileMissing)
    }

    // MARK: deliverable fence

    @Test func deliverableInsideResearchRootIsAllowed() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        let page = fixture.allowedRoot.appendingPathComponent("session/report.html").path
        #expect(TranscriptParser.isPathWithinAllowedRoots(page, roots: [fixture.allowedRoot.path]))
    }

    @Test func deliverableOutsideResearchRootIsRejected() throws {
        let fixture = try makeFenceFixture()
        defer { fixture.cleanup() }
        let outsidePage = fixture.outsideDir.appendingPathComponent("report.html").path
        #expect(!TranscriptParser.isPathWithinAllowedRoots(outsidePage, roots: [fixture.allowedRoot.path]))
    }
}

// MARK: - Single trailing signal (sparse IA)

/// The trimmed IA collapses the old kind pill + status dot + status word + timestamp into
/// ONE token per row. These assert the ACTUAL resolved text + tone for each case (not
/// tautologies), so a regression that re-stacks descriptors or mislabels a state fails.
struct HistorySessionRowSignalTests {

    private func makeRow(
        status: ResearchSessionStatus,
        kind: ResearchSessionKind = .research,
        dismissed: Bool = false,
        updatedOffsetSeconds: TimeInterval = 0
    ) -> HistoryRow {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ResearchManifestEntry(
            sessionId: "s",
            kind: kind,
            title: "Best winter photo spots in Aomori",
            task: "Best winter photo spots in Aomori",
            status: status,
            createdAt: base,
            updatedAt: base.addingTimeInterval(updatedOffsetSeconds),
            workingDir: "/tmp/s",
            transcriptPath: "/tmp/s/s.jsonl",
            deliverablePath: nil,
            dismissed: dismissed ? true : nil
        )
        // `now` two hours after `updatedAt` so a completed run's time signal is a stable
        // "2 hr ago" we can assert exactly.
        let now = base.addingTimeInterval(updatedOffsetSeconds + 2 * 3600)
        return HistoryRowBuilder.makeRow(from: entry, now: now)
    }

    @Test func runningRowShowsTheStatusWordInTheActiveTone() {
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .running))
        #expect(signal.text == "running")
        #expect(signal.tone == .active)
    }

    @Test func failedRowShowsTheStatusWordInTheFailureTone() {
        // A failed run flags itself in the RED `.failure` tone (matching the live progress
        // overlay's error color), NOT the amber `.warning` used for non-failure caution.
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .failed))
        #expect(signal.text == "failed")
        #expect(signal.tone == .failure)
    }

    @Test func stoppedRowShowsTheStatusWordInTheNeutralTone() {
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .stopped))
        #expect(signal.text == "stopped")
        #expect(signal.tone == .neutral)
    }

    @Test func completedRowShowsTheRelativeTimeNotAStatusWord() {
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .completed))
        // The single signal for a finished run is its relative time, never "completed".
        #expect(signal.text == "2 hr ago")
        #expect(signal.tone == .neutral)
    }

    @Test func activeRootRowShowsTheRelativeTime() {
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .active, kind: .root))
        #expect(signal.text == "2 hr ago")
        #expect(signal.tone == .neutral)
    }

    @Test func dismissedRowCollapsesToTheDismissedTagRegardlessOfStatus() {
        // A dismissed running run reads "dismissed" (not "running") — the single signal
        // carries the dismissed affordance rather than a separate always-on capsule tag.
        let signal = HistorySessionRowSignal.forRow(makeRow(status: .running, dismissed: true))
        #expect(signal.text == "dismissed")
        #expect(signal.tone == .neutral)
    }
}
