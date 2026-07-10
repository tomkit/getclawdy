//
//  ResearchHistoryResumeCodexTests.swift
//  ClawdyTests
//
//  Stage D of Codex research parity: the History window's "Resume in Terminal" action must
//  work for CODEX sessions, not just Claude — launching Codex's native resume
//  (`codex resume <thread_id>`, run in the session's working dir) exactly like the Claude
//  path launches `claude --resume <id>`. This is PASSTHROUGH to the CLI's native resume; no
//  emulation.
//
//  Covers, headlessly:
//   1. The pure engine + resume-identifier threading onto `HistoryRow`
//      (`HistoryRowBuilder.engineKind(for:)` / `.resumeIdentifier(for:)`): a Codex row carries
//      `.codex` + its `thread_id` (persisted, or recovered from the rollout transcript path); a
//      Claude row is unchanged (`.claudeCode` + its session id); a Codex run with no thread id
//      has NO resume identifier.
//   2. The pure resume-command build for a Codex row (`ResearchResumeCommandBuilder`) with the
//      correct `codex resume <thread_id>`, cwd, and CODEX binary path — and that a Claude row
//      still builds the byte-for-byte-unchanged `claude --resume <id>` command.
//   3. The `ResearchHistoryViewModel` render-time gate: `resumeEngine(for:)` returns the row's
//      producing engine (not hardcoded Claude), and `canResumeInTerminal(for:)` hides the button
//      for a row with no resumable identifier.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Pure: engineKind + resumeIdentifier threaded onto the row

struct HistoryRowEngineResumeIdentifierTests {

    /// Builds a manifest entry with the fields this slice cares about (engine, thread id,
    /// transcript path) and sensible defaults for everything else.
    private func makeEntry(
        sessionId: String,
        kind: ResearchSessionKind = .research,
        status: ResearchSessionStatus = .completed,
        workingDir: String = "/tmp/research/session",
        transcriptPath: String,
        engineKind: String?,
        codexThreadId: String? = nil
    ) -> ResearchManifestEntry {
        ResearchManifestEntry(
            sessionId: sessionId,
            kind: kind,
            title: "T",
            task: "task",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workingDir: workingDir,
            transcriptPath: transcriptPath,
            deliverablePath: nil,
            engineKind: engineKind,
            codexThreadId: codexThreadId
        )
    }

    @Test func claudeRowCarriesClaudeEngineAndSessionIdAsResumeIdentifier() {
        let entry = makeEntry(
            sessionId: "claude-abc",
            transcriptPath: "/tmp/research/session/claude-abc.jsonl",
            engineKind: CoachEngineKind.claudeCode.rawValue
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.engineKind == .claudeCode)
        // Claude resumes by its own session id — unchanged from before this slice.
        #expect(row.resumeIdentifier == "claude-abc")
    }

    @Test func legacyUntaggedEntryReadsAsClaudeAndResumesBySessionId() {
        // An entry written before engine tagging existed (engineKind == nil) predates Codex
        // research, so it must read as Claude and resume by its session id.
        let entry = makeEntry(
            sessionId: "legacy-1",
            transcriptPath: "/tmp/research/session/legacy-1.jsonl",
            engineKind: nil
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.engineKind == .claudeCode)
        #expect(row.resumeIdentifier == "legacy-1")
    }

    @Test func codexRowCarriesCodexEngineAndPersistedThreadIdAsResumeIdentifier() {
        let entry = makeEntry(
            sessionId: "codex-run-1", // a client-minted run id, NOT the resume handle
            transcriptPath: "/tmp/research/session/rollout-2025-01-15T10-30-00-thread-xyz.jsonl",
            engineKind: CoachEngineKind.codex.rawValue,
            codexThreadId: "thread-persisted-9"
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.engineKind == .codex)
        // The RESUME identifier for Codex is the thread id, NOT the client-minted run id.
        #expect(row.resumeIdentifier == "thread-persisted-9")
    }

    @Test func codexRowRecoversThreadIdFromTranscriptPathWhenNotPersisted() {
        // A Codex run recorded BEFORE `codexThreadId` was persisted: the thread id is recovered
        // from the rollout transcript filename `rollout-<ts>-<thread_id>.jsonl`.
        let entry = makeEntry(
            sessionId: "codex-run-2",
            transcriptPath: "/tmp/research/session/rollout-2025-01-15T10-30-00-recovered-thread-42.jsonl",
            engineKind: CoachEngineKind.codex.rawValue,
            codexThreadId: nil
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.engineKind == .codex)
        #expect(row.resumeIdentifier == "recovered-thread-42")
    }

