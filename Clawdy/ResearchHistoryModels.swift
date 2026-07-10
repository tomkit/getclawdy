//
//  ResearchHistoryModels.swift
//  Clawdy
//
//  Pure, testable models for the native History window (SLICE D). Two concerns,
//  both free of any UI or file I/O so they unit-test headlessly:
//
//   1. `HistoryRowBuilder` turns the raw `ResearchManifestEntry` list from
//      `ResearchManifestStore` into display-ready `HistoryRow`s — newest first,
//      with a resolved title, a Root/Research kind badge, a human status label,
//      and a relative timestamp computed against an injected `now` (so tests are
//      deterministic). It shows BOTH present (running/active) and past
//      (completed/failed/stopped) sessions — it never filters by status.
//
//   2. `TranscriptParser` turns the contents of a Claude Code transcript `.jsonl`
//      (one JSON record per line) into an ordered list of readable `TranscriptTurn`s:
//      user prompts, assistant text, and compact tool-call / tool-result markers.
//      Malformed lines are skipped rather than throwing, and a missing file is
//      surfaced as a distinct result so the UI can show a friendly placeholder.
//
//  This slice is strictly READ-ONLY over the manifest and transcripts — nothing
//  here writes or deletes anything.
//

import Foundation

// MARK: - History rows

/// One row in the History list: a manifest entry resolved into everything the UI
/// needs to render it, plus the paths the detail pane reads (both READ-ONLY).
struct HistoryRow: Identifiable, Equatable {
    /// Stable identity for SwiftUI selection — the session id.
    var id: String { sessionId }

    let sessionId: String
    let kind: ResearchSessionKind
    /// The best human title for the row: the entry's `title` if it has one, else
    /// its `task`, else a generic fallback so the row is never blank.
    let displayTitle: String
    /// "Root" for the warm quick-answer session, "Research" for a research run.
    let kindBadge: String
    let status: ResearchSessionStatus
    /// A capitalized, human-readable status ("Running", "Completed", …).
    let statusLabel: String
    /// A short relative time like "2 min ago", computed against an injected `now`.
    let relativeTimestamp: String
    /// Absolute path to the Claude Code transcript `.jsonl` (may no longer exist).
    let transcriptPath: String
    /// The directory the session was created/run in — the directory a "Resume in
    /// Terminal" action must `cd` into before resuming, because both engines cwd-filter
    /// their sessions. Carried on the row (copied from the manifest entry) so the row is
    /// self-sufficient for building the resume command without re-reading the manifest.
    /// May be empty for a manifest entry that never recorded one.
    let workingDir: String
    /// Which coding-assistant engine PRODUCED this session (Claude Code or Codex),
    /// resolved from the manifest entry's `engineKind` tag (a legacy untagged entry
    /// predates engine tagging and reads as Claude Code). Drives which engine's NATIVE
    /// resume command the "Resume in Terminal" action builds and which binary it resolves —
    /// a Codex row resumes with `codex resume <thread_id>` via the codex binary even while
    /// Claude is the currently-selected engine.
    let engineKind: CoachEngineKind
    /// The durable RESUME identifier for this session, or nil when none is available (→ the
    /// "Resume in Terminal" action is hidden/disabled — never a dead resume). Claude resumes
    /// by its own session id (always present); Codex resumes by its `thread_id` (the persisted
    /// `codexThreadId`, else the id recovered from the transcript path for a run recorded before
    /// that field existed). Passed to `ResearchResumeCommandBuilder` as the resume id.
    let resumeIdentifier: String?
    /// The produced report.html for a finished research run, if any.
    let deliverablePath: String?
    let createdAt: Date
    let updatedAt: Date
    /// DISPLAY-only: true when the manifest recorded this session as DISMISSED (the
    /// user hid its toast chrome via ×). Drives the dimmed + "dismissed" tag treatment
    /// in the recents / History lists. Never affects the run. The grouped "Quick
    /// answers" row is never dismissed.
    let isDismissed: Bool
}

/// Pure conversion of manifest entries into sorted, display-ready History rows.
enum HistoryRowBuilder {

    /// The single collapsed title shown for the grouped warm/root ("Quick answers")
    /// entry. Every quick-answer turn belongs to ONE long-running warm session
    /// (captured under a fresh root session id each app launch), so they are collapsed
    /// into this one row rather than listed per launch / per utterance.
    static let quickAnswersGroupTitle = "Quick answers"

