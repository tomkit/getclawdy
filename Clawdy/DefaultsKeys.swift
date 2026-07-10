import Foundation

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
}