    @Test func codexRowWithNoPersistedOrRecoverableThreadIdHasNilResumeIdentifier() {
        // Neither a persisted thread id nor a rollout-shaped transcript path → no resume handle.
        let entry = makeEntry(
            sessionId: "codex-run-3",
            transcriptPath: "/tmp/research/session/not-a-rollout.jsonl",
            engineKind: CoachEngineKind.codex.rawValue,
            codexThreadId: nil
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.engineKind == .codex)
        #expect(row.resumeIdentifier == nil)
    }
}

// MARK: - Pure: the resume command built from a row

struct HistoryRowResumeCommandTests {

    /// The exact codex resume command a Codex History row produces: `codex resume <thread_id>`
    /// run FROM the session's working dir, using the app-RESOLVED absolute codex binary path.
    @Test func codexRowBuildsCodexResumeSubcommandWithThreadIdAndCwd() {
        let entry = ResearchManifestEntry(
            sessionId: "codex-run-1",
            kind: .research,
            title: "Winter photo spots",
            task: "Winter photo spots",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workingDir: "/Users/me/Library/Application Support/Clawdy/research/codex-run-1",
            transcriptPath: "/tmp/rollout-2025-01-15T10-30-00-thread-xyz.jsonl",
            deliverablePath: nil,
            engineKind: CoachEngineKind.codex.rawValue,
            codexThreadId: "thread-xyz"
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))

        // The producing engine drives the native resume verb + the binary resolved.
        let resumeEngine: ResearchResumeEngine = row.engineKind == .codex ? .codex : .claudeCode
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: resumeEngine,
            binaryPath: "/opt/homebrew/bin/codex",
            workingDir: row.workingDir,
            sessionId: row.resumeIdentifier ?? ""
        )

        #expect(command == "cd '/Users/me/Library/Application Support/Clawdy/research/codex-run-1' && '/opt/homebrew/bin/codex' resume 'thread-xyz'")
        // Codex uses the `resume` SUBCOMMAND, never Claude's `--resume` flag.
        #expect(!command.contains("--resume"))
    }

    /// A Claude History row still builds the byte-for-byte-unchanged `claude --resume <id>`.
    @Test func claudeRowBuildsUnchangedClaudeResumeFlagCommand() {
        let entry = ResearchManifestEntry(
            sessionId: "claude-abc",
            kind: .research,
            title: "Dig",
            task: "Dig",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workingDir: "/Users/me/Library/Application Support/Clawdy/research/claude-abc",
            transcriptPath: "/tmp/claude-abc.jsonl",
            deliverablePath: nil,
            engineKind: CoachEngineKind.claudeCode.rawValue,
            codexThreadId: nil
        )
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))

        let resumeEngine: ResearchResumeEngine = row.engineKind == .codex ? .codex : .claudeCode
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: resumeEngine,
            binaryPath: "/opt/homebrew/bin/claude",
            workingDir: row.workingDir,
            sessionId: row.resumeIdentifier ?? ""
        )

        #expect(command == "cd '/Users/me/Library/Application Support/Clawdy/research/claude-abc' && '/opt/homebrew/bin/claude' --resume 'claude-abc'")
    }
}

// MARK: - View model: per-engine resume gate

@MainActor
struct HistoryResumeViewModelTests {

