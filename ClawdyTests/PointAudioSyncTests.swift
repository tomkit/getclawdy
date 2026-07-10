//
//  PointAudioSyncTests.swift
//  ClawdyTests
//
//  Unit tests for Stage 4: syncing (and slightly LEADING) the shadow-cursor advance to
//  ElevenLabs speech using character-level timestamps. These cover the PURE mapping logic
//  only — the async polling that WAITS for those times, and the live audio itself, are
//  validated by the user's own test build (feel-tuned against real audio). The two traps
//  are guarded here: alignment-vs-normalized indexing (via the parser test in TTSTests)
//  and per-clip re-basing (clip 2 uses clip 2's own zero, not a global timeline).
//

import Testing
import Foundation
import CoreGraphics
@testable import Clawdy

/// A TTS provider that speaks but produces NO character timing — stands in for Apple TTS
/// (or any provider using the protocol default `speakTextReportingTiming`), to prove the
/// graceful-degradation path.
@MainActor
final class FakeNoTimingTTSClient: SpeechTTSProviding {
    private(set) var spokenTexts: [String] = []
    func speakText(_ text: String) async throws { spokenTexts.append(text) }
    var isPlaying: Bool { false }
    func stopPlayback() {}
    // Deliberately does NOT override speakTextReportingTiming — it uses the protocol
    // default, which speaks via speakText and returns SpokenClipTiming.none.
}

struct PointAudioSyncTests {

    /// Builds a clip alignment where each character starts at index * 0.1s (so the audio
    /// time of a character equals its index tenth-of-a-second) for easy arithmetic checks.
    private func alignment(for text: String) -> SpeechClipAlignment {
        let characters = text.map { String($0) }
        let starts = characters.indices.map { Double($0) * 0.1 }
        let ends = characters.indices.map { Double($0) * 0.1 + 0.1 }
        return SpeechClipAlignment(
            characters: characters,
            characterStartTimesSeconds: starts,
            characterEndTimesSeconds: ends
        )
    }

    // MARK: - Word-before mapping

    @Test func wordStartBeforeSkipsWhitespaceAndFindsWordStart() {
        // "click run " — a POINT tag sat at position 9 (right after "run" and its space).
        // The word before is "run", which starts at index 6.
        let characters = "click run ".map { String($0) }
        #expect(PointAudioSyncMapper.indexOfWordStartBefore(positionInClip: 9, characters: characters) == 6)
    }

    @Test func wordStartBeforeHandlesPositionRightAfterAWordWithNoTrailingSpace() {
        // "click run" — position 9 is one past the end (tag immediately after "run").
        // The word before still resolves to "run" starting at index 6.
        let characters = "click run".map { String($0) }
        #expect(PointAudioSyncMapper.indexOfWordStartBefore(positionInClip: 9, characters: characters) == 6)
    }

    @Test func wordStartBeforeClampsAtTheStart() {
        let characters = "run".map { String($0) }
        #expect(PointAudioSyncMapper.indexOfWordStartBefore(positionInClip: 0, characters: characters) == 0)
        #expect(PointAudioSyncMapper.indexOfWordStartBefore(positionInClip: -5, characters: characters) == 0)
    }

    // MARK: - Fire time (anchor on word start, subtract lead, clamp)

