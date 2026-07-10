//
//  ResearchResumeCommandTests.swift
//  ClawdyTests
//
//  Covers the pure "Resume in Terminal" command builder — the two-layer quoting
//  (POSIX shell + AppleScript string literal) that is easy to get subtly wrong, the
//  per-engine native resume verb (`--resume` flag vs `resume` subcommand), and the
//  fact that the app-RESOLVED absolute binary path is embedded (never a bare name).
//  Also asserts that `HistoryRow` now carries the session's working directory so a
//  row is self-sufficient for building its resume command.
//

import Testing
import Foundation
@testable import Clawdy

struct ResearchResumeCommandBuilderTests {

    // MARK: - POSIX quoting

    @Test func posixQuotingWrapsPlainValueInSingleQuotes() {
        #expect(ResearchResumeCommandBuilder.posixQuoted("abc") == "'abc'")
    }

    @Test func posixQuotingKeepsAPathWithSpacesAsOneWord() {
        let quoted = ResearchResumeCommandBuilder.posixQuoted("/Users/me/Library/Application Support/Clawdy")
        #expect(quoted == "'/Users/me/Library/Application Support/Clawdy'")
    }

    @Test func posixQuotingEscapesEmbeddedSingleQuoteWithClassicSequence() {
        // A single quote must close the quote, emit an escaped literal quote, and reopen it.
        let quoted = ResearchResumeCommandBuilder.posixQuoted("/tmp/O'Brien/work")
        #expect(quoted == "'/tmp/O'\\''Brien/work'")
    }

    // MARK: - AppleScript escaping

    @Test func appleScriptEscapingEscapesDoubleQuotes() {
        #expect(ResearchResumeCommandBuilder.appleScriptQuoted("say \"hi\"") == "say \\\"hi\\\"")
    }

    @Test func appleScriptEscapingEscapesBackslashBeforeQuotes() {
        // Backslash MUST be escaped first, so `\"` becomes `\\\"` (escaped backslash + escaped quote).
        #expect(ResearchResumeCommandBuilder.appleScriptQuoted("a\\b") == "a\\\\b")
        #expect(ResearchResumeCommandBuilder.appleScriptQuoted("a\\\"b") == "a\\\\\\\"b")
    }

    // MARK: - Per-engine shell command