    /// Builds a view model backed by a temp manifest holding ONE research entry produced by
    /// `engineKind`, optionally persisting a Codex `thread_id`, and selects it. `resolveBinary`
    /// is wired as the "Resume in Terminal" binary resolver (the cached-registry read the live
    /// app injects); pass nil to leave it at the safe no-op (nothing resolvable → button hidden).
    private func makeSelectedViewModel(
        sessionId: String,
        engineKind: CoachEngineKind,
        codexThreadId: String? = nil,
        transcriptFileName: String? = nil,
        resolveBinary: (@MainActor (ResearchResumeEngine) -> String?)? = nil
    ) -> ResearchHistoryViewModel {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdy-history-resume-\(sessionId)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ResearchManifestStore(fileURL: manifestURL, dateProvider: { fixedDate })
        let transcriptPath = tempDir.appendingPathComponent(transcriptFileName ?? "\(sessionId).jsonl").path
        store.recordResearchSessionStarted(
            sessionId: sessionId,
            title: "Best winter photo spots",
            task: "Best winter photo spots",
            workingDir: tempDir.path,
            transcriptPath: transcriptPath,
            engineKind: engineKind
        )
        store.recordResearchSessionOutcome(
            sessionId: sessionId,
            status: .completed,
            deliverablePath: tempDir.appendingPathComponent("report.html").path
        )
        if let codexThreadId {
            store.recordCodexThreadID(sessionId: sessionId, threadID: codexThreadId)
        }

        let viewModel = ResearchHistoryViewModel(manifestStore: store)
        if let resolveBinary {
            viewModel.resolveResumeBinaryPath = resolveBinary
        }
        viewModel.refresh()
        viewModel.select(rowID: sessionId)
        return viewModel
    }

    private func selectedRow(_ viewModel: ResearchHistoryViewModel, sessionId: String) -> HistoryRow {
        viewModel.rows.first(where: { $0.id == sessionId })!
    }

    @Test func codexRowResolvesCodexEngineAndCanResumeWhenCodexBinaryPresent() {
        let viewModel = makeSelectedViewModel(
            sessionId: "codex-1",
            engineKind: .codex,
            codexThreadId: "thread-abc",
            resolveBinary: { engine in
                switch engine {
                case .claudeCode: return "/opt/homebrew/bin/claude"
                case .codex: return "/opt/homebrew/bin/codex"
                }
            }
        )
        let row = selectedRow(viewModel, sessionId: "codex-1")

        // The engine is the PRODUCING engine (Codex), not hardcoded Claude.
        #expect(viewModel.resumeEngine(for: row) == .codex)
        #expect(row.resumeIdentifier == "thread-abc")
        // Working dir + resume identifier + resolvable codex binary → button shown.
        #expect(viewModel.canResumeInTerminal(for: row))
    }

    @Test func codexRowWithoutResolvableCodexBinaryHidesResume() {
        // Codex produced the run and it has a thread id, but the codex binary isn't resolvable
        // (Codex not installed) → the button is hidden (no dead resume with a bare name).
        let viewModel = makeSelectedViewModel(
            sessionId: "codex-2",
            engineKind: .codex,
            codexThreadId: "thread-abc",
            resolveBinary: { engine in
                switch engine {
                case .claudeCode: return "/opt/homebrew/bin/claude"
                case .codex: return nil
                }
            }
        )
        let row = selectedRow(viewModel, sessionId: "codex-2")
        #expect(viewModel.resumeEngine(for: row) == .codex)
        #expect(!viewModel.canResumeInTerminal(for: row))
    }

    @Test func codexRowWithNoResumeIdentifierHidesResumeEvenWithBinary() {
        // A Codex run with neither a persisted thread id nor a rollout-shaped transcript path has
        // no resume handle → the button is hidden even though the codex binary resolves.
        let viewModel = makeSelectedViewModel(
            sessionId: "codex-3",
            engineKind: .codex,
            codexThreadId: nil,
            transcriptFileName: "not-a-rollout.jsonl",
            resolveBinary: { _ in "/opt/homebrew/bin/codex" }
        )
        let row = selectedRow(viewModel, sessionId: "codex-3")
        #expect(row.resumeIdentifier == nil)
        #expect(!viewModel.canResumeInTerminal(for: row))
    }

    @Test func claudeRowResolvesClaudeEngineAndCanResume() {
        // The Claude path is unchanged: engine resolves to Claude, session id is the handle, and
        // the button shows when the claude binary resolves.
        let viewModel = makeSelectedViewModel(
            sessionId: "claude-9",
            engineKind: .claudeCode,
            resolveBinary: { engine in
                switch engine {
                case .claudeCode: return "/opt/homebrew/bin/claude"
                case .codex: return nil
                }
            }
        )
        let row = selectedRow(viewModel, sessionId: "claude-9")
        #expect(viewModel.resumeEngine(for: row) == .claudeCode)
        #expect(row.resumeIdentifier == "claude-9")
        #expect(viewModel.canResumeInTerminal(for: row))
    }
}
