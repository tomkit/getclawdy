//
//  ResearchArguments.swift
//  Clawdy
//
//  Pure constructors for the two `claude` argument vectors the research subsystem
//  runs. Static and side-effect-free so the exact command lines are unit-testable
//  without launching anything — exactly like `ClaudeCodeEngine.makeArguments`.
//
//  The research subsystem is a SEPARATE process from the warm quick-answer
//  session; it deliberately enables a NARROW tool allowlist and writes its
//  deliverable to a scoped temp dir. It is run in two phases:
//
//  `--safe-mode` on BOTH phases is now gated on the single app-wide "Use my Claude
//  Code setup" setting (`useClaudeCustomizations`, default true): true OMITS it so the
//  user's own `claude` setup loads on research too; false ADDS it to isolate the run.
//  The command lines below show the ISOLATED form (setting OFF).
//
//  PLAN/CLARIFY (the model decides whether it needs to ask the user anything):
//
//    claude -p "<task>" \
//      --append-system-prompt "<research plan system prompt>" \
//      --permission-mode plan \
//      [--safe-mode]            # only when useClaudeCustomizations == false
//      --output-format stream-json --verbose \
//      --model sonnet
//
//  EXECUTE (resume the SAME session, switch to autonomous tool use):
//
//    claude -p "<answers + proceed>" \
//      --resume <session_id> \
//      --append-system-prompt "<research execute system prompt>" \
//      --permission-mode acceptEdits \
//      [--safe-mode]            # only when useClaudeCustomizations == false
//      --allowedTools WebSearch WebFetch Write \
//      --add-dir <output dir> \
//      --max-budget-usd <cap> \
//      --output-format stream-json --verbose \
//      --model sonnet
//
//  Billing note: NEITHER phase passes `--bare`, so both bill the user's logged-in
//  subscription (verified: tool-enabled runs report apiKeySource: none under the
//  Max plan). We never grant `bypassPermissions` — only the narrow allowlist.
//

import Foundation

enum ResearchArguments {
    /// The fixed model the research subsystem uses. Sonnet is fast/cheap enough for
    /// the plan + execute loop while still handling multi-source web research.
    static let model = "sonnet"

    /// Just the three tools the execute phase is allowed to run, pre-authorized so
    /// they run with NO per-tool permission prompt. No shell, no arbitrary file
    /// access beyond the scoped `--add-dir` output directory.
    static let allowedTools = ["WebSearch", "WebFetch", "Write"]

    /// Builds the PLAN/CLARIFY phase argument vector. The task is passed as the
    /// `-p` print-mode prompt. `--permission-mode plan` makes the model decide
    /// whether to ask clarifying questions (it runs no tools in this mode).
    ///
    /// `--session-id` PRE-ASSIGNS the pre-minted `sessionID` so Clawdy owns the id
    /// before the run (claude echoes it back verbatim). The execute phase then
    /// continues this exact id with `--resume`, and both phases append to the one
    /// `<sessionID>.jsonl` transcript in the same working directory.
    ///
    /// `useClaudeCustomizations` mirrors the single app-wide setting (default true):
    /// when true the user's own `claude` setup (CLAUDE.md, skills, MCP, hooks) loads
    /// so research runs in the same configured environment as the warm quick-answer
    /// path; when false we add `--safe-mode` to ISOLATE the run from those.
    static func makePlanArguments(
        task: String,
        sessionID: String,
        systemPrompt: String,
        useClaudeCustomizations: Bool
    ) -> [String] {
        var arguments = [
            "-p", task,
            "--session-id", sessionID,
            "--append-system-prompt", systemPrompt,
            "--permission-mode", "plan"
        ]
        if !useClaudeCustomizations {
            arguments.append("--safe-mode")
        }
        arguments.append(contentsOf: [
            "--output-format", "stream-json",
            "--verbose",
            "--model", model
        ])
        return arguments
    }

    /// Builds the EXECUTE phase argument vector. Resumes the plan session, switches
    /// to `acceptEdits` so the narrow tool allowlist runs without prompts, scopes
    /// file writes to `outputDirectoryPath`, and caps spend at `maxBudgetUSD`.
    ///
    /// `useClaudeCustomizations` follows the same single app-wide setting as the plan
    /// phase: false adds `--safe-mode` so the resumed run stays isolated from the
    /// user's `claude` setup (the narrow `--allowedTools` allowlist is unaffected —
    /// safe-mode disables settings sources, not the explicit tool grants).
    static func makeExecuteArguments(
        sessionID: String,
        outputDirectoryPath: String,
        maxBudgetUSD: Double,
        userMessage: String,
        systemPrompt: String,
        useClaudeCustomizations: Bool
    ) -> [String] {
        var arguments = [
            "-p", userMessage,
            "--resume", sessionID,
            "--append-system-prompt", systemPrompt,
            "--permission-mode", "acceptEdits"
        ]
        if !useClaudeCustomizations {
            arguments.append("--safe-mode")
        }
        arguments.append("--allowedTools")
        arguments.append(contentsOf: allowedTools)
        arguments.append(contentsOf: [
            "--add-dir", outputDirectoryPath,
            "--max-budget-usd", trimmedBudgetString(maxBudgetUSD),
            "--output-format", "stream-json",
            "--verbose",
            "--model", model
        ])
        return arguments
    }

    /// Formats the budget cap without a trailing ".0" when it's a whole number, so
    /// the command line reads "5" rather than "5.0".
    static func trimmedBudgetString(_ budgetUSD: Double) -> String {
        if budgetUSD == budgetUSD.rounded() {
            return String(Int(budgetUSD))
        }
        return String(budgetUSD)
    }
}
