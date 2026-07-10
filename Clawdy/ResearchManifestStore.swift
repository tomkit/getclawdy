//
//  ResearchManifestStore.swift
//  Clawdy
//
//  A tiny, Clawdy-owned JSON index of research (and root/warm) sessions. It is the
//  durable record the FUTURE History / continue-conversation UI will read to list
//  past runs and reopen or resume them — this slice builds ONLY the store and the
//  writes across a run's lifecycle, not any UI.
//
//  Each session Clawdy starts (a research run, or the warm quick-answer "root"
//  session) gets one `ResearchManifestEntry` keyed by its `sessionId`, recording
//  where its transcript lives (`~/.claude/projects/<sanitized-cwd>/<id>.jsonl`),
//  the stable working directory the session must be resumed FROM, and — for a
//  finished research run — the produced deliverable. Because a session is only
//  resumable from the directory it ran in (Claude Code keys sessions by CWD), the
//  manifest deliberately persists `workingDir` alongside `transcriptPath`.
//
//  The store is a small INJECTABLE type: production uses `ResearchManifestStore.shared`
//  (pointing at the real manifest.json under Application Support), while tests
//  construct one with a temp `fileURL` and a fixed `dateProvider` so the lifecycle
//  writes are fully unit-testable with no global state. All file access is
//  serialized on an internal lock so writes from the research coordinator (main
//  actor) and from the warm session's root-id capture (a background reader thread)
//  can't corrupt the file.
//

import Foundation

/// Which kind of Clawdy session an entry describes.
enum ResearchSessionKind: String, Codable, Equatable {
    /// An autonomous research run (plan + execute) that produces an HTML deliverable.
    case research
    /// The warm quick-answer "root" session (`ClaudePersistentSession`). Captured
    /// read-only so History can show/branch it later; Clawdy does NOT change how the
    /// warm session runs.
    case root
}

/// The lifecycle status of a session as the manifest last observed it.
enum ResearchSessionStatus: String, Codable, Equatable {
    /// A research run that is currently in flight (planning / awaiting input / executing).
    case running
    /// A research run that finished and produced a deliverable.
    case completed
    /// A research run that errored out.
    case failed
    /// A research run the user stopped.
    case stopped
    /// The warm root session — long-lived, no terminal state of its own.
    case active
}

/// One indexed session. `Codable`/`Equatable` so the whole manifest round-trips
/// through JSON and is trivially assertable in tests.
struct ResearchManifestEntry: Codable, Equatable {
    let sessionId: String
    let kind: ResearchSessionKind
    var title: String
    var task: String
    var status: ResearchSessionStatus
    let createdAt: Date
    var updatedAt: Date
    /// The directory the session ran in and MUST be resumed from (Claude Code keys
    /// sessions by working directory). For research this is the stable per-session
    /// dir; for the root session it is the warm process's working directory.
    var workingDir: String
    /// The `~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl` transcript path.
    var transcriptPath: String
    /// The produced HTML page for a finished research run; nil until completion (and
    /// always nil for the root session).
    var deliverablePath: String?
    /// DISPLAY-only: true once the user DISMISSED this session's toast (hid its chrome
    /// via the × control). Persisted so the recents / History lists can dim + tag a
    /// dismissed session DURABLY across relaunch. It NEVER affects the run — dismiss
    /// hides chrome, it does not stop the run. Optional so pre-existing manifests
    /// (written before this field existed) still decode: an absent value reads as
    /// "not dismissed".
    var dismissed: Bool? = nil
    /// Which research engine produced this session — the raw `CoachEngineKind` value
    /// (`"claude-code"` today; a future `"codex"` once Codex research parity lands).
    /// Optional and default-nil so pre-existing manifests (written before this field
    /// existed) still decode: an absent value means the entry predates engine tagging
    /// and is treated as the historical Claude engine. It is purely descriptive — it
    /// never changes how a run behaves.
    var engineKind: String? = nil
    /// For a Codex research run: the Codex `thread_id` this run produced, captured
    /// POST-HOC from the execute turn's `thread.started` event and persisted as the
    /// durable RESUME handle later stages (reconstruction / follow-up / resume-in-terminal)
    /// need. Codex has no pre-mintable session id — the run's `sessionId` here is a
    /// client-minted run id, NOT the Codex thread id — so this discrete field is where the
    /// thread id lives. Optional and default-nil so pre-existing manifests (and every
    /// Claude entry, which has no Codex thread) still decode. Nil for a Codex run that
    /// never captured a thread id; for a pre-persistence Codex run the id is still
    /// recoverable from `transcriptPath` via `CodexResearchEngine.threadID(fromTranscriptPath:)`.
    var codexThreadId: String? = nil
}

/// The on-disk manifest document: a version stamp plus the list of sessions. The
/// wrapper (rather than a bare array) leaves room to evolve the format later.
struct ResearchManifest: Codable, Equatable {
    var version: Int
    var sessions: [ResearchManifestEntry]

