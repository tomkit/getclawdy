//
//  AcknowledgementCueTests.swift
//  ClawdyTests
//
//  The "I heard you / still working" cues: the schedule's thresholds and fire rule, the
//  renderer's cache layout + a real Apple render to disk, and the player's arbitration
//  (reply audio preempts, turn end cancels, nothing overlaps).
//

import Testing
import Foundation
import AVFoundation
@testable import Clawdy

struct AcknowledgementCueScheduleTests {
    @Test func acknowledgementAfterABeatThenFillersNoEarlierThanThreeSeconds() {
        let schedule = AcknowledgementCueSchedule.default
        #expect(schedule.first?.delaySeconds == 1.0, "a spoken acknowledgement a natural beat after the keys come up, not the instant they do")
        let laterDelays = schedule.dropFirst().map(\.delaySeconds)
        #expect(laterDelays.min()! >= 3.0, "a filler before ~3s would collide with an easy answer's first audio (~2–2.5s)")
        #expect(laterDelays == laterDelays.sorted())
        #expect(!AcknowledgementCueSchedule.allPhrases().isEmpty)
    }

    @Test func fillersFireOnlyWhileTheReplyIsSilentAndTheTurnIsLive() {
        let step = AcknowledgementCueSchedule.Step(delaySeconds: 3, phrases: ["hmm"])
        #expect(AcknowledgementCueSchedule.shouldFire(step: step, replyHasBegun: false, turnHasEnded: false))
        #expect(!AcknowledgementCueSchedule.shouldFire(step: step, replyHasBegun: true, turnHasEnded: false))
        #expect(!AcknowledgementCueSchedule.shouldFire(step: step, replyHasBegun: false, turnHasEnded: true))
    }
}

struct AcknowledgementCueRendererTests {
    @Test func cachePathsAreStablePerVoiceAndPhrase() {
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: URL(fileURLWithPath: "/tmp/cues"))
        let a = renderer.fileURL(phrase: "still checking.", voice: .apple(voiceIdentifier: "com.apple.voice.premium.en-US.Ava"))
        let b = renderer.fileURL(phrase: "still checking.", voice: .elevenLabs(voiceID: "21m00Tcm4TlvDq8ikWAM"))
        #expect(a.path.hasPrefix("/tmp/cues/apple-com.apple.voice.premium.en-US.Ava/") && a.pathExtension == "caf")
        #expect(b.path.hasPrefix("/tmp/cues/elevenlabs-21m00Tcm4TlvDq8ikWAM/") && b.pathExtension == "mp3")
        #expect(a.lastPathComponent.dropLast(4) == b.lastPathComponent.dropLast(4), "same phrase → same digest across voices")
        #expect(renderer.cachedFileURL(phrase: "never rendered", voice: .apple(voiceIdentifier: nil)) == nil)
    }

    @Test func rendersAnApplePhraseToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: dir)
        await renderer.renderMissing(phrases: ["hmm, let me look."], voice: .apple(voiceIdentifier: nil))
        let url = try #require(renderer.cachedFileURL(phrase: "hmm, let me look.", voice: .apple(voiceIdentifier: nil)))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 4000, "a real spoken clip, not an empty file")
    }
}

@MainActor
struct SpokenCueArbiterTests {
    @Test func replyTextCancelsPendingFillersAndTurnEndCancelsToo() async throws {
        let arbiter = SpokenCueArbiter(schedule: [
            .init(delaySeconds: 0, phrases: ["mm-hm."]),
            .init(delaySeconds: 0.05, phrases: ["hmm"]),
            .init(delaySeconds: 5, phrases: ["still checking"])
        ], renderer: AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues")))
        arbiter.setVoice(.apple(voiceIdentifier: nil))
        arbiter.beginTurn()
        #expect(arbiter.scheduledFillerCountForTesting == 2)
        arbiter.replyBegan()
        #expect(arbiter.scheduledFillerCountForTesting == 0, "the reply's first text drops every pending filler")
        #expect(!arbiter.isCuePlaying)

        arbiter.beginTurn()
        arbiter.turnEnded()
        #expect(arbiter.scheduledFillerCountForTesting == 0, "a routed/failed turn drops them too")
    }

    /// A research hand-off must produce exactly ONE acknowledgement, whichever comes first.
    @Test func researchStartIsSkippedWhenTheTurnWasAlreadyAcknowledgedAndReplacesItOtherwise() {
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues"))
        let arbiter = SpokenCueArbiter(schedule: [.init(delaySeconds: 5, phrases: ["mm-hm."])], renderer: renderer)
        arbiter.setVoice(.apple(voiceIdentifier: nil))
        arbiter.setReplyOrRecordingActive(true)   // announcements queue, so they're countable

        // "mm-hm" already spoken → "on it" is dropped.
        arbiter.beginTurn()
        arbiter.markAcknowledgementSpokenForTesting()
        arbiter.announceResearchStart("on it.")
        #expect(arbiter.queuedAnnouncementCountForTesting == 0)

        // Router was quicker than the 1 s beat → the pending "mm-hm" is cancelled and "on it" stands in.
        arbiter.beginTurn()
        #expect(arbiter.scheduledFillerCountForTesting == 1)
        arbiter.announceResearchStart("on it.")
        #expect(arbiter.scheduledFillerCountForTesting == 0, "the pending acknowledgement is cancelled")
        #expect(arbiter.queuedAnnouncementCountForTesting == 1, "the research line is the acknowledgement")
        #expect(arbiter.hasSpokenAcknowledgementThisTurnForTesting)
    }
}

@MainActor
private final class SilentFakeTTSClient: SpeechTTSProviding {
    func speakText(_ text: String) async throws {}
    var isPlaying: Bool { false }
    func stopPlayback() {}
}

@MainActor
struct SpokenCueSurvivalTests {
    /// REGRESSION: `stopAllTTS()` runs at the start of every request, right after the keys
    /// come up. It used to cancel the turn's cues too, so "mm-hm" was cut off (or never heard
    /// when transcription was quick), the 3/8/15 s fillers never fired, and a queued research
    /// announcement died whenever a follow-up answer started. The request start must leave
    /// the turn's cues alone; only a real stop (re-press, Stop button) cancels them.
    @Test func requestStartKeepsTheTurnsScheduledFillers() {
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, localTTSClient: SilentFakeTTSClient())
        manager.setSelectedTTSEngineForTesting(.apple)
        manager.simulateReleaseThenRequestStartForTesting()
        #expect(manager.scheduledCueFillerCountForTesting == 4, "the 1 s ack and the 3 s / 8 s / 15 s fillers are still armed after the request started")
        manager.cancelQuickAnswer()
        #expect(manager.scheduledCueFillerCountForTesting == 0, "a real Stop cancels them")
    }
}
