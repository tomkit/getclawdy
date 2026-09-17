//
//  KokoroTTSClientTests.swift
//  ClawdyTests
//
//  The bundled-voice client's cancellation contract: a re-press / Stop must cancel every
//  sentence that was handed to the synthesizer but not yet played, so the next turn's first
//  clip doesn't queue behind seconds of stale synthesis. Skipped when the model isn't bundled
//  in the test host (fresh clone before `scripts/fetch-models.sh`).
//

import Testing
import Foundation
@testable import Clawdy

@MainActor
struct KokoroTTSClientTests {
    @Test func stopPlaybackCancelsUnplayedPreparedClips() async throws {
        try #require(KokoroTTSClient.isModelBundled, "Kokoro model not bundled in the test host")
        let client = KokoroTTSClient()
        client.prewarm()
        _ = await client.synthesizer()

        let sentence = "This is a long sentence that takes the model a good while to synthesize, so cancellation has something to cut short."
        let prepared = (0..<5).map { _ in client.prepareClip(sentence) }
        client.stopPlayback()

        var cancelledCount = 0
        for clip in prepared {
            do {
                _ = try await clip.wavData.value
            } catch is CancellationError {
                cancelledCount += 1
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
        // The first clip may have been mid-run inside ORT (uninterruptible); the rest must be cancelled.
        #expect(cancelledCount >= prepared.count - 1)

        // And a fresh clip after the cancel plays promptly.
        let started = Date()
        try await client.speakText("Okay.")
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(client.isPlaying)
        client.stopPlayback()
    }
}
