import Foundation
import CoreGraphics

/// Single source of truth for every `UserDefaults` key that `CompanionManager`
/// reads or writes. Centralizing the raw key strings here means a typo at one
/// call site can no longer silently point at a DIFFERENT key — which, for
/// persisted user state, would read as "the setting reset itself".
///
/// ⚠️ Each `rawValue` below is the EXACT string that has shipped to users. The
/// stored value on disk is keyed by this string, so changing any `rawValue`
/// silently orphans the user's saved preference (their setting appears to reset).
/// Never edit a `rawValue`. `DefaultsKeyTests` pins each one to its legacy string.
enum DefaultsKey: String {
    /// Which coach engine (claude-code / codex) the user selected.
    case selectedCoachEngine = "selectedCoachEngine"

    /// Whether the Clawdy cursor overlay is shown. Defaults to true (shown).
    case clawdyCursorEnabled = "isClawdyCursorEnabled"

    /// Whether the user has completed onboarding at least once.
    case hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Whether the user submitted their email during onboarding.
    case hasSubmittedEmail = "hasSubmittedEmail"

    /// Whether screen-content (ScreenCaptureKit) permission has been confirmed.
    case hasScreenContentPermission = "hasScreenContentPermission"

    /// "Use my Claude Code setup" — loads the user's own `claude` customizations.
    case useClaudeCustomizations = "useClaudeCustomizations"

    /// Which TTS engine the user has chosen (apple / elevenLabs).
    case selectedTTSEngine = "selectedTTSEngine"

    /// The ElevenLabs voice id the user picked (or typed manually).
    case elevenLabsVoiceID = "elevenLabsVoiceID"

    /// NON-SECRET flag mirroring whether a usable ElevenLabs key is saved. The
    /// secret itself never lives in UserDefaults — only in the Keychain.
    case hasElevenLabsAPIKey = "hasElevenLabsAPIKey"

    /// "Show Clawdy in screen recordings" (Recording Mode). When true, Clawdy's
    /// on-screen overlays (cursor, annotation strokes, research chrome) are visible
    /// to EXTERNAL screen recorders. Defaults to false (hidden from capture — the
    /// historical behavior). Never affects Clawdy's OWN model screenshots, which
    /// always exclude Clawdy's windows at the application level.
    case recordingModeEnabled = "recordingModeEnabled"

    /// The user's manual drag offset (in screen points) for the upper-left research
    /// overlay cluster — the toast stack AND the idle recents badge share this ONE
    /// offset, so dragging either repositions both. Persisted so a moved position
    /// survives relaunch. Stored as a `[dx, dy]` pair of doubles.
    case researchOverlayDragOffset = "researchOverlayColumnDragOffset"
}

/// Thin `DefaultsKey`-typed overloads over the standard `UserDefaults` accessors.
/// These forward verbatim to the existing `forKey: String` methods using the
/// key's `rawValue`, so behavior is byte-for-byte identical — the only change is
/// that call sites pass a checked `DefaultsKey` case instead of a bare string.
extension UserDefaults {
    func bool(forKey key: DefaultsKey) -> Bool {
        bool(forKey: key.rawValue)
    }

    func string(forKey key: DefaultsKey) -> String? {
        string(forKey: key.rawValue)
    }

    func object(forKey key: DefaultsKey) -> Any? {
        object(forKey: key.rawValue)
    }

    func set(_ value: Bool, forKey key: DefaultsKey) {
        set(value, forKey: key.rawValue)
    }

    func set(_ value: String, forKey key: DefaultsKey) {
        set(value, forKey: key.rawValue)
    }

    func removeObject(forKey key: DefaultsKey) {
        removeObject(forKey: key.rawValue)
    }

    /// Reads a `CGVector` stored as a `[dx, dy]` pair of doubles (the research overlay
    /// drag offset). Returns nil when nothing was ever saved (or the stored value isn't a
    /// two-element numeric array), so the caller can fall back to `.zero`.
    func vector(forKey key: DefaultsKey) -> CGVector? {
        guard let rawArray = array(forKey: key.rawValue) else { return nil }
        let doubleComponents = rawArray.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard doubleComponents.count == 2 else { return nil }
        return CGVector(dx: doubleComponents[0], dy: doubleComponents[1])
    }

    /// Writes a `CGVector` as a `[dx, dy]` pair of doubles.
    func set(_ vector: CGVector, forKey key: DefaultsKey) {
        set([Double(vector.dx), Double(vector.dy)], forKey: key.rawValue)
    }
}