    @Test func claudeUsesResumeFlagAndCdsIntoWorkingDir() {
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .claudeCode,
            binaryPath: "/opt/homebrew/bin/claude",
            workingDir: "/Users/me/Library/Application Support/Clawdy/research/abc",
            sessionId: "abc-123"
        )
        #expect(command == "cd '/Users/me/Library/Application Support/Clawdy/research/abc' && '/opt/homebrew/bin/claude' --resume 'abc-123'")
    }

    @Test func codexUsesResumeSubcommandNotAFlag() {
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .codex,
            binaryPath: "/usr/local/bin/codex",
            workingDir: "/tmp/work",
            sessionId: "sess-9"
        )
        #expect(command == "cd '/tmp/work' && '/usr/local/bin/codex' resume 'sess-9'")
        // Codex must NOT get the Claude `--resume` flag form.
        #expect(!command.contains("--resume"))
    }

    @Test func resolvedAbsoluteBinaryPathIsEmbeddedNotABareName() {
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .claudeCode,
            binaryPath: "/Users/me/.nvm/versions/node/v20.0.0/bin/claude",
            workingDir: "/tmp/work",
            sessionId: "id"
        )
        // The full resolved path is embedded (quoted); the invocation is never a bare `claude`.
        #expect(command.contains("'/Users/me/.nvm/versions/node/v20.0.0/bin/claude'"))
        #expect(!command.contains("&& 'claude'"))
        #expect(!command.contains("&& claude "))
    }

    @Test func workingDirAndBinaryWithSpacesStayIntactWords() {
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .claudeCode,
            binaryPath: "/Applications/My Tools/claude",
            workingDir: "/Users/me/Research Runs/abc",
            sessionId: "abc"
        )
        #expect(command == "cd '/Users/me/Research Runs/abc' && '/Applications/My Tools/claude' --resume 'abc'")
    }

    // MARK: - Adversarial shell metacharacters stay inert

    @Test func posixQuotingKeepsShellMetacharactersLiteralInsideSingleQuotes() {
        // Inside single quotes the shell treats every one of these as a literal character — no
        // variable expansion (`$`), no command substitution (backtick), no command separators
        // (`;`), no background/pipe/redirect (`&`, `|`, `>`).
        let adversarial = "/tmp/a$b`c;d&e|f>g"
        #expect(ResearchResumeCommandBuilder.posixQuoted(adversarial) == "'/tmp/a$b`c;d&e|f>g'")
    }

    @Test func posixQuotingKeepsANewlineLiteralAsOneWord() {
        // A newline inside single quotes stays part of the one quoted word — it can't split the
        // command into a second line/command.
        #expect(ResearchResumeCommandBuilder.posixQuoted("a\nb") == "'a\nb'")
    }

    @Test func shellCommandWithMetacharactersInWorkingDirAndSessionIdStaysSingleQuoted() {
        // A working dir AND session id full of shell metacharacters must produce a command in
        // which each is a single-quoted, inert argument — no breakout into extra commands.
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .claudeCode,
            binaryPath: "/opt/homebrew/bin/claude",
            workingDir: "/tmp/a$b`c;d e&f|g",
            sessionId: "id$(rm -rf);`whoami`"
        )
        #expect(command == "cd '/tmp/a$b`c;d e&f|g' && '/opt/homebrew/bin/claude' --resume 'id$(rm -rf);`whoami`'")
        // The command has EXACTLY one `&&` (the intentional cd→resume join) — the `&` inside the
        // quoted dir did not introduce another shell operator.
        #expect(command.components(separatedBy: "&&").count == 2)
    }

    @Test func shellCommandWithNewlineInWorkingDirKeepsItInsideTheQuotedArgument() {
        let command = ResearchResumeCommandBuilder.shellCommand(
            engine: .claudeCode,
            binaryPath: "/bin/claude",
            workingDir: "/tmp/line1\nline2",
            sessionId: "id"
        )
        // The newline stays inside the single-quoted dir; the command still begins with `cd '`.
        #expect(command == "cd '/tmp/line1\nline2' && '/bin/claude' --resume 'id'")
    }

    // MARK: - Adversarial AppleScript content stays inert

    @Test func appleScriptContentPassesShellMetacharactersThroughVerbatim() {
        // `$`, backtick, and `;` have no meaning in an AppleScript string literal, so they pass
        // through unescaped — but must still appear verbatim (no accidental mangling) inside the
        // `do script "…"` string, never breaking out of it.
        let shellCommand = "cd '/tmp/a$b`c;d' && '/bin/claude' --resume 'id'"
        let script = ResearchResumeCommandBuilder.terminalAppleScript(shellCommand: shellCommand)
        #expect(script.contains("do script \"cd '/tmp/a$b`c;d' && '/bin/claude' --resume 'id'\""))
    }

    @Test func appleScriptEscapingNeutralizesAQuoteThatWouldCloseTheStringEarly() {
        // The one AppleScript-dangerous character in shell output is an unescaped double quote;
        // it must be escaped so it can't terminate the string literal and inject AppleScript.
        let shellCommand = "cd '/tmp/x' && '/bin/claude' --resume 'a\"b'"
        let script = ResearchResumeCommandBuilder.terminalAppleScript(shellCommand: shellCommand)
        // The embedded quote is escaped as \" — the string literal is not closed early.
        #expect(script.contains("--resume 'a\\\"b'"))
        // Exactly the opening + closing quotes of the do-script literal remain UNescaped: the
        // total count of `"` chars is the 2 delimiters plus the 2 chars of each `\"` escape.
        #expect(script.contains("do script \"cd '/tmp/x' && '/bin/claude' --resume 'a\\\"b'\""))
    }

    // MARK: - Terminal AppleScript

    @Test func terminalAppleScriptOpensAWindowRunsTheCommandAndActivates() {
        let shellCommand = "cd '/tmp/work' && '/opt/homebrew/bin/claude' --resume 'abc'"
        let script = ResearchResumeCommandBuilder.terminalAppleScript(shellCommand: shellCommand)
        // Opens/runs in Terminal via `do script` and brings it to the front via `activate`.
        #expect(script.contains("tell application \"Terminal\" to do script"))
        #expect(script.contains("activate"))
        // The single quotes from the shell command survive untouched (only backslash/double-quote
        // are AppleScript-escaped, and there are none here).
        #expect(script.contains("cd '/tmp/work' && '/opt/homebrew/bin/claude' --resume 'abc'"))
    }

    @Test func terminalAppleScriptEscapesADoubleQuoteInTheShellCommand() {
        // A (contrived) shell command containing a double quote must be escaped so it can't
        // terminate the AppleScript string literal early.
        let shellCommand = "echo \"hi\""
        let script = ResearchResumeCommandBuilder.terminalAppleScript(shellCommand: shellCommand)
        #expect(script.contains("do script \"echo \\\"hi\\\"\""))
    }
}

// MARK: - HistoryRow carries workingDir

struct HistoryRowWorkingDirTests {

    private func makeEntry(sessionId: String, kind: ResearchSessionKind, workingDir: String) -> ResearchManifestEntry {
        ResearchManifestEntry(
            sessionId: sessionId,
            kind: kind,
            title: "T",
            task: "task",
            status: kind == .root ? .active : .completed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workingDir: workingDir,
            transcriptPath: "\(("~/.claude/projects" as NSString).expandingTildeInPath)/\(sessionId).jsonl",
            deliverablePath: nil
        )
    }

    @Test func researchRowCarriesTheEntryWorkingDir() {
        let entry = makeEntry(sessionId: "r1", kind: .research, workingDir: "/tmp/research/r1")
        let row = HistoryRowBuilder.makeRow(from: entry, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row.workingDir == "/tmp/research/r1")
    }

    @Test func groupedQuickAnswersRowCarriesTheRepresentativeWorkingDir() {
        let root = makeEntry(sessionId: "root-1", kind: .root, workingDir: "/Users/me")
        let row = HistoryRowBuilder.groupedQuickAnswersRow(from: [root], now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(row?.workingDir == "/Users/me")
    }
}
