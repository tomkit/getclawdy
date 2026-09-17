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
//      --effort low    no measurable speed change on this path (no tool loop to shorten)
//
//  So Sonnet is the default: about a second faster to first audio and half the cost,
//  with no visible quality loss on a one-or-two-sentence spoken reply. Effort is
//  exposed because it's cheap to try, not because it's a proven lever here.
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

/// The effort level for quick answers. For Claude, `.harnessDefault` omits `--effort` so
/// the user's own `claude` setting applies (effort showed no measurable effect there).
/// For Codex, `.harnessDefault` means Clawdy's `low` override (medium was 2× slower);
/// an explicit level is passed as `-c model_reasoning_effort=<level>`.
enum QuickAnswerEffort: String, CaseIterable, Identifiable, Codable {
    case harnessDefault
    case low
    case medium
    case high

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

    static let recommended: QuickAnswerEffort = .harnessDefault
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

    static let recommended = QuickAnswerSettings(model: .recommended, effort: .recommended)
}
