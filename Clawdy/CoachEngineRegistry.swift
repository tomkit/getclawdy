//
//  CoachEngineRegistry.swift
//  Clawdy
//
//  Detects which coaching CLI engines (`claude` / `codex`) are actually
//  installed and builds CoachEngine instances on demand. CompanionManager uses
//  this to drive the engine picker and to construct the active engine.
//

import Foundation

@MainActor
final class CoachEngineRegistry {
    /// Engines found installed on this machine, in stable display order
    /// (Claude Code first), each paired with its resolved binary path. A `var` so a
    /// rescan can refresh it when a CLI is installed while Clawdy is running.
    private(set) var detectedEngines: [DetectedCoachEngine]

    init() {
        self.detectedEngines = Self.detectInstalledEngines()
    }

    /// Whether applying `newlyDetectedEngines` would change the set of available
    /// engine KINDS (order-sensitive). The caller checks this BEFORE mutating so it
    /// can publish `objectWillChange` only when the picker's contents actually change
    /// and skip all work on the common no-change rescan.
    func detectedEngineKindsWouldChange(with newlyDetectedEngines: [DetectedCoachEngine]) -> Bool {
        detectedEngines.map { $0.kind } != newlyDetectedEngines.map { $0.kind }
    }

    /// Replaces the detected set with a freshly-probed one. The probe itself
    /// (`detectInstalledEngines`) is `nonisolated` so it can run OFF the main actor
    /// (the login-shell fallback is slow); only this apply step touches actor state.
    func applyDetectedEngines(_ newlyDetectedEngines: [DetectedCoachEngine]) {
        detectedEngines = newlyDetectedEngines
    }

    /// The kinds available to offer in the UI.
    var availableEngineKinds: [CoachEngineKind] {
        detectedEngines.map { $0.kind }
    }

    var hasAnyEngineInstalled: Bool {
        !detectedEngines.isEmpty
    }

    /// The resolved absolute binary path for an installed engine kind, or nil when
    /// that kind isn't installed. Used by the research subsystem to launch its own
    /// dedicated `claude` process, separate from the warm coaching session.
    func detectedBinaryPath(for kind: CoachEngineKind) -> String? {
        detectedEngines.first(where: { $0.kind == kind })?.binaryPath
    }

    /// Builds a fresh CoachEngine for `kind`, or nil if that kind isn't installed.
    /// `useClaudeCustomizations` mirrors the app-wide "Use my Claude Code setup"
    /// setting and is threaded into the Claude engine so a rebuild picks up the
    /// current toggle (Codex is unaffected — it takes no such flag).
    func makeEngine(for kind: CoachEngineKind, useClaudeCustomizations: Bool) -> CoachEngine? {
        guard let detected = detectedEngines.first(where: { $0.kind == kind }) else {
            return nil
        }
        switch kind {
        case .claudeCode:
            return ClaudeCodeEngine(
                binaryPath: detected.binaryPath,
                useClaudeCustomizations: useClaudeCustomizations
            )
        case .codex:
            return CodexEngine(binaryPath: detected.binaryPath)
        }
    }

    /// Probes the filesystem for each engine's binary. Order is deterministic:
    /// Claude Code first, then Codex, so "default to Claude Code when both" is a
    /// simple `.first`. `nonisolated` so callers can run it OFF the main actor — the
    /// login-shell fallback inside can take up to ~2s and must never block the menu.
    nonisolated static func detectInstalledEngines() -> [DetectedCoachEngine] {
        var detected: [DetectedCoachEngine] = []
        for kind in CoachEngineKind.allCases {
            if let binaryPath = CLIBinaryResolver.resolveInstalledBinaryPath(binaryName: kind.binaryName) {
                detected.append(DetectedCoachEngine(kind: kind, binaryPath: binaryPath))
                print("🧠 Coach engine detected: \(kind.displayName) at \(binaryPath)")
            }
        }
        if detected.isEmpty {
            print("⚠️ No coach engine detected — install Claude Code or Codex.")
        }
        return detected
    }
}
