//
//  CodexEngine.swift
//  Clawdy
//
//  CoachEngine implementation that shells out to the user's installed `codex`
//  CLI in non-interactive `exec` mode, billing the user's own Codex/OpenAI
//  subscription. No API key, no proxy.
//
//  FINAL COMMAND LINE (chosen empirically by running the installed CLI):
//
//    codex exec \
//      --skip-git-repo-check \
//      -s read-only \
//      -C "<temp dir>" \
//      --json \
//      -c model_reasoning_effort=low \
//      -i "<temp dir>/screen1.jpg" [-i "<temp dir>/screen2.jpg" ...] \
//      -
//
//  with the prompt text fed on stdin (the trailing `-`).
//
//  Why these flags:
//  - `exec` is Codex's non-interactive mode.
//  - `--skip-git-repo-check` lets it run in the temp dir, which is not a git repo.
//  - `-s read-only` is the most restrictive sandbox: Codex may read but never
//    write or run commands, which is all it needs to look at screenshots.
//  - `-C <temp dir>` sets the working root to the temp dir (where screenshots live).
//  - `--json` emits JSONL events; the final answer is the `agent_message` item.
//  - `-c model_reasoning_effort=low` LOWERS Codex's reasoning effort for this
//    quick-answer coaching path only. LATENCY RATIONALE: coaching is short,
//    spoken screen-help where responsiveness matters far more than deep
//    reasoning. Under the user's global `model_reasoning_effort = high`, the
//    coaching round-trip measured ~8s wall vs Claude's ~2.6-3.5s warm path.
//    `low` (deliberately NOT `minimal`) trades a little reasoning depth for
//    speed while keeping answer quality acceptable for glance-level help.
//    The two bigger Claude latency levers — a true WARM long-lived process and
//    token-streaming TTS — are BLOCKED for Codex by the CLI itself: `codex exec`
//    is a one-shot with no interactive stdin loop to keep warm, and its `--json`
//    stream carries no token deltas to stream into TTS. So lowering the
//    reasoning effort is the one achievable latency lever here. `-c key=value`
//    overrides a `~/.codex/config.toml` value (`value` parsed as TOML, falling
//    back to a literal string), confirmed accepted by the installed CLI.
//    This override is scoped to the coaching arg vector ONLY (there is no Codex
//    research path today, and this must never affect one if it is added).
//  - `-i <file>` attaches each screenshot natively so the model SEES it directly
//    (no "read this file" step needed, unlike Claude Code).
//  - The trailing `-` makes Codex read the prompt from stdin, which avoids the
//    `-i ...` greedily swallowing a positional prompt argument.
//  - Codex `exec` has no system-prompt flag, so the coaching system prompt is
//    folded into the top of the stdin prompt text (see CLIPromptComposer).
//

import Foundation

final class CodexEngine: CoachEngine {
    /// The reasoning-effort override applied to the quick-answer coaching path so
    /// spoken screen-help stays responsive even when the user's global
    /// `~/.codex/config.toml` sets a higher effort. See the file header for the
    /// full latency rationale (and why a true warm session / streaming TTS are
    /// CLI-blocked for Codex, leaving this as the one achievable latency lever).
    static let coachingReasoningEffortOverride = "model_reasoning_effort=low"

    private let binaryPath: String
    private let homeDirectoryPath: String

    init(binaryPath: String, homeDirectoryPath: String = NSHomeDirectory()) {
        self.binaryPath = binaryPath
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// Builds the `codex` argument vector. Pure and static so it can be
    /// unit-tested without launching anything.
    static func makeArguments(
        workingDirectoryPath: String,
        imageFilePaths: [String]
    ) -> [String] {
        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "-s", "read-only",
            "-C", workingDirectoryPath,
            "--json",
            // Lower the reasoning effort for this quick-answer coaching path only,
            // trading reasoning depth for latency (see the file header).
            "-c", coachingReasoningEffortOverride
        ]
        for imageFilePath in imageFilePaths {
            arguments.append("-i")
            arguments.append(imageFilePath)
        }
        // Trailing "-" => read the prompt from stdin.
        arguments.append("-")
        return arguments
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let temporaryDirectory = try CLIEngineWorkspace.makeRequestDirectory()
        defer { CLIEngineWorkspace.removeDirectory(temporaryDirectory) }

        let screenshotFiles = try CLIEngineWorkspace.writeScreenshots(images, into: temporaryDirectory)

        let promptText = CLIPromptComposer.composeCodexPrompt(
            systemPrompt: systemPrompt,
            screenshotFiles: screenshotFiles,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let arguments = Self.makeArguments(
            workingDirectoryPath: temporaryDirectory.path,
            imageFilePaths: screenshotFiles.map { $0.absolutePath }
        )

        let environment = CLIProcessRunner.makeChildEnvironment(homeDirectoryPath: homeDirectoryPath)

        let streamState = CodexStreamParseState()

        let result = try await CLIProcessRunner.run(
            executablePath: binaryPath,
            arguments: arguments,
            workingDirectoryPath: temporaryDirectory.path,
            environment: environment,
            standardInput: promptText,
            onStandardOutputLine: { line in
                if let latestAgentMessage = streamState.consume(line: line) {
                    Task { @MainActor in onTextChunk(latestAgentMessage) }
                }
            }
        )

        guard result.exitCode == 0 else {
            throw CLIProcessRunner.RunError.nonZeroExit(
                exitCode: result.exitCode,
                standardError: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }

        guard let finalText = streamState.latestAgentMessageText, !finalText.isEmpty else {
            throw CLIProcessRunner.RunError.nonZeroExit(
                exitCode: 0,
                standardError: "Codex returned no agent message. Output: \(result.standardOutput)"
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: finalText, duration: duration)
    }
}

/// Parses Codex's `--json` JSONL output, extracting the agent's message text.
/// The final answer arrives as: { type: "item.completed", item: { type:
/// "agent_message", text: "..." } }. Independently unit-testable.
///
/// Thread-safe: `consume` runs on background pipe queues while the engine reads
/// `latestAgentMessageText` after the process exits, so all access is guarded by
/// a lock.
final class CodexStreamParseState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestAgentMessageTextStorage: String?

    var latestAgentMessageText: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestAgentMessageTextStorage
    }

    /// Feeds one JSONL line. Returns the agent message text when this line
    /// carried one, otherwise nil.
    @discardableResult
    func consume(line: String) -> String? {
        guard let jsonObject = decodeJSONLine(line),
              let eventType = jsonObject["type"] as? String,
              eventType == "item.completed",
              let item = jsonObject["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message",
              let text = item["text"] as? String else {
            return nil
        }

        lock.lock()
        latestAgentMessageTextStorage = text
        lock.unlock()
        return text
    }
}