    @Test func fireTimeAnchorsOnWordStartMinusLead() throws {
        // "click run " → word "run" starts at index 6 → 0.6s. Lead 0.4 → fire at 0.2s.
        let a = alignment(for: "click run ")
        let fireTime = try #require(PointAudioSyncMapper.fireTimeSeconds(
            alignment: a,
            positionInClip: 9,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.4
        ))
        #expect(abs(fireTime - 0.2) < 0.0001)
    }

    @Test func fireTimeClampsToZeroWhenLeadExceedsWordTime() {
        // Word "run" starts at 0.6s but the lead is a full second → clamp to 0 (fire now),
        // never a negative time (the playhead can't be negative).
        let a = alignment(for: "click run ")
        let fireTime = PointAudioSyncMapper.fireTimeSeconds(
            alignment: a,
            positionInClip: 9,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 1.0
        )
        #expect(fireTime == 0.0)
    }

    @Test func fireTimeAtTagPositionStrategyAnchorsOnTheTagCharacter() throws {
        // The alternate anchor strategy: anchor on the tag position itself (index 5 → 0.5s)
        // minus the lead 0.1 → 0.4s.
        let a = alignment(for: "abcdefgh")
        let fireTime = try #require(PointAudioSyncMapper.fireTimeSeconds(
            alignment: a,
            positionInClip: 5,
            strategy: .atTagPosition,
            leadSeconds: 0.1
        ))
        #expect(abs(fireTime - 0.4) < 0.0001)
    }

    @Test func fireTimeIsNilForEmptyAlignmentSoTheCallerDegrades() {
        let empty = SpeechClipAlignment(characters: [], characterStartTimesSeconds: [], characterEndTimesSeconds: [])
        let fireTime = PointAudioSyncMapper.fireTimeSeconds(
            alignment: empty,
            positionInClip: 3,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.4
        )
        #expect(fireTime == nil)
    }

    @Test func fireTimeIsNilWhenTimeArraysAreShorterThanCharacters() {
        // A malformed response (times shorter than characters) must yield nil rather than
        // index out of range — the caller then advances that point immediately.
        let malformed = SpeechClipAlignment(
            characters: ["a", "b", "c"],
            characterStartTimesSeconds: [0.0], // too short
            characterEndTimesSeconds: [0.1]
        )
        let fireTime = PointAudioSyncMapper.fireTimeSeconds(
            alignment: malformed,
            positionInClip: 2,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        )
        #expect(fireTime == nil)
    }

    // MARK: - Per-clip re-basing (TRAP 2)

    /// A point whose spoken position lands in clip 1 (the batched remainder) must be
    /// re-based to clip 1's OWN zero — clip 1's alignment starts at 0, so its positions are
    /// measured from the start of clip 1's text, not the global spoken text.
    @Test func clipAssignmentRebasesClipTwoPositionsToClipTwoZero() {
        let firstClipTextLength = 20

        // Position 5 is inside clip 0 → clip 0, unchanged.
        let inClipZero = PointAudioSyncMapper.clipAssignment(spokenPosition: 5, firstClipTextLength: firstClipTextLength)
        #expect(inClipZero.clipOrdinal == 0)
        #expect(inClipZero.positionInClip == 5)

        // Position 33 is past clip 0 → clip 1, re-based to 33 - 20 = 13 (NOT 33).
        let inClipOne = PointAudioSyncMapper.clipAssignment(spokenPosition: 33, firstClipTextLength: firstClipTextLength)
        #expect(inClipOne.clipOrdinal == 1)
        #expect(inClipOne.positionInClip == 13)
    }

    @Test func clipAssignmentPutsTheBoundaryPositionIntoClipOne() {
        // Exactly at the boundary belongs to clip 1 (clip 0 is [0, len)).
        let assignment = PointAudioSyncMapper.clipAssignment(spokenPosition: 20, firstClipTextLength: 20)
        #expect(assignment.clipOrdinal == 1)
        #expect(assignment.positionInClip == 0)
    }

    /// Two points at the SAME clip-relative position but in different clips resolve to the
    /// same within-clip time, proving the re-base — a global-timeline bug would give clip 1
    /// a much larger time.
    @Test func rebasedClipTwoPointResolvesToClipTwoLocalTimeNotGlobalTime() throws {
        let firstClipTextLength = 30
        // Clip 1's text is "open the run panel" — "run" starts at local index 9.
        let clipOneAlignment = alignment(for: "open the run panel")

        // Global position 39 → clip 1 local 9 (39 - 30). A POINT tag right after "run" would
        // sit a couple chars later; use the tag position 12 (just after "run ").
        let assignment = PointAudioSyncMapper.clipAssignment(spokenPosition: 30 + 12, firstClipTextLength: firstClipTextLength)
        #expect(assignment.clipOrdinal == 1)
        #expect(assignment.positionInClip == 12)

        let fireTime = try #require(PointAudioSyncMapper.fireTimeSeconds(
            alignment: clipOneAlignment,
            positionInClip: assignment.positionInClip,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        ))
        // "run" starts at clip-1-local index 9 → 0.9s in clip 1's OWN timeline. If the code
        // had used the global position 42, it would index way past the clip (clamped) and
        // report a very different time.
        #expect(abs(fireTime - 0.9) < 0.0001)
    }

    // MARK: - Graceful degradation (no alignment -> untimed sequence)

    /// A provider WITHOUT timing (Apple TTS, or any provider that uses the protocol
    /// default) still speaks, but reports NO alignment and NO playhead — the signal
    /// `CompanionManager` uses to fall back to the untimed, fixed-dwell pointing sequence.
    @MainActor
    @Test func providerWithoutTimingSpeaksButReportsNoAlignmentSoPointingDegrades() async throws {
        let fake = FakeNoTimingTTSClient()
        let timing = try await fake.speakTextReportingTiming("point at the run button")

        // It DID speak (audio still plays)...
        #expect(fake.spokenTexts == ["point at the run button"])
        // ...but produced no alignment/playhead, so audio-sync is impossible → degrade.
        #expect(timing.alignment == nil)
        #expect(timing.playheadSecondsReader == nil)
        // The shared "no timing" sentinel is genuinely empty.
        #expect(SpokenClipTiming.none.alignment == nil)
        #expect(SpokenClipTiming.none.playheadSecondsReader == nil)
    }

    /// A fresh manager begins with pointing NOT audio-synced, and a plain
    /// `beginPointingSequence` (no ElevenLabs timing in play) leaves it that way — the
    /// overlay then keeps its Stage 1–3 fixed-dwell walk.
    @MainActor
    @Test func managerDefaultsToUntimedPointingWhenNoAudioTimingIsPresent() {
        let manager = CompanionManager()
        #expect(manager.pointingAdvanceIsAudioSynced == false)

        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        manager.beginPointingSequence([
            CompanionManager.DetectedElementTarget(screenLocation: .zero, displayFrame: frame, elementLabel: "a"),
            CompanionManager.DetectedElementTarget(screenLocation: CGPoint(x: 1, y: 1), displayFrame: frame, elementLabel: "b"),
        ])
        // Nothing turned audio-sync on, so the walk stays untimed (fixed dwell).
        #expect(manager.pointingAdvanceIsAudioSynced == false)
    }

    // MARK: - Tunables live in one place

    @Test func leadDefaultsToRoughlyPointFourAndAnchorsOnTheWordBeforeTheTag() {
        // The tunables the user will adjust during live testing: a ~0.4s lead and the
        // start-of-word-before-tag anchor. Guard the defaults so they stay centralized.
        #expect(PointAudioSyncTuning.leadSeconds == 0.4)
        #expect(PointAudioSyncTuning.anchorStrategy == .startOfWordBeforeTag)
    }
}