    /// Builds the History list, newest first. RESEARCH runs each remain their own row;
    /// every warm/root ("quick answer") entry is COLLAPSED into a single "Quick answers"
    /// row so the warm session reads as one long-running conversation instead of one row
    /// per app launch. Both the research rows and the grouped quick-answers row take part
    /// in the same reverse-chronological ordering by last activity.
    ///
    /// - Parameters:
    ///   - entries: the manifest's sessions, in write order.
    ///   - now: the reference time for relative timestamps. Injected so tests are
    ///     deterministic; the live window passes `Date()`.
    /// - Returns: rows sorted by `updatedAt` descending (most recently active on
    ///   top), tie-broken by `createdAt` descending, then `sessionId` for stability.
    static func makeRows(from entries: [ResearchManifestEntry], now: Date) -> [HistoryRow] {
        // Research runs pass through one-to-one; root/warm entries are grouped.
        var rows = entries
            .filter { $0.kind == .research }
            .map { entry in makeRow(from: entry, now: now) }

        let rootEntries = entries.filter { $0.kind == .root }
        if let quickAnswersRow = groupedQuickAnswersRow(from: rootEntries, now: now) {
            rows.append(quickAnswersRow)
        }

        return rows.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.sessionId > rhs.sessionId
        }
    }

    /// Builds one display row from a single manifest entry (used for research runs).
    static func makeRow(from entry: ResearchManifestEntry, now: Date) -> HistoryRow {
        HistoryRow(
            sessionId: entry.sessionId,
            kind: entry.kind,
            displayTitle: resolvedTitle(for: entry),
            kindBadge: kindBadge(for: entry.kind),
            status: entry.status,
            statusLabel: statusLabel(for: entry.status),
            relativeTimestamp: relativeTimestamp(from: entry.updatedAt, to: now),
            transcriptPath: entry.transcriptPath,
            workingDir: entry.workingDir,
            engineKind: engineKind(for: entry),
            resumeIdentifier: resumeIdentifier(for: entry),
            deliverablePath: entry.deliverablePath,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            isDismissed: entry.dismissed == true
        )
    }

    /// Collapses all warm/root entries into ONE "Quick answers" row, or nil when there
    /// are no root entries. The row's activity spans from the EARLIEST root `createdAt`
    /// to the LATEST root `updatedAt` (so it orders by its most recent quick answer),
    /// and it adopts the most-recently-active root entry's transcript so selecting the
    /// row shows the current warm conversation. Read-only: it invents no paths.
    static func groupedQuickAnswersRow(from rootEntries: [ResearchManifestEntry], now: Date) -> HistoryRow? {
        guard !rootEntries.isEmpty else { return nil }

        // The representative = the most recently active root session; its transcript is
        // the one the row surfaces.
        let representative = rootEntries.max { lhs, rhs in lhs.updatedAt < rhs.updatedAt } ?? rootEntries[0]
        let earliestCreatedAt = rootEntries.map(\.createdAt).min() ?? representative.createdAt
        let latestUpdatedAt = rootEntries.map(\.updatedAt).max() ?? representative.updatedAt

        return HistoryRow(
            sessionId: representative.sessionId,
            kind: .root,
            displayTitle: quickAnswersGroupTitle,
            kindBadge: kindBadge(for: .root),
            status: .active,
            statusLabel: statusLabel(for: .active),
            relativeTimestamp: relativeTimestamp(from: latestUpdatedAt, to: now),
            transcriptPath: representative.transcriptPath,
            workingDir: representative.workingDir,
            engineKind: engineKind(for: representative),
            resumeIdentifier: resumeIdentifier(for: representative),
            deliverablePath: nil,
            createdAt: earliestCreatedAt,
            updatedAt: latestUpdatedAt,
            isDismissed: false
        )
    }

    /// Prefer the explicit title; fall back to the task; finally a generic label so
    /// a row is never empty (root entries carry an empty `task`, for instance).
    static func resolvedTitle(for entry: ResearchManifestEntry) -> String {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedTask = entry.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTask.isEmpty {
            return trimmedTask
        }
        return entry.kind == .root ? "Quick-answer session" : "Untitled research"
    }

    static func kindBadge(for kind: ResearchSessionKind) -> String {
        switch kind {
        case .root: return "Root"
        case .research: return "Research"
        }
    }

    /// The coding-assistant engine that PRODUCED `entry`, from its `engineKind` tag. A legacy
    /// untagged entry (nil / unrecognized raw value) predates engine tagging — those entries
    /// are all Claude Code (Codex research parity landed after tagging), so they read as Claude.
    /// Mirrors `ResearchSessionManager.reconstructionEngineKind(for:)`; kept as a pure,
    /// nonisolated helper here so the (nonisolated, off-main-actor) row builder can resolve it
    /// without depending on the @MainActor session manager.
    static func engineKind(for entry: ResearchManifestEntry) -> CoachEngineKind {
        guard let rawEngineKind = entry.engineKind,
              let resolvedEngineKind = CoachEngineKind(rawValue: rawEngineKind) else {
            return .claudeCode
        }
        return resolvedEngineKind
    }

    /// The durable RESUME identifier for `entry`, or nil when none is available (→ the row's
    /// "Resume in Terminal" action is hidden). Claude resumes by its own session id (always
    /// present). Codex resumes by its `thread_id`: the persisted `codexThreadId` when present,
    /// else the id recovered from the transcript path (`rollout-<ts>-<thread_id>.jsonl`) for a
    /// run recorded before that field existed — a Codex run with neither has no resume handle.
    ///
    /// This mirrors `ResearchSessionManager.resumeHandle(for:)` (the reconstruction gate's
    /// resolver). That method is @MainActor-isolated (its type is), so it isn't reachable from
    /// this nonisolated, off-main-actor row builder; this is the sanctioned pure duplicate. Keep
    /// the two in sync — both must agree on what counts as a resumable identifier for an engine.
    static func resumeIdentifier(for entry: ResearchManifestEntry) -> String? {
        switch engineKind(for: entry) {
        case .claudeCode:
            return entry.sessionId
        case .codex:
            if let persistedThreadID = entry.codexThreadId, !persistedThreadID.isEmpty {
                return persistedThreadID
            }
            return CodexResearchEngine.threadID(fromTranscriptPath: entry.transcriptPath)
        }
    }

    static func statusLabel(for status: ResearchSessionStatus) -> String {
        switch status {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .active: return "Active"
        }
    }

    /// A compact relative description ("just now", "5 min ago", "2 hr ago", …).
    /// Deterministic given both dates so it's unit-testable.
    static func relativeTimestamp(from date: Date, to now: Date) -> String {
        let secondsElapsed = now.timeIntervalSince(date)
        // Guard against a future/clock-skewed timestamp reading as a huge negative.
        if secondsElapsed < 60 {
            return "just now"
        }
        let minutes = Int(secondsElapsed / 60)
        if minutes < 60 {
            return "\(minutes) min ago"
        }
        let hours = Int(secondsElapsed / 3600)
        if hours < 24 {
            return "\(hours) hr ago"
        }
        let days = Int(secondsElapsed / 86_400)
        if days < 7 {
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
        let weeks = days / 7
        return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    }
}