    static let currentVersion = 1

    static let empty = ResearchManifest(version: currentVersion, sessions: [])
}

/// Reads and writes the research manifest JSON. Injectable + thread-safe.
final class ResearchManifestStore: @unchecked Sendable {
    /// The process-wide store pointing at the real manifest under Application Support.
    /// The research coordinator and the warm root-id capture both default to this.
    static let shared = ResearchManifestStore()

    private let fileURL: URL
    private let dateProvider: () -> Date
    /// Serializes every read-modify-write so concurrent writers (the main-actor
    /// coordinator and the warm session's background reader) can't corrupt the file.
    private let accessLock = NSLock()

    /// - Parameters:
    ///   - fileURL: where the manifest JSON lives. Defaults to
    ///     `~/Library/Application Support/Clawdy/research/manifest.json`.
    ///   - dateProvider: supplies `createdAt`/`updatedAt`. Injectable so tests can
    ///     pin time and assert exact timestamps.
    init(
        fileURL: URL = ResearchManifestStore.defaultManifestFileURL(),
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.dateProvider = dateProvider
    }

    /// The real manifest location: a sibling of the per-session research directories.
    static func defaultManifestFileURL() -> URL {
        ClaudeResearchEngine.researchSupportDirectory()
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    // MARK: - Reads

    /// All indexed sessions in write order. Returns an empty array when the manifest
    /// doesn't exist yet or can't be parsed (a corrupt/absent index is treated as
    /// empty rather than crashing the app).
    func loadSessions() -> [ResearchManifestEntry] {
        accessLock.lock()
        defer { accessLock.unlock() }
        return readManifestLocked().sessions
    }

    // MARK: - Lifecycle writes

    /// Records a research run that just started: status `.running`, no deliverable
    /// yet, `createdAt == updatedAt`. Overwrites any prior entry for the same id.
    /// `engineKind` tags WHICH research engine produced the run (Claude Code or Codex);
    /// it defaults to Claude Code so pre-existing callers stay correct.
    func recordResearchSessionStarted(
        sessionId: String,
        title: String,
        task: String,
        workingDir: String,
        transcriptPath: String,
        engineKind: CoachEngineKind = .claudeCode
    ) {
        let now = dateProvider()
        let entry = ResearchManifestEntry(
            sessionId: sessionId,
            kind: .research,
            title: title,
            task: task,
            status: .running,
            createdAt: now,
            updatedAt: now,
            workingDir: workingDir,
            transcriptPath: transcriptPath,
            deliverablePath: nil,
            engineKind: engineKind.rawValue
        )
        upsert(entry)
    }

    /// Updates a research run's terminal status (completed / failed / stopped),
    /// bumps `updatedAt`, and — on completion — records the deliverable path.
    /// Preserves `createdAt` and all identity fields. No-op if the session is absent.
    func recordResearchSessionOutcome(
        sessionId: String,
        status: ResearchSessionStatus,
        deliverablePath: String?
    ) {
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        guard let index = manifest.sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return
        }
        // Belt-and-suspenders durable-state protection: a session that already finished
        // (`.completed`, a real deliverable on disk) must NEVER be regressed BACK to
        // `.failed`/`.stopped` by any caller. A transient later failure — e.g. a
        // follow-up turn on a completed run — otherwise corrupts a perfectly good
        // deliverable's durable record. Keep the `.completed` status + `deliverablePath`
        // intact; only refresh `updatedAt` as every write here already does. A
        // legitimate re-completion (`.completed`) or a first terminal write is
        // unaffected because it isn't a completed→failed/stopped regression.
        let storedStatus = manifest.sessions[index].status
        let isIllegalRegressionFromCompleted =
            storedStatus == .completed && (status == .failed || status == .stopped)
        if isIllegalRegressionFromCompleted {
            manifest.sessions[index].updatedAt = dateProvider()
            writeManifestLocked(manifest)
            return
        }
        manifest.sessions[index].status = status
        manifest.sessions[index].updatedAt = dateProvider()
        if let deliverablePath {
            manifest.sessions[index].deliverablePath = deliverablePath
        }
        writeManifestLocked(manifest)
    }

