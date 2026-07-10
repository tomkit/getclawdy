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

/// Collects the clip reports the streaming speaker emits, so a test can assert a report is
/// emitted even when a clip falls back to Apple (BLOCKER 3 — the anti-hang guarantee).
@MainActor
final class ClipReportCollector {
    private(set) var reports: [SpokenClipReport] = []
    func record(_ report: SpokenClipReport) { reports.append(report) }
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

    // MARK: - One consistent coordinate system + clip boundary (BLOCKER 2)

    /// A clip is located within the spoken text so point positions and the clip boundary
    /// share ONE ruler (the spoken text), including the inter-clip separator whitespace.
    @Test func clipStartOffsetLocatesEachClipInTheSpokenText() {
        let spokenText = "First sentence. Second sentence."
        // Clip 0 "First sentence." starts at 0.
        #expect(PointAudioSyncMapper.clipStartOffset(of: "First sentence.", in: spokenText, from: 0) == 0)
        // Clip 1 "Second sentence." starts at 16 (after "First sentence." + the separator space).
        #expect(PointAudioSyncMapper.clipStartOffset(of: "Second sentence.", in: spokenText, from: 15) == 16)
        // A clip whose text isn't present returns nil (caller falls back to a running cursor).
        #expect(PointAudioSyncMapper.clipStartOffset(of: "not here", in: spokenText, from: 0) == nil)
    }

    /// BLOCKER 2: a POINT tag right after clip 0's final word/punctuation is anchored to
    /// clip 0 and must map to clip 0's alignment/playhead — NOT clip 1's. Routing keys off the
    /// NAMED word, so the boundary tag reads clip 0's timeline.
    @Test func aPointAtTheEndOfClipZeroMapsToClipZeroNotClipOne() throws {
        // Spoken text is two clips. A [POINT] tag sat right after clip 0's last word, so its
        // spoken position lands at clip 0's end (or in the separator before clip 1).
        let spokenText = "open the run panel then quit"
        let clipZeroText = "open the run panel"      // clip 0
        let clipOneText = "then quit"                // clip 1 (batched remainder)

        let clipZeroStart = try #require(PointAudioSyncMapper.clipStartOffset(of: clipZeroText, in: spokenText, from: 0))
        let clipZeroEnd = clipZeroStart + clipZeroText.count // 18
        let clipOneStart = try #require(PointAudioSyncMapper.clipStartOffset(of: clipOneText, in: spokenText, from: clipZeroEnd)) // 19

        // A tag right after clip 0's last word "panel" sits at position 18 (its end / the
        // separator space). Its named word ("panel") is in clip 0, so it maps to clip 0.
        let boundaryPosition = clipZeroEnd
        #expect(PointAudioSyncMapper.belongsToFirstClip(spokenPosition: boundaryPosition, firstClipEndOffset: clipZeroEnd, in: spokenText) == true)
        // Re-based into clip 0's coordinate it is position 18 (clamped by the anchor to the
        // last word), NOT some position inside clip 1.
        let clipZeroPosition = PointAudioSyncMapper.positionInClip(spokenPosition: boundaryPosition, clipStartOffset: clipZeroStart)
        #expect(clipZeroPosition == 18)

        // The naming word before the tag is "panel" — resolved in clip 0's alignment, proving
        // the boundary point reads clip 0's timeline, not clip 1's.
        let clipZeroAlignment = alignment(for: clipZeroText)
        let wordStart = PointAudioSyncMapper.indexOfWordStartBefore(positionInClip: clipZeroPosition, characters: clipZeroAlignment.characters)
        // "panel" starts at index 13 in "open the run panel".
        #expect(wordStart == 13)

        // A position genuinely inside clip 1 belongs to clip 1 and re-bases to its own zero.
        let clipOnePosition = PointAudioSyncMapper.positionInClip(spokenPosition: clipOneStart + 5, clipStartOffset: clipOneStart)
        #expect(PointAudioSyncMapper.belongsToFirstClip(spokenPosition: clipOneStart + 5, firstClipEndOffset: clipZeroEnd, in: spokenText) == false)
        #expect(clipOnePosition == 5)
    }

