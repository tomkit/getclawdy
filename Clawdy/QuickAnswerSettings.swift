//
//  QuickAnswerSettings.swift
//  Clawdy
//
//  The user-tunable model + effort for the WARM quick-answer path (the `claude`
//  process every push-to-talk talks to). Measured 2026-09-17 against `claude` 2.1.274
//  with an inline screenshot, one-shot (so ~1.5s of cold start is included that the
//  warm path doesn't pay):
//
//      opus   default  first text ~3.0s   api ~3.5s   ~$0.024 / turn
//      sonnet default  first text ~2.1–2.6s api ~2.4s ~$0.011 / turn   ← default
//      haiku  either   first text 6.5–9s  (slower, not faster — same as the June finding)
//      --effort low    no change on a trivial question — but on a substantive one
//                      (a "be thorough" ask that triggers extended thinking) it HALVES
//                      time-to-first-text: 6.5s → 3.4s and 4.8s → 2.6s (sonnet). A real
//                      turn in the app showed 11.5s to first text at the user's inherited
//                      `effortLevel: high` + `alwaysThinkingEnabled`. Disabling thinking
//                      outright adds nothing beyond `low` (~2.6s either way).
//
//  So Sonnet + low effort is the default: about a second faster to first audio than Opus
//  at half the cost, and no multi-second silent think before a longer answer.
//
//  Both are `--model` / `--effort` spawn arguments, so a change REBUILDS the warm
//  engine (cancel in-flight turn, shutdown, prewarm) exactly like an engine switch.
//  Codex is one-shot per request and takes its own flags; these settings are
//  Claude-only and the panel shows them only when Claude Code is selected.
//

import Foundation

/// Which model the warm quick-answer `claude` process runs. `.harnessDefault` omits
/// `--model` so the user's own `claude` default applies.
enum QuickAnswerModel: String, CaseIterable, Identifiable, Codable {
    case sonnet
    case opus
    case harnessDefault

    var id: String { rawValue }

    /// The `--model` alias to pass, or nil to inherit the CLI's default.
    var claudeModelArgument: String? {
        switch self {
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .harnessDefault: return nil
        }
    }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .harnessDefault: return "Default"
        }
    }

    var detail: String {
        switch self {
        case .sonnet: return "fastest, recommended"
        case .opus: return "smarter, about a second slower"
        case .harnessDefault: return "whatever your claude CLI uses"
        }
    }

    static let recommended: QuickAnswerModel = .sonnet

    /// The choices the panel offers. `.harnessDefault` stays a valid stored value (and
    /// arg behavior) but isn't offered: the two named models are the whole decision.
    static let offeredCases: [QuickAnswerModel] = [.sonnet, .opus]
}

/// The effort level for quick answers; `low` by default for BOTH engines (Claude: halves
/// time-to-first-text on substantive questions; Codex: 2× faster than medium).
/// `.harnessDefault` ("Auto") inherits the CLI's own setting: Claude omits `--effort`,
/// Codex omits the `model_reasoning_effort` override.
enum QuickAnswerEffort: String, CaseIterable, Identifiable, Codable {
    case low
    case medium
    case high
    case harnessDefault

    var id: String { rawValue }

    /// The `--effort` value to pass, or nil to inherit the CLI's default.
    var claudeEffortArgument: String? {
        switch self {
        case .harnessDefault: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    var displayName: String {
        switch self {
        case .harnessDefault: return "Auto"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        }
    }

    static let recommended: QuickAnswerEffort = .low
}

/// The pair, as threaded into the engine. Equatable so a "did it change?" check is
/// trivial before a respawn.
struct QuickAnswerSettings: Equatable, Codable {
    var model: QuickAnswerModel
    var effort: QuickAnswerEffort
    /// The Codex `-m` model slug, or nil to use the user's `config.toml` default. Offered
    /// choices come from Codex's own catalog (`CodexModelCatalog`). Measured 2026-09-17:
    /// the model barely moves Codex latency (effort does), so this is for choice, not speed.
    var codexModel: String? = nil
    /// The engines' own "fast" tiers, propagated to the lead (quick-answer) agent:
    /// Claude `--settings '{"fastMode":true}'` (Opus only; 2.5× output speed claimed, ~12%
    /// measured on a long answer, higher per-token price), Codex `-c service_tier=fast`
    /// (measured ~1s faster per reply; 2–2.5× credits). Off by default: it costs more and,
    /// for Claude, Sonnet + low effort already reaches first audio sooner.
    var fastMode: Bool = false

    static let recommended = QuickAnswerSettings(model: .recommended, effort: .recommended)
}
