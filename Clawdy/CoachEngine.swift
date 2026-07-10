//
//  CoachEngine.swift
//  Clawdy
//
//  Abstraction over the thing that turns screenshots + a spoken prompt into a
//  coaching response. CompanionManager depends ONLY on this protocol, never on
//  a concrete client. The original app shipped a single network-backed
//  implementation (ClaudeAPI hitting a Cloudflare Worker proxy). Clawdy instead
//  ships local implementations that shell out to the user's own installed CLIs
//  (`claude` / `codex`) so responses are billed to the user's existing
//  subscription — no API keys, no proxy, no metering.
//

import Foundation

/// Produces a coaching response from one or more screenshots plus the user's
/// spoken prompt. The signature deliberately mirrors the original
/// `ClaudeAPI.analyzeImageStreaming` call site so swapping engines required no
/// change to the response-handling / POINT-tag-parsing pipeline in
/// CompanionManager.
///
/// - `images`: one JPEG per connected display, each with a human-readable label
///   that already includes the screenshot's pixel dimensions (the coordinate
///   space the model must use for `[POINT:x,y:label]` tags).
/// - `systemPrompt`: the coaching persona + the `[POINT:...]` pointing protocol
///   instructions. Passed through verbatim to the underlying CLI.
/// - `conversationHistory`: prior exchanges so the engine can remember context
///   within a session. Folded into the prompt text for CLI engines.
/// - `userPrompt`: the freshly transcribed thing the user just said.
/// - `onTextChunk`: called on the main actor with the accumulated response text
///   so the UI can render progressively as text arrives.
///
/// Returns the full response text (raw model output, POINT tags intact) and how
/// long the call took. Throws if the engine fails (non-zero exit / stderr).
protocol CoachEngine: AnyObject {
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)

    /// Optionally spawn/keepalive any warm backend ahead of the first turn so the
    /// user's first push-to-talk doesn't pay cold-start. `systemPrompt` is the one
    /// real turns will use, so a warm-process engine can launch with it and avoid a
    /// respawn on the first request. Engines without a warm process (e.g. Codex)
    /// inherit the default no-op.
    func prewarm(systemPrompt: String)

    /// Tear down any long-lived backend process this engine owns. Called when the
    /// user switches to a different engine, or when the app quits, so a warm process
    /// never outlives its selection. Engines without a warm process (e.g. Codex)
    /// inherit the default no-op.
    func shutdown()
}

extension CoachEngine {
    /// Default: nothing to pre-warm. Codex spawns a fresh one-shot process per
    /// request, so there's no warm process to prime.
    func prewarm(systemPrompt: String) {}

    /// Default: nothing to tear down. Codex holds no long-lived process between
    /// requests, so there's nothing to shut down.
    func shutdown() {}
}

/// Pure decision for what to do with coaching-engine sessions when the user
/// switches the selected engine in settings. Tearing down the previously-selected
/// engine's long-lived session frees its process; the newly-selected engine then
/// starts its own warm session. Extracted as a pure function so the switch
/// teardown/restart logic is unit-testable without live processes.
enum CoachEngineSwitchPlan {
    /// True when the selection actually changed to a different engine and therefore
    /// the old engine's session must be torn down and the new engine's started.
    /// False when the "new" kind equals the current one (a no-op — never disturb an
    /// already-warm session by tearing it down and respawning needlessly).
    static func shouldTearDownPreviousAndStartNew(
        previousKind: CoachEngineKind?,
        newKind: CoachEngineKind
    ) -> Bool {
        return previousKind != newKind
    }
}

/// Which CLI-subscription engine to use for coaching responses. The raw value is
/// the string persisted to UserDefaults.
enum CoachEngineKind: String, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex = "codex"

    var id: String { rawValue }

    /// Name shown in the menu-bar engine picker.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The executable name to look for on disk / in PATH.
    var binaryName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// Friendly one-line install instruction shown when no engine is detected.
    var installCommand: String {
        switch self {
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .codex: return "npm install -g @openai/codex"
        }
    }
}

/// A CLI engine that was actually found installed on the machine, paired with
/// the resolved absolute path to its binary so engines don't have to re-resolve.
struct DetectedCoachEngine {
    let kind: CoachEngineKind
    let binaryPath: String
}