    /// BLOCKER 2 (residual): a POINT anchored in the SEPARATOR WHITESPACE after clip 0's last
    /// word — including a tag one PAST clip 0's trimmed end (or at clip 1's first character) —
    /// maps to clip 0 and schedules against clip 0's alignment/playhead. The earlier
    /// `spokenPosition <= clipZeroEnd` rule mis-routed exactly `clipZeroEnd + 1` to clip 1.
    @Test func aPointInTheSeparatorWhitespaceMapsToClipZeroNotClipOne() throws {
        // "Click panel. Then go." — clip 0 "Click panel." ends at 12; clip 1 "Then go."
        // starts at 13 (single-space separator at index 12).
        let spokenText = "Click panel. Then go."
        let clipZeroText = "Click panel."
        let clipOneText = "Then go."
        let clipZeroStart = try #require(PointAudioSyncMapper.clipStartOffset(of: clipZeroText, in: spokenText, from: 0))
        let clipZeroEnd = clipZeroStart + clipZeroText.count // 12
        let clipOneStart = try #require(PointAudioSyncMapper.clipStartOffset(of: clipOneText, in: spokenText, from: clipZeroEnd)) // 13
        #expect(clipZeroEnd == 12)
        #expect(clipOneStart == 13)

        // The reviewer's exact case: a tag at clipZeroEnd + 1 (== clipOneStart for a single
        // -space separator). Its named word is still "panel" (clip 0), so it maps to clip 0 —
        // the OLD `spokenPosition <= clipZeroEnd` rule wrongly sent this to clip 1.
        let separatorPosition = clipZeroEnd + 1
        #expect(PointAudioSyncMapper.belongsToFirstClip(spokenPosition: separatorPosition, firstClipEndOffset: clipZeroEnd, in: spokenText) == true)

        // It schedules against CLIP 0's alignment — the fire time resolves to "panel" (clip 0
        // local index 6 → 0.6s with our synthetic alignment), NOT anything in clip 1.
        let clipZeroAlignment = alignment(for: clipZeroText)
        let fireTime = try #require(PointAudioSyncMapper.fireTimeSeconds(
            spokenPosition: separatorPosition,
            clipStartOffset: clipZeroStart,
            alignment: clipZeroAlignment,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        ))
        #expect(abs(fireTime - 0.6) < 0.0001)
    }

    /// MINOR (BLOCKER 2 follow-on): when clip 1's text can't be located on the spoken-text
    /// ruler (a whitespace-normalization mismatch — the speaker batches later sentences with
    /// single spaces while the spoken text keeps the original whitespace), the point DEGRADES
    /// to the untimed dwell (nil fire time) rather than re-basing from a guessed offset.
    @Test func aClipThatCannotBeLocatedDegradesToUntimedRatherThanMisScheduling() {
        let clipOneAlignment = alignment(for: "open the run panel")
        // clipStartOffset is nil (clip couldn't be located) → the composed fire time is nil,
        // which the scheduler reads as "degrade this target to the untimed fixed dwell".
        let degraded = PointAudioSyncMapper.fireTimeSeconds(
            spokenPosition: 42,
            clipStartOffset: nil,
            alignment: clipOneAlignment,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        )
        #expect(degraded == nil)

        // With a valid located offset, the same point DOES schedule (non-nil) — proving nil
        // means "unlocatable", not "always degrade".
        let scheduled = PointAudioSyncMapper.fireTimeSeconds(
            spokenPosition: 42,
            clipStartOffset: 30,
            alignment: clipOneAlignment,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        )
        #expect(scheduled != nil)
    }

    /// TRAP 2: a clip-1 point resolves against clip 1's OWN zero. Re-basing by the located
    /// clip-1 start (a global-timeline bug would index far past the clip).
    @Test func clipOnePointResolvesToClipOneLocalTimeNotGlobalTime() throws {
        let spokenText = "go left. open the run panel"
        let clipOneText = "open the run panel"
        let clipOneStart = try #require(PointAudioSyncMapper.clipStartOffset(of: clipOneText, in: spokenText, from: 8)) // 9
        let clipOneAlignment = alignment(for: clipOneText)

        // A tag right after "run" in clip 1 sits at global position clipOneStart + 12.
        let positionInClip = PointAudioSyncMapper.positionInClip(spokenPosition: clipOneStart + 12, clipStartOffset: clipOneStart)
        #expect(positionInClip == 12)

        let fireTime = try #require(PointAudioSyncMapper.fireTimeSeconds(
            alignment: clipOneAlignment,
            positionInClip: positionInClip,
            strategy: .startOfWordBeforeTag,
            leadSeconds: 0.0
        ))
        // "run" starts at clip-1-local index 9 → 0.9s in clip 1's OWN timeline. A global
        // -timeline bug (position 21) would index near/after the clip end and give ~1.7s+.
        #expect(abs(fireTime - 0.9) < 0.0001)
    }

    // MARK: - Timed-vs-untimed eligibility (BLOCKER 1 & 4)

    /// BLOCKER 1: a genuinely-timed response (ElevenLabs, clip 0 returned non-empty
    /// alignment) MUST use timed sync. This is the decision `resolveAudioSyncEligibility`
    /// makes AFTER finish, so a one-sentence reply (whose only clip is reported at finish)
    /// is no longer wrongly dropped to the fixed dwell.
    @Test func oneSentenceElevenLabsResponseWithAlignmentUsesTimedSync() {
        let clipZeroAlignment = alignment(for: "click the run button")
        #expect(PointAudioSyncMapper.shouldUseTimedPointing(
            providerIsElevenLabs: true,
            firstClipAlignment: clipZeroAlignment
        ) == true)
    }

    /// BLOCKER 4: the untimed multi-point walk runs ONLY when per-word timing is truly
    /// unavailable — Apple TTS (never ElevenLabs), or ElevenLabs that produced no alignment.
    /// Never as a mask over an available-but-mis-decided timed path.
    @Test func untimedWalkOnlyWhenTimingTrulyUnavailable() {
        let realAlignment = alignment(for: "click the run button")
        // Apple TTS → untimed, regardless of any alignment.
        #expect(PointAudioSyncMapper.shouldUseTimedPointing(providerIsElevenLabs: false, firstClipAlignment: realAlignment) == false)
        // ElevenLabs but clip 0 produced no alignment → untimed.
        #expect(PointAudioSyncMapper.shouldUseTimedPointing(providerIsElevenLabs: true, firstClipAlignment: nil) == false)
        let emptyAlignment = SpeechClipAlignment(characters: [], characterStartTimesSeconds: [], characterEndTimesSeconds: [])
        #expect(PointAudioSyncMapper.shouldUseTimedPointing(providerIsElevenLabs: true, firstClipAlignment: emptyAlignment) == false)
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

    /// BLOCKER 3: when an ElevenLabs-intended clip fails and falls back to Apple, the speaker
    /// STILL emits a clip report (with no alignment). Without it, the manager's scheduler
    /// would wait ~12s for a report that never comes and strand the cursor. Here the
    /// ElevenLabs client has no key, so clip 0 throws `missingAPIKey` and falls back to Apple
    /// — and we assert a report is emitted PROMPTLY with nil alignment.
    @MainActor
    @Test func clipFallingBackToAppleStillReportsSoTheCursorNeverHangs() async {
        let collector = ClipReportCollector()
        let fakeApple = FakeNoTimingTTSClient()
        let speaker = StreamingResponseSpeaker(
            provider: .elevenLabs,
            appleTTSClient: fakeApple,
            elevenLabsTTSClient: ElevenLabsTTSClient(),
            // No key → ElevenLabs throws missingAPIKey → the clip falls back to Apple.
            elevenLabsAPIKeyProvider: { nil },
            elevenLabsVoiceID: "voice",
            onPlaybackStarted: {},
            onClipSpoken: { [collector] report in collector.record(report) }
        )

        speaker.enqueueSentence("click the run button.")
        speaker.finish(finalRemainder: nil, fullSpokenText: "click the run button.")
        await speaker.awaitAllPlaybackFinished()

        // A report WAS emitted (the anti-hang guarantee) even though the clip fell back...
        #expect(collector.reports.count >= 1)
        // ...and it carries NO alignment, so the scheduler degrades to the untimed walk.
        #expect(collector.reports.first?.timing.alignment == nil)
        // The chunk really was spoken through Apple.
        #expect(fakeApple.spokenTexts.contains("click the run button."))
    }

    // MARK: - Tunables live in one place

    @Test func leadDefaultsToRoughlyPointFourAndAnchorsOnTheWordBeforeTheTag() {
        // The tunables the user will adjust during live testing: a ~0.4s lead and the
        // start-of-word-before-tag anchor. Guard the defaults so they stay centralized.
        #expect(PointAudioSyncTuning.leadSeconds == 0.4)
        #expect(PointAudioSyncTuning.anchorStrategy == .startOfWordBeforeTag)
    }
}
