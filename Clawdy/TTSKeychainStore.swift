//
//  TTSKeychainStore.swift
//  Clawdy
//
//  Secure storage for the user's ElevenLabs API key. The key is a secret, so it
//  lives in the macOS Keychain (a generic password item) — never in UserDefaults
//  or any plaintext file. Provides save / load / delete.
//

import Foundation
import Security

/// Keychain-backed store for the ElevenLabs API key.
enum TTSKeychainStore {
    /// Keychain service identifier scoping our item. Unique to Clawdy's TTS key
    /// so it never collides with other generic-password items.
    private static let keychainServiceName = "com.clawdy.tts.elevenlabs"
    /// Account name within the service. We store a single key, so a constant
    /// account is enough.
    private static let keychainAccountName = "api-key"

    /// Saves (or replaces) the API key. Returns true on success. An empty or
    /// whitespace-only key deletes the stored item instead of storing blank.
    @discardableResult
    static func saveAPIKey(_ apiKey: String) -> Bool {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            deleteAPIKey()
            return true
        }
        guard let apiKeyData = trimmedAPIKey.data(using: .utf8) else { return false }

        // Delete any existing item first so we always end with exactly one,
        // then add the fresh value. This is simpler and more robust than a
        // conditional SecItemUpdate when the item may or may not already exist.
        deleteAPIKey()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName,
            kSecValueData as String: apiKeyData,
            // Only readable while the device is unlocked; never syncs to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Test-only seam. When non-nil, `loadAPIKey()` routes through this closure
    /// instead of the real Keychain. It exists so the Keychain-access gating tests
    /// can observe EVERY read of the ElevenLabs secret — including a DIRECT
    /// `TTSKeychainStore.loadAPIKey()` call that bypasses a caller's injected
    /// accessor (the exact gap an accessor-only spy could not see) — and so those
    /// tests never fire the real macOS Keychain prompt. Always nil in production;
    /// no production code path assigns it.
    static var overrideSecretReaderForTesting: (() -> String?)?

    /// Loads the stored API key, or nil if none is saved. This is the single choke
    /// point every secret read must funnel through (callers hold it as their
    /// injected accessor); a direct call here on a hot/launch path is a bug the
    /// gating tests are designed to catch via `overrideSecretReaderForTesting`.
    static func loadAPIKey() -> String? {
        if let overrideSecretReaderForTesting {
            return overrideSecretReaderForTesting()
        }
        return loadAPIKeyFromKeychain()
    }

    /// The real Keychain read. Private so the only way to read the secret from
    /// outside is `loadAPIKey()`, keeping the test seam authoritative.
    private static func loadAPIKeyFromKeychain() -> String? {
        let loadQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var loadedItem: CFTypeRef?
        let loadStatus = SecItemCopyMatching(loadQuery as CFDictionary, &loadedItem)
        guard loadStatus == errSecSuccess,
              let apiKeyData = loadedItem as? Data,
              let apiKey = String(data: apiKeyData, encoding: .utf8) else {
            return nil
        }
        return apiKey
    }

    /// Deletes the stored API key, if any.
    static func deleteAPIKey() {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}
