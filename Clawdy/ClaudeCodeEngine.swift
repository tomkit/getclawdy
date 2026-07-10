//
//  ClaudeCodeEngine.swift
//  Clawdy
//
//  CoachEngine implementation that shells out to the user's installed `claude`
//  CLI, billing the user's own Claude subscription. No API key, no proxy.
//
//  FINAL COMMAND LINE (chosen empirically by running the installed CLI, verified
//  against 2.1.198):
//
//    claude -p \
//      --append-system-prompt "<coaching system prompt>" \
//      --tools "" \
//      --input-format stream-json \
//      --output-format stream-json --verbose --include-partial-messages \
//      --exclude-dynamic-system-prompt-sections
//
//  and each push-to-talk turn is written to the process's STDIN as one NDJSON
//  `user` message whose content is a text block followed by one base64 `image`
//  block per screenshot (see ClaudeStreamJSONMessage). The process is kept WARM
//  across turns by ClaudePersistentSession.
//
//  Why these flags (measured against the installed CLI):
//  - Inline base64 images via `--input-format stream-json` let Claude see the
//    screens in the FIRST model turn. The old design wrote screenshots to a temp
//    dir and made Claude read them with the Read tool, which cost a whole extra
//    model turn (num_turns=2, ~7s api). Inline images drop that to num_turns=1
//    and roughly halve end-to-end latency. The model still honors the
//    [POINT:...] protocol.
//  - `--tools ""` disables ALL tools (no Read, no nothing) since the model no
//    longer needs to touch the filesystem — which also removes the temp dir,
//    `--allowedTools Read`, and `--add-dir` entirely.
//  - `--safe-mode` is now controlled by the single app-wide "Use my Claude Code
//    setup" setting (`useClaudeCustomizations`, default true). By DEFAULT we OMIT
//    `--safe-mode` so the user's own `claude` customizations — CLAUDE.md, skills,
//    plugins, hooks, and MCP servers — load on the warm quick-answer path, so a
//    spoken answer reflects the same configured environment the user gets in their
//    own terminal. When the user turns the setting OFF (isolate), we ADD
//    `--safe-mode`, which DISABLES exactly those. IMPORTANT compatibility caveat:
//    on `claude` 2.1.198, `--safe-mode` + `--input-format stream-json` makes the CLI
//    exit 0 with EMPTY stdout (no `result` event) — the warm process then hits EOF
//    with nothing to parse (2.1.199 fixed it). Rather than surface the generic "hit
//    a snag", `ClaudePersistentSession` detects that specific case (safe-mode active
//    + a turn that ended with no text) and throws `.isolationModeUnsupported`, whose
//    message tells the user to turn the setting back on. (`--tools ""` still disables
//    all tools, and `--append-system-prompt` still governs behavior either way, so
//    the coaching contract is unchanged regardless of the setting.)
//  - `--exclude-dynamic-system-prompt-sections` moves per-machine sections (cwd,
//    env, git status) out of the system prompt so the system prompt is identical
//    across turns and prompt-caches cleanly.
//  - `--output-format stream-json --verbose --include-partial-messages` emits one
//    JSON object per line so we can stream `text_delta` events (for sentence-by-
//    sentence TTS) and read the final `result` event for the authoritative text.
//  - We deliberately do NOT pass `--bare`, because that forces ANTHROPIC_API_KEY
//    auth instead of the user's logged-in subscription.
//

import Foundation

final class ClaudeCodeEngine: CoachEngine {
    /// The warm, long-lived `claude` process. Kept for the lifetime of this engine
    /// instance so turns after the first pay ~no startup cost and Claude remembers
    /// the conversation server-side.
    private let persistentSession: ClaudePersistentSession