    /// Fills in a research entry's `transcriptPath` once it becomes resolvable — used by
    /// engines that only learn their transcript location POST-HOC (Codex, after its execute
    /// turn captures a `thread_id`). Deliberately touches NOTHING else (not status,
    /// updatedAt, or the deliverable), so it never reorders the recents/History lists or
    /// regresses a completed run. No-op if the session is absent or the path is empty.
    func recordResearchSessionTranscriptPath(sessionId: String, transcriptPath: String) {
        guard !transcriptPath.isEmpty else { return }
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        guard let index = manifest.sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return
        }
        manifest.sessions[index].transcriptPath = transcriptPath
        writeManifestLocked(manifest)
    }

    /// Persists the Codex `thread_id` — the durable RESUME handle discovered POST-HOC from
    /// a Codex execute turn's `thread.started` event — onto the run's manifest entry.
    /// Deliberately touches NOTHING else (not status, updatedAt, transcriptPath, or the
    /// deliverable), mirroring `recordResearchSessionTranscriptPath`, so it never reorders
    /// the recents/History lists or regresses a completed run. No-op if the session is
    /// absent from the manifest or the thread id is empty.
    func recordCodexThreadID(sessionId: String, threadID: String) {
        guard !threadID.isEmpty else { return }
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        guard let index = manifest.sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return
        }
        manifest.sessions[index].codexThreadId = threadID
        writeManifestLocked(manifest)
    }

    /// Records (or refreshes) the warm quick-answer "root" session captured from its
    /// stream init. Read-only w.r.t. the warm session itself — this only indexes it.
    func recordRootSession(
        sessionId: String,
        title: String,
        workingDir: String,
        transcriptPath: String
    ) {
        let now = dateProvider()
        // `createdAt` here is a placeholder — `upsertPreservingCreatedAt` swaps in the
        // stored one under a SINGLE lock so no concurrent writer can slip between the
        // read and the write.
        let entry = ResearchManifestEntry(
            sessionId: sessionId,
            kind: .root,
            title: title,
            task: "",
            status: .active,
            createdAt: now,
            updatedAt: now,
            workingDir: workingDir,
            transcriptPath: transcriptPath,
            deliverablePath: nil,
            // The warm quick-answer session is a Claude Code process.
            engineKind: CoachEngineKind.claudeCode.rawValue
        )
        upsertPreservingCreatedAt(entry)
    }

    /// Persists the DISPLAY-only `dismissed` flag for a session (the user hid its toast
    /// chrome via ×). Deliberately does NOT touch `status` or `updatedAt` — dismiss is
    /// not stop, and it must not reorder the recents/History lists. No-op if the
    /// session is absent from the manifest.
    func recordSessionDismissed(sessionId: String, dismissed: Bool) {
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        guard let index = manifest.sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return
        }
        manifest.sessions[index].dismissed = dismissed
        writeManifestLocked(manifest)
    }

    /// Inserts `entry`, or replaces an existing entry with the same `sessionId` while
    /// PRESERVING that entry's original `createdAt`. A SINGLE locked read-modify-write,
    /// so the createdAt preservation can't race a concurrent writer (the background
    /// warm-root capture) the way a separate `loadSessions()` + `upsert()` could —
    /// there is no gap between the read and the write for another writer to slip into.
    /// Behavior is otherwise identical to `upsert`.
    private func upsertPreservingCreatedAt(_ entry: ResearchManifestEntry) {
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        if let index = manifest.sessions.firstIndex(where: { $0.sessionId == entry.sessionId }) {
            // `createdAt` is a `let`, so rebuild the entry with the stored createdAt
            // rather than mutating in place. Everything else is the fresh entry, exactly
            // as the old `upsert(entry)` replacement wrote it.
            let preservedCreatedAt = manifest.sessions[index].createdAt
            let preservedEntry = ResearchManifestEntry(
                sessionId: entry.sessionId,
                kind: entry.kind,
                title: entry.title,
                task: entry.task,
                status: entry.status,
                createdAt: preservedCreatedAt,
                updatedAt: entry.updatedAt,
                workingDir: entry.workingDir,
                transcriptPath: entry.transcriptPath,
                deliverablePath: entry.deliverablePath,
                dismissed: entry.dismissed,
                engineKind: entry.engineKind,
                codexThreadId: entry.codexThreadId
            )
            manifest.sessions[index] = preservedEntry
        } else {
            manifest.sessions.append(entry)
        }
        writeManifestLocked(manifest)
    }

    /// Inserts `entry`, or replaces an existing entry with the same `sessionId`.
    func upsert(_ entry: ResearchManifestEntry) {
        accessLock.lock()
        defer { accessLock.unlock() }
        var manifest = readManifestLocked()
        if let index = manifest.sessions.firstIndex(where: { $0.sessionId == entry.sessionId }) {
            manifest.sessions[index] = entry
        } else {
            manifest.sessions.append(entry)
        }
        writeManifestLocked(manifest)
    }

    // MARK: - File I/O (caller must hold accessLock)

    private func readManifestLocked() -> ResearchManifest {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }
        guard let manifest = try? Self.jsonDecoder.decode(ResearchManifest.self, from: data) else {
            return .empty
        }
        return manifest
    }

    private func writeManifestLocked(_ manifest: ResearchManifest) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.jsonEncoder.encode(manifest)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A failed manifest write must never take down a research run or the
            // warm session — it only means History will be missing this entry.
            print("⚠️ ResearchManifestStore: write failed: \(error)")
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
