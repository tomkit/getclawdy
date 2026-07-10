//
//  KeychainAccessGatingTests.swift
//  ClawdyTests
//
//  REAL-PATH regression tests for the ElevenLabs BYO-key Keychain-access prompt
//  bug: macOS prompted for `com.clawdy.tts.elevenlabs` on EVERY relaunch (and on
//  every spoken answer) because the app read the secret EAGERLY — at launch to
//  populate provider state, and on the TTS hot path — even when the user is on the
//  default Apple TTS and nothing needs the key. Each read fires the prompt.
//
//  These drive the actual objects (a real CompanionManager and a real
//  StreamingResponseSpeaker) with an INJECTED keychain-accessor spy that counts
//  secret reads, and assert:
//    1. Constructing the manager (the launch path) reads the secret ZERO times.
//    2. Speaking under Apple TTS reads the secret ZERO times.
//    3. Speaking under ElevenLabs reads the secret ON-DEMAND (>= 1) — and a
//       missing key still falls back to Apple (the never-break-a-spoken-answer
//       guarantee) without throwing out of the speaker.
//
//  BEFORE the fix (eager read at construction / on the hot path) #1 and #2 see a
//  non-zero count and FAIL; AFTER the fix they read zero and PASS.
//
//  HARDENING (closes a gap Codex flagged): an accessor-only spy sees reads that go
//  through a caller's INJECTED accessor, but a future DIRECT
//  `TTSKeychainStore.loadAPIKey()` — bypassing the accessor — would slip past it.
//  So these tests now install the spy at the STORE's single choke point
//  (`TTSKeychainStore.overrideSecretReaderForTesting`) and drive the objects with
//  the REAL production accessor (`TTSKeychainStore.loadAPIKey`). Any eager read on
//  the launch/hot path — via the accessor OR a direct static call — is therefore
//  observed and fails the gate. A meta-test proves the seam catches a direct call.
//  Because the seam is process-global, the suite is `.serialized`.
//

import Testing
import Foundation
@testable import Clawdy

/// Thread-safe spy standing in for the real Keychain accessor. Counts how many
/// times the secret was actually read and returns a canned value. `@unchecked
/// Sendable` + a lock because the speaker may invoke it from its chained Task.
private final class KeychainReadSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let cannedKey: String?

    init(returning cannedKey: String?) {
        self.cannedKey = cannedKey
    }

    /// The accessor closure to inject. Every call is a "secret read".
    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return cannedKey
    }

    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Polls `condition` until true or timeout (records an issue on timeout).
private func pollUntilTrue(
    timeoutSeconds: Double,
    _ description: String,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while await !condition() {
        if Date() >= deadline {
            Issue.record("timed out after \(timeoutSeconds)s waiting for: \(description)")
            return
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}

@Suite(.serialized)
@MainActor
struct KeychainAccessGatingTests {

    /// #1 — Constructing CompanionManager (what happens at launch) must NOT read
    /// the ElevenLabs secret. Before the fix a stored-property initializer read the
    /// Keychain here, firing the macOS prompt on every relaunch.
    ///
    /// The manager is built with its DEFAULT accessor (`TTSKeychainStore.loadAPIKey`),
    /// so this exercises the REAL production wiring routed through the store seam —
    /// catching an eager read whether it goes via the accessor or a direct static call.
    @Test func constructingManagerDoesNotReadTheElevenLabsSecret() {
        let spy = KeychainReadSpy(returning: "sk_fake_launch")
        TTSKeychainStore.overrideSecretReaderForTesting = spy.read
        defer { TTSKeychainStore.overrideSecretReaderForTesting = nil }

        _ = CompanionManager()
        #expect(spy.readCount == 0)
    }

    /// #2 — Speaking a response under Apple TTS must NOT read the ElevenLabs secret.
    /// Before the fix the caller resolved the key eagerly for every utterance, so an
    /// Apple-TTS user hit the prompt on every spoken answer.
    ///
    /// The speaker is given the REAL accessor as its key provider and the store seam
    /// is installed, so any read — accessor or direct static — would be observed.
    @Test func speakingUnderAppleTTSNeverReadsTheElevenLabsSecret() async {
        let spy = KeychainReadSpy(returning: "sk_fake_apple")
        TTSKeychainStore.overrideSecretReaderForTesting = spy.read
        defer { TTSKeychainStore.overrideSecretReaderForTesting = nil }
        let speaker = StreamingResponseSpeaker(
            provider: .apple,
            appleTTSClient: LocalSpeechTTSClient(),
            elevenLabsTTSClient: ElevenLabsTTSClient(),
            elevenLabsAPIKeyProvider: TTSKeychainStore.loadAPIKey,
            elevenLabsVoiceID: ElevenLabsAPI.defaultVoiceID,
            onPlaybackStarted: {}
        )

        speaker.enqueueSentence("Tokyo is the capital of Japan.")
        speaker.finish(finalRemainder: nil, fullSpokenText: "Tokyo is the capital of Japan.")

        // Let the utterance chain fully drain, then assert the secret was untouched.
        await pollUntilTrue(timeoutSeconds: 5, "Apple TTS utterance to finish") { [speaker] in
            !speaker.isSpeaking
        }
        #expect(spy.readCount == 0)
    }

    /// #3 — Speaking under ElevenLabs reads the secret ON-DEMAND (only when actually
    /// synthesizing). A missing key (spy returns nil) must still fall back to Apple
    /// without the speaker throwing — preserving the "a TTS/keychain error never
    /// breaks a spoken answer" guarantee.
    @Test func speakingUnderElevenLabsReadsTheSecretOnDemandThenFallsBack() async {
        let spy = KeychainReadSpy(returning: nil) // no key → must fall back to Apple
        TTSKeychainStore.overrideSecretReaderForTesting = spy.read
        defer { TTSKeychainStore.overrideSecretReaderForTesting = nil }
        let speaker = StreamingResponseSpeaker(
            provider: .elevenLabs,
            appleTTSClient: LocalSpeechTTSClient(),
            elevenLabsTTSClient: ElevenLabsTTSClient(),
            elevenLabsAPIKeyProvider: TTSKeychainStore.loadAPIKey,
            elevenLabsVoiceID: ElevenLabsAPI.defaultVoiceID,
            onPlaybackStarted: {}
        )

        speaker.enqueueSentence("Tell me a joke.")

        // The on-demand read happens the moment the ElevenLabs utterance runs.
        await pollUntilTrue(timeoutSeconds: 5, "on-demand ElevenLabs secret read") {
            spy.readCount >= 1
        }
        #expect(spy.readCount >= 1)

        // The utterance still resolves (missing key → silent Apple fallback), never
        // wedging the queue.
        await pollUntilTrue(timeoutSeconds: 5, "utterance to finish after fallback") { [speaker] in
            !speaker.isSpeaking
        }
    }

    /// #4 (guard-the-guard) — proves the store-level seam observes a DIRECT
    /// `TTSKeychainStore.loadAPIKey()` call, which is exactly the bypass an
    /// accessor-only spy could not see. This is what makes #1 and #2 able to fail
    /// if a future launch/hot path reintroduces a direct eager read instead of
    /// going through an injected accessor.
    @Test func gatingSeamObservesADirectStoreReadThatBypassesInjectedAccessors() {
        let spy = KeychainReadSpy(returning: "sk_direct_bypass")
        TTSKeychainStore.overrideSecretReaderForTesting = spy.read
        defer { TTSKeychainStore.overrideSecretReaderForTesting = nil }

        _ = TTSKeychainStore.loadAPIKey()
        #expect(spy.readCount == 1)
    }
}