// MARK: - Transcript turns

/// The displayable kind of a single transcript turn. Tool activity is kept
/// separate from conversation text so the UI can render it compactly/collapsed.
enum TranscriptTurnKind: Equatable {
    /// A message the user (or the app's user text block) sent.
    case userMessage
    /// Assistant prose (the answer / narration).
    case assistantMessage
    /// A compact "the assistant called tool X" marker.
    case toolCall
    /// A compact, collapsed tool result.
    case toolResult
}

/// One readable turn extracted from the transcript, in file order.
struct TranscriptTurn: Identifiable, Equatable {
    /// Stable identity for SwiftUI — the turn's ordinal position in the file.
    let id: Int
    let kind: TranscriptTurnKind
    /// The primary text to show. Already trimmed; never empty for a produced turn.
    let text: String
    /// A short secondary label (e.g. a tool name) shown alongside `text`, if any.
    let detail: String?
}

/// The outcome of trying to load a transcript, so the UI can distinguish "the file
/// is gone" from "the file is here but has no conversation yet".
enum TranscriptLoadResult: Equatable {
    /// The transcript file does not exist (rolled away, never written, wrong path).
    case fileMissing
    /// The file parsed into these turns (possibly empty for a brand-new session).
    case parsed([TranscriptTurn])
}