    init(
        binaryPath: String,
        homeDirectoryPath: String = NSHomeDirectory(),
        useClaudeCustomizations: Bool = true,
        manifestStore: ResearchManifestStore = .shared
    ) {
        // READ-ONLY capture of the warm session's own `session_id` for the History
        // index. This only records where the root transcript lives — it changes
        // nothing about how the warm session runs (its working directory stays
        // `homeDirectoryPath`, its args are untouched). The warm
        // process's CWD is `homeDirectoryPath`, so that's the working dir Claude Code
        // keyed its transcript project under.
        self.persistentSession = ClaudePersistentSession(
            binaryPath: binaryPath,
            homeDirectoryPath: homeDirectoryPath,
            // Mirrors the app-wide "Use my Claude Code setup" setting. Fixed for this
            // engine instance's lifetime; CompanionManager rebuilds the engine (and so
            // respawns the warm process) when the user flips the toggle, so the new
            // arg set applies on the next turn.
            useClaudeCustomizations: useClaudeCustomizations,
            // Keep the `claude` process alive for the WHOLE app lifetime: no idle
            // teardown, and an unexpected death self-heals via a proactive respawn.
            // Every push-to-talk reuses this one long-lived session.
            keepWarmForAppLifetime: true,
            onRootSessionCaptured: { rootSessionID in
                let transcriptPath = ClaudeResearchEngine.claudeTranscriptPath(
                    sessionID: rootSessionID,
                    workingDirectoryPath: homeDirectoryPath,
                    homeDirectoryPath: homeDirectoryPath
                )
                manifestStore.recordRootSession(
                    sessionId: rootSessionID,
                    title: "Quick answers",
                    workingDir: homeDirectoryPath,
                    transcriptPath: transcriptPath
                )
            }
        )
    }

    /// Builds the `claude` argument vector. Pure and static so it can be
    /// unit-tested without launching anything. The system prompt is the only
    /// per-call input; everything else (the screenshots + spoken prompt) is fed
    /// on stdin as a stream-json message.
    ///
    /// `useClaudeCustomizations` mirrors the single app-wide setting (default true).
    /// true (the default) OMITS `--safe-mode` so the user's own `claude` setup
    /// (CLAUDE.md, skills, plugins, hooks, MCP) loads on the warm path. false ADDS
    /// `--safe-mode` to isolate the run — but see the header note: on some `claude`
    /// versions (observed 2.1.198) `--safe-mode` + `--input-format stream-json`
    /// returns EMPTY output, which `ClaudePersistentSession` detects and surfaces as
    /// specific guidance rather than the generic snag. `--tools ""` still disables
    /// all tools and `--append-system-prompt` still governs behavior either way.
    static func makeArguments(systemPrompt: String, useClaudeCustomizations: Bool) -> [String] {
        var arguments = [
            "-p",
            "--append-system-prompt", systemPrompt,
            "--tools", ""
        ]
        if !useClaudeCustomizations {
            arguments.append("--safe-mode")
        }
        arguments.append(contentsOf: [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--exclude-dynamic-system-prompt-sections"
        ])
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

        // Encode each screenshot inline as a base64 JPEG image block.
        let inlineImages = images.map { image in
            ClaudeStreamJSONMessage.InlineImage(
                base64EncodedData: image.data.base64EncodedString(),
                mediaType: "image/jpeg"
            )
        }

        // Describe the attached images (by label/order) and the spoken prompt.
        // No "read these files" instruction — the model sees the images directly.
        let userText = CLIPromptComposer.composeClaudeInlinePromptText(
            imageLabels: images.map { $0.label },
            userPrompt: userPrompt
        )

        // Conversation history is carried server-side by the warm process, so it
        // is only used to PRIME a freshly-spawned (cold) process — handled inside
        // the session. We render it here and let the session decide.
        let historyPrimerText = CLIPromptComposer.renderConversationHistory(conversationHistory)

        let finalText = try await persistentSession.sendRequest(
            systemPrompt: systemPrompt,
            userText: userText,
            historyPrimerText: historyPrimerText.isEmpty ? nil : historyPrimerText,
            images: inlineImages,
            onAccumulatedText: onTextChunk
        )

        let duration = Date().timeIntervalSince(startTime)
        return (text: finalText, duration: duration)
    }

    /// Pre-warms the long-lived `claude` process so the first push-to-talk turn
    /// doesn't pay the ~1.5s cold start. Delegates to the warm session, which
    /// no-ops unless it's fully cold. Launches with the same system prompt the
    /// first real turn will use so that turn reuses this process.
    func prewarm(systemPrompt: String) {
        persistentSession.prewarm(systemPrompt: systemPrompt)
    }

    /// Terminates the long-lived `claude` process. Called when the user switches to
    /// a different engine or when the app quits, so the warm process never outlives
    /// its purpose. Safe to call repeatedly.
    func shutdown() {
        persistentSession.shutdown()
    }
}
