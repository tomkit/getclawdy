//
//  CLIPromptComposer.swift
//  Clawdy
//
//  Pure helpers that fold the structured request (system prompt, conversation
//  history, per-screen image labels, the user's spoken prompt) into the flat
//  text a CLI invocation needs. The CLIs take a single prompt string rather than
//  the structured messages array the raw API accepted, so history and labels are
//  serialized into readable plain text. Kept pure so it is unit-testable.
//

import Foundation

enum CLIPromptComposer {
    /// A screenshot written to a temp file, ready to hand to a CLI.
    struct WrittenScreenshotFile {
        /// Absolute path on disk (inside the per-request temp directory).
        let absolutePath: String
        /// Just the file name, e.g. "screen1.jpg".
        let fileName: String
        /// The human-readable label (includes pixel dimensions) for this screen.
        let label: String
    }

    /// Builds the file name for the screen at `screenIndex` (0-based).
    static func screenshotFileName(forScreenIndex screenIndex: Int) -> String {
        return "screen\(screenIndex + 1).jpg"
    }

    /// Renders the conversation history as a readable transcript that can be
    /// prepended to the prompt so a CLI engine still "remembers" the session.
    /// Returns an empty string when there is no history.
    static func renderConversationHistory(
        _ conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> String {
        guard !conversationHistory.isEmpty else { return "" }

        var lines: [String] = ["Here is the conversation so far in this session:"]
        for exchange in conversationHistory {
            lines.append("User said: \(exchange.userPlaceholder)")
            lines.append("You replied: \(exchange.assistantResponse)")
        }
        return lines.joined(separator: "\n")
    }

    /// Composes the text block for one Claude Code stream-json `user` turn. The
    /// screenshots are attached INLINE as base64 image blocks alongside this text
    /// (see ClaudeStreamJSONMessage), so the model sees them directly — there is
    /// no "read the file" instruction and no file names. Each attached image is
    /// described by label and attachment order so the model can map a screen to
    /// its coordinate space for POINT tags. The system prompt is passed via
    /// `--append-system-prompt`, and conversation history is carried server-side
    /// by the warm session, so NEITHER is included here.
    static func composeClaudeInlinePromptText(
        imageLabels: [String],
        userPrompt: String
    ) -> String {
        var sections: [String] = []

        if !imageLabels.isEmpty {
            var screenshotLines: [String] = [
                "The attached images are screenshots of the user's screen(s), in this order:"
            ]
            for (attachmentIndex, label) in imageLabels.enumerated() {
                screenshotLines.append("- attached image \(attachmentIndex + 1): \(label)")
            }
            sections.append(screenshotLines.joined(separator: "\n"))
        }

        sections.append("The user just said: \"\(userPrompt)\"")
        sections.append("Respond following all the rules in your system prompt, including the [POINT:...] pointing protocol. Output only your spoken reply and the optional point tag — no preamble, no tool-call narration.")

        return sections.joined(separator: "\n\n")
    }

    /// Composes the full prompt text for the Codex CLI. Codex attaches images
    /// natively (`-i file.jpg`) so the model sees them directly — no "read the
    /// file" instruction is needed. Codex `exec` has no separate system-prompt
    /// flag, so the coaching system prompt is folded in at the top here. Each
    /// attached image is described by label and attachment order so the model can
    /// map a screen to its coordinate space for POINT tags.
    static func composeCodexPrompt(
        systemPrompt: String,
        screenshotFiles: [WrittenScreenshotFile],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        var sections: [String] = []

        sections.append(systemPrompt)

        let renderedHistory = renderConversationHistory(conversationHistory)
        if !renderedHistory.isEmpty {
            sections.append(renderedHistory)
        }

        if !screenshotFiles.isEmpty {
            var screenshotLines: [String] = [
                "The attached images are screenshots of the user's screen(s), in this order:"
            ]
            for (attachmentIndex, screenshotFile) in screenshotFiles.enumerated() {
                screenshotLines.append("- attached image \(attachmentIndex + 1): \(screenshotFile.label)")
            }
            sections.append(screenshotLines.joined(separator: "\n"))
        }

        sections.append("The user just said: \"\(userPrompt)\"")
        sections.append("Respond following all the rules above, including the [POINT:...] pointing protocol. Output only your spoken reply and the optional point tag — nothing else.")

        return sections.joined(separator: "\n\n")
    }
}