/// Pure parser for a Claude Code transcript `.jsonl`. Each line is an independent
/// JSON record; we only surface `user` / `assistant` message records and reduce
/// them to readable turns. Everything else (mode, attachment, system, thinking,
/// file-history-snapshot, …) is intentionally ignored so the view stays readable.
enum TranscriptParser {

    /// Parses the full contents of a transcript file. Never throws: malformed lines
    /// are skipped individually so one bad record can't blank the whole conversation.
    static func parse(jsonlContents: String) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var nextTurnIndex = 0

        // Split on newlines; a trailing newline (or blank lines) just yields empties.
        let lines = jsonlContents.split(whereSeparator: \.isNewline)
        for line in lines {
            // `lines` was already split on newline characters, so trimming
            // whitespace-and-newlines here is equivalent to the previous
            // `.whitespaces` trim (no newline characters can remain in a segment).
            guard let record = decodeJSONLine(String(line)) else {
                // Blank / malformed / non-object line — skip gracefully.
                continue
            }

            guard let recordType = record["type"] as? String,
                  recordType == "user" || recordType == "assistant" else {
                continue
            }
            guard let message = record["message"] as? [String: Any] else { continue }

            let extractedTurns = turnsFromMessage(
                recordType: recordType,
                message: message,
                startingIndex: nextTurnIndex
            )
            turns.append(contentsOf: extractedTurns)
            nextTurnIndex += extractedTurns.count
        }

        return turns
    }

    /// Reduces one message record's `content` to zero or more turns.
    private static func turnsFromMessage(
        recordType: String,
        message: [String: Any],
        startingIndex: Int
    ) -> [TranscriptTurn] {
        let isUser = recordType == "user"
        var producedTurns: [TranscriptTurn] = []
        var nextIndex = startingIndex

        func append(_ kind: TranscriptTurnKind, _ text: String, detail: String? = nil) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || detail != nil else { return }
            producedTurns.append(
                TranscriptTurn(id: nextIndex, kind: kind, text: trimmed, detail: detail)
            )
            nextIndex += 1
        }

        // `content` is either a bare string (simple user text) or an array of blocks.
        if let contentString = message["content"] as? String {
            append(isUser ? .userMessage : .assistantMessage, contentString)
            return producedTurns
        }

        guard let contentBlocks = message["content"] as? [[String: Any]] else {
            return producedTurns
        }

        for block in contentBlocks {
            let blockType = block["type"] as? String
            switch blockType {
            case "text":
                let text = (block["text"] as? String) ?? ""
                append(isUser ? .userMessage : .assistantMessage, text)

            case "tool_use":
                let toolName = (block["name"] as? String) ?? "tool"
                append(.toolCall, toolCallSummary(for: block), detail: toolName)

            case "tool_result":
                append(.toolResult, toolResultSummary(for: block), detail: "result")

            // `thinking`, `image`, `fallback`, etc. are intentionally not rendered.
            default:
                continue
            }
        }

        return producedTurns
    }

    /// A one-line preview of a tool call: its most descriptive input field if we can
    /// find one, so the collapsed marker still tells the reader what happened.
    private static func toolCallSummary(for block: [String: Any]) -> String {
        guard let input = block["input"] as? [String: Any] else { return "" }
        // Prefer the fields humans recognize, in priority order.
        for key in ["description", "command", "prompt", "query", "path", "file_path", "pattern"] {
            if let value = input[key] as? String, !value.isEmpty {
                return firstLine(of: value)
            }
        }
        return ""
    }

    /// A short, collapsed preview of a tool result. The result `content` may be a
    /// string or an array of text blocks; we extract the first usable text and clip.
    private static func toolResultSummary(for block: [String: Any]) -> String {
        if let contentString = block["content"] as? String {
            return firstLine(of: contentString)
        }
        if let contentBlocks = block["content"] as? [[String: Any]] {
            for innerBlock in contentBlocks {
                if let text = innerBlock["text"] as? String, !text.isEmpty {
                    return firstLine(of: text)
                }
            }
        }
        return ""
    }

    /// Loads and parses the transcript at `filePath`, distinguishing "the file is
    /// gone" (`.fileMissing`) from "the file is here" (`.parsed`). A leading `~` is
    /// expanded; absolute paths pass through unchanged. Never throws — an unreadable
    /// file is treated like a missing one so the UI shows the same friendly
    /// placeholder. Testable directly against real temp files.
    ///
    /// SECURITY: the manifest lives under a user-writable directory, so its
    /// `transcriptPath` strings are NOT trusted. Before touching the disk we fence
    /// the path to `allowedRoots` (the Claude Code projects store + Clawdy's research
    /// root) using the fully-resolved canonical path — a tampered entry pointing at
    /// an arbitrary readable file (e.g. `/etc/passwd`, a `..` escape, or a symlink
    /// out of the fence) is rejected and treated exactly like a missing transcript.
    static func loadResult(
        forFileAtPath filePath: String,
        allowedRoots: [String] = historyTranscriptAllowedRoots()
    ) -> TranscriptLoadResult {
        guard isPathWithinAllowedRoots(filePath, roots: allowedRoots) else {
            return .fileMissing
        }
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return .fileMissing
        }
        guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return .fileMissing
        }
        return .parsed(parse(jsonlContents: contents))
    }

    /// Trims to the first line and caps length so a collapsed marker stays one line.
    private static func firstLine(of text: String) -> String {
        let firstLineSubstring = text.split(whereSeparator: \.isNewline).first ?? ""
        let firstLine = firstLineSubstring.trimmingCharacters(in: .whitespaces)
        let maximumPreviewLength = 140
        if firstLine.count > maximumPreviewLength {
            return String(firstLine.prefix(maximumPreviewLength)) + "…"
        }
        return firstLine
    }
}

