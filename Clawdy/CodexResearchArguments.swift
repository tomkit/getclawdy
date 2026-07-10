//
//  CodexResearchArguments.swift
//  Clawdy
//
//  Pure constructors for the two `codex` argument vectors the Codex research path
//  runs. Static and side-effect-free so the exact command lines are unit-testable
//  without launching anything — exactly like the Claude `ResearchArguments`.
//
//  Codex research is a SEPARATE, single-turn path (v1: no plan/clarify phase). It
//  runs `codex exec` in a WORKSPACE-WRITE sandbox scoped to the per-run directory so
//  it can both research the web (a real `web_search` tool) AND write its one
//  self-contained `report.html`:
//
//  EXECUTE (the one autonomous turn; prompt fed on stdin via the trailing `-`):
//
//    codex exec \
//      --skip-git-repo-check \
//      -s workspace-write \
//      -C <output dir> \
//      --add-dir <output dir> \
//      -c tools.web_search=true \
//      --json \
//      -
//
//  RESUME-FOLLOW-UP (continue the SAME thread with a spoken/typed follow-up):
//
//    codex exec resume <thread_id> \
//      --json \
//      -
//
//  IMPORTANT Codex-CLI facts encoded here (codex-cli 0.142.x):
//   - There is NO `--session-id` flag: the session id is the `thread_id`, read
//     POST-HOC from the `thread.started` event (it CANNOT be pre-minted).
//   - `codex exec resume <thread_id>` continues the prior context but CANNOT set
//     `-s`/`-C`/`--add-dir` again — it INHERITS the first turn's sandbox + cwd — so
//     the resume vector deliberately omits them.
//   - There is NO `--max-budget-usd` equivalent; spend is bounded by the caller's
//     execute-phase TIMEOUT only.
//   - `codex exec` has no system-prompt flag, so ALL research instructions are folded
//     into the stdin prompt (see `CodexResearchEngine`).
//

import Foundation

enum CodexResearchArguments {
    /// Enables Codex's built-in web-search tool for the research turn. Passed as a
    /// `-c key=value` config override (parsed as TOML: the bare `true` is a boolean).
    static let webSearchConfigOverride = "tools.web_search=true"

    /// Builds the single-turn EXECUTE argument vector. Runs in a WORKSPACE-WRITE
    /// sandbox scoped to `outputDirectoryPath` (both as the working root via `-C` and
    /// as the writable grant via `--add-dir`) so the turn can research the web and
    /// write `report.html` into that one directory. The prompt is read from stdin (the
    /// trailing `-`); `--json` emits the JSONL event stream the parser consumes.
    static func makeExecuteArguments(outputDirectoryPath: String) -> [String] {
        return [
            "exec",
            // The per-run dir is not a git repo; don't refuse to run there.
            "--skip-git-repo-check",
            // Workspace-write (NOT read-only) so the turn can Write report.html, but
            // scoped to the granted directory only.
            "-s", "workspace-write",
            "-C", outputDirectoryPath,
            "--add-dir", outputDirectoryPath,
            // Turn on the real web_search tool for this run.
            "-c", webSearchConfigOverride,
            "--json",
            // Trailing "-" => read the prompt from stdin.
            "-"
        ]
    }

    /// Builds the RESUME-follow-up argument vector: `codex exec resume <thread_id>`.
    /// The sandbox / working directory / web-search config are NOT re-specified — a
    /// resumed turn INHERITS the first turn's settings (the CLI rejects re-setting
    /// them), so the follow-up only supplies the thread id and reads the follow-up
    /// prompt from stdin.
    static func makeResumeFollowUpArguments(threadID: String) -> [String] {
        return [
            "exec",
            "resume",
            threadID,
            "--json",
            "-"
        ]
    }
}
