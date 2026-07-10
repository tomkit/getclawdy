//
//  DefaultsKeyTests.swift
//  ClawdyTests
//
//  Pins every `DefaultsKey.rawValue` to the EXACT legacy UserDefaults string that
//  shipped, so the DRY consolidation can never silently change a key (which would
//  orphan the user's persisted value and read as "the setting reset itself"). Also
//  covers the cursor-enabled loader (default-true when unset, stored value when
//  set) against an isolated UserDefaults suite.
//

import Testing
import Foundation
@testable import Clawdy

struct DefaultsKeyTests {

    // MARK: - Byte-for-byte key string pins

    /// Each case must map to the precise string previously used as a raw literal /
    /// named constant. Changing any of these breaks persistence for existing users.
    @Test func rawValuesMatchLegacyStrings() {
        #expect(DefaultsKey.selectedCoachEngine.rawValue == "selectedCoachEngine")
        #expect(DefaultsKey.clawdyCursorEnabled.rawValue == "isClawdyCursorEnabled")
        #expect(DefaultsKey.hasCompletedOnboarding.rawValue == "hasCompletedOnboarding")
        #expect(DefaultsKey.hasSubmittedEmail.rawValue == "hasSubmittedEmail")
        #expect(DefaultsKey.hasScreenContentPermission.rawValue == "hasScreenContentPermission")
        #expect(DefaultsKey.useClaudeCustomizations.rawValue == "useClaudeCustomizations")
        #expect(DefaultsKey.selectedTTSEngine.rawValue == "selectedTTSEngine")
        #expect(DefaultsKey.elevenLabsVoiceID.rawValue == "elevenLabsVoiceID")
        #expect(DefaultsKey.hasElevenLabsAPIKey.rawValue == "hasElevenLabsAPIKey")
    }

    /// The screen-content permission key carries NO namespace prefix — it must stay
    /// the bare "hasScreenContentPermission" (unlike WindowPositionManager's
    /// "com.learningbuddy."-prefixed screen-recording key, which is out of scope).
    @Test func screenContentPermissionKeyHasNoPrefix() {
        #expect(DefaultsKey.hasScreenContentPermission.rawValue == "hasScreenContentPermission")
        #expect(DefaultsKey.hasScreenContentPermission.rawValue.hasPrefix("com.") == false)
    }

    /// The `DefaultsKey`-typed UserDefaults overloads must forward verbatim to the
    /// `forKey: String` methods using the key's rawValue (no behavior change).
    @Test func typedOverloadsForwardToRawValueKey() {
        let defaults = makeIsolatedDefaults()
        defer { wipe(defaults) }

        defaults.set(true, forKey: DefaultsKey.hasSubmittedEmail)
        // Read back through BOTH the typed overload and the raw string — same value.
        #expect(defaults.bool(forKey: DefaultsKey.hasSubmittedEmail) == true)
        #expect(defaults.bool(forKey: "hasSubmittedEmail") == true)

        defaults.set("codex", forKey: DefaultsKey.selectedCoachEngine)
        #expect(defaults.string(forKey: DefaultsKey.selectedCoachEngine) == "codex")
        #expect(defaults.string(forKey: "selectedCoachEngine") == "codex")

        #expect(defaults.object(forKey: DefaultsKey.selectedCoachEngine) != nil)
        defaults.removeObject(forKey: DefaultsKey.selectedCoachEngine)
        #expect(defaults.object(forKey: DefaultsKey.selectedCoachEngine) == nil)
    }

    // MARK: - Cursor-enabled key loading

    /// Key never written → default true (cursor shown).
    @Test @MainActor func loadDefaultsTrueWhenKeyNotPresent() {
        let defaults = makeIsolatedDefaults()
        defer { wipe(defaults) }

        #expect(CompanionManager.loadClawdyCursorEnabled(from: defaults) == true)
    }

    /// Key written false → the stored value is returned verbatim.
    @Test @MainActor func loadReturnsStoredValueWhenKeySetFalse() {
        let defaults = makeIsolatedDefaults()
        defer { wipe(defaults) }
        defaults.set(false, forKey: "isClawdyCursorEnabled")

        #expect(CompanionManager.loadClawdyCursorEnabled(from: defaults) == false)
    }

    /// Key written true → the stored value is returned verbatim.
    @Test @MainActor func loadReturnsStoredValueWhenKeySetTrue() {
        let defaults = makeIsolatedDefaults()
        defer { wipe(defaults) }
        defaults.set(true, forKey: "isClawdyCursorEnabled")

        #expect(CompanionManager.loadClawdyCursorEnabled(from: defaults) == true)
    }

    // MARK: - Helpers

    /// A throwaway `UserDefaults` suite so tests never touch the dev machine's real
    /// standard domain. Wiped before use and in each test's `defer`.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "DefaultsKeyTests.isolated"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func wipe(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: "isClawdyCursorEnabled")
        defaults.removeObject(forKey: "selectedCoachEngine")
        defaults.removeObject(forKey: "hasSubmittedEmail")
    }
}
