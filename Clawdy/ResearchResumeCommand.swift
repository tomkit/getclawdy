//
//  ResearchResumeCommand.swift
//  Clawdy
//
//  Pure, AppKit-free, unit-testable builder for the "Resume in Terminal" action on
//  the Research History window. Given a session's engine, the app-resolved absolute
//  CLI binary path, its working directory, and its session id, it produces:
//
//    1. the SHELL command that resumes that session with the ENGINE'S NATIVE resume
//       command, run FROM the session's working directory
//       (Claude: `cd '<dir>' && '<binary>' --resume '<id>'`,
//        Codex:  `cd '<dir>' && '<binary>' resume '<id>'`), and
//    2. the AppleScript that tells Terminal to open a window, run that shell command,
//       and activate (bring Terminal to the front).
//
//  BOTH escaping layers live here so they are covered by unit tests:
//   - `posixQuoted` wraps a value in single quotes for the POSIX shell (escaping any
//     embedded single quote as the classic `'\''` sequence), so a working directory
//     or binary path containing spaces or quotes stays one intact argument, and
//   - `appleScriptQuoted` escapes a string for embedding inside an AppleScript string
//     literal (backslash and double-quote), so the shell command survives being
//     nested inside `do script "…"`.
//
//  Nothing here touches AppKit, the filesystem, or `NSAppleScript` — the History view
//  model owns actually executing the produced AppleScript. This keeps the two-layer
//  quoting/escaping (the part that is easy to get subtly wrong) fully testable.
//

import Foundation

/// The coding-assistant engine whose NATIVE resume command should be built. Kept
/// engine-agnostic so Codex parity slots in later; all sessions recorded today are
/// Claude, so callers currently pass `.claudeCode`.
enum ResearchResumeEngine: Equatable {
    case claudeCode
    case codex
}

/// Pure constructors for the "Resume in Terminal" shell command + Terminal AppleScript.
enum ResearchResumeCommandBuilder {

    /// The POSIX shell command that resumes `sessionId` with `engine`'s native resume
    /// subcommand, run FROM `workingDir` (both engines cwd-filter their sessions, so the
    /// resume must happen in the directory the session was created in). `binaryPath` is the
    /// app-RESOLVED absolute path to the CLI (never a bare name) — Terminal's login-shell
    /// PATH may not include the same dirs Clawdy augments, so we embed the full path.
    ///
    /// Produces, for Claude Code:
    ///   `cd '<workingDir>' && '<binaryPath>' --resume '<sessionId>'`
    /// and for Codex:
    ///   `cd '<workingDir>' && '<binaryPath>' resume '<sessionId>'`
    ///
    /// Every interpolated value is `posixQuoted` so spaces / quotes in a path or id can't
    /// break the command into extra words.
    static func shellCommand(
        engine: ResearchResumeEngine,
        binaryPath: String,
        workingDir: String,
        sessionId: String
    ) -> String {
        let quotedWorkingDir = posixQuoted(workingDir)
        let quotedBinaryPath = posixQuoted(binaryPath)
        let quotedSessionId = posixQuoted(sessionId)

        // Claude uses the `--resume <id>` flag; Codex uses the `resume <id>` subcommand.
        // Both are cwd-filtered, so both are run after `cd`-ing into the working directory.
        let resumeInvocation: String
        switch engine {
        case .claudeCode:
            resumeInvocation = "\(quotedBinaryPath) --resume \(quotedSessionId)"
        case .codex:
            resumeInvocation = "\(quotedBinaryPath) resume \(quotedSessionId)"
        }

        return "cd \(quotedWorkingDir) && \(resumeInvocation)"
    }

    /// The AppleScript that opens a Terminal window running `shellCommand`, then brings
    /// Terminal to the front. `do script` (with no target window) opens a NEW window and
    /// runs the command in it; `activate` focuses Terminal so the user sees it. The shell
    /// command is `appleScriptQuoted` so quotes/backslashes in it don't terminate the
    /// AppleScript string literal early.
    static func terminalAppleScript(shellCommand: String) -> String {
        let escapedShellCommand = appleScriptQuoted(shellCommand)
        return """
        tell application "Terminal" to do script "\(escapedShellCommand)"
        tell application "Terminal" to activate
        """
    }

    /// Wraps `value` in single quotes for the POSIX shell, escaping any embedded single
    /// quote as the classic `'\''` sequence (close the quote, an escaped literal quote,
    /// reopen the quote). Inside single quotes the shell treats everything else — spaces,
    /// double quotes, backslashes, `$`, `&&` — as literal, so this makes `value` exactly
    /// one shell word regardless of its contents.
    static func posixQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Escapes `value` for embedding inside an AppleScript double-quoted string literal:
    /// backslashes first (so we don't double-escape the ones we add next), then double
    /// quotes. Order matters — backslash MUST be escaped before quote.
    static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