// MARK: - Read-side path fence

/// Pure containment check used to fence every history READ/OPEN against the
/// user-writable manifest. The manifest stores paths verbatim, so a corrupted or
/// tampered entry could otherwise point the History window at an arbitrary
/// readable file. Nothing here writes or deletes — it only decides whether a path
/// is inside an allowed root.
extension TranscriptParser {

    /// The roots a transcript is legitimately allowed to live under:
    ///  (a) the Claude Code projects transcript store (`~/.claude/projects`), where
    ///      our `transcriptPath` genuinely points, and
    ///  (b) Clawdy's own research root under Application Support.
    static func historyTranscriptAllowedRoots() -> [String] {
        [
            ("~/.claude/projects" as NSString).expandingTildeInPath,
            ClaudeResearchEngine.researchSupportDirectory().path,
        ]
    }

    /// The single root a deliverable page is allowed to live under: Clawdy's
    /// research storage. Deliverables are always produced there.
    static func historyDeliverableAllowedRoots() -> [String] {
        [ClaudeResearchEngine.researchSupportDirectory().path]
    }

    /// True iff `path`, once expanded (`~`), symlink-resolved, and standardized, is
    /// contained within one of `roots` (each resolved the same way). The comparison
    /// is on fully-canonical PATH COMPONENTS — never a raw string prefix — so it is
    /// immune to `..` traversal, symlink escape, absolute-path override, and the
    /// `/foo/bar` vs `/foo/bar-evil` sibling-prefix trap. An empty/unresolvable path
    /// or root is rejected.
    static func isPathWithinAllowedRoots(_ path: String, roots: [String]) -> Bool {
        let candidateComponents = canonicalPathComponents(forPath: path)
        guard !candidateComponents.isEmpty else { return false }

        for root in roots {
            let rootComponents = canonicalPathComponents(forPath: root)
            guard !rootComponents.isEmpty else { continue }
            // Contained iff the candidate begins with the full root component list.
            // (Equal paths count as contained — a root itself is "within" itself.)
            if candidateComponents.count >= rootComponents.count
                && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents {
                return true
            }
        }
        return false
    }

    /// Fully canonicalizes a path to its resolved absolute components: expand `~`,
    /// standardize (collapsing `.`/`..`), then resolve any existing symlinks. The
    /// leading `/` element is dropped so two canonical paths compare component-wise.
    private static func canonicalPathComponents(forPath path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolvedURL = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return resolvedURL.pathComponents.filter { $0 != "/" }
    }
}
