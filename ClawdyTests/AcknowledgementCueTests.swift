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
    @Test func acknowledgementAfterABeatThenFillersNoEarlierThanTwentySeconds() {
        let schedule = AcknowledgementCueSchedule.default
        #expect(schedule.first?.delaySeconds == 1.0, "a spoken acknowledgement a natural beat after the keys come up, not the instant they do")
        let laterDelays = schedule.dropFirst().map(\.delaySeconds)
        #expect(laterDelays.min()! >= 20.0, "a filler before ~20s doubles up with the acknowledgement on an ordinary 2–4s answer")
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
        let a = renderer.fileURL(phrase: "still checking.", voice: .kokoro(voiceID: "af_heart"))
        let b = renderer.fileURL(phrase: "still checking.", voice: .elevenLabs(voiceID: "21m00Tcm4TlvDq8ikWAM"))
        #expect(a.path.hasPrefix("/tmp/cues/kokoro-af_heart-v\(AcknowledgementCueRenderer.Voice.kokoroRenderVersion)/") && a.pathExtension == "wav")
        #expect(b.path.hasPrefix("/tmp/cues/elevenlabs-21m00Tcm4TlvDq8ikWAM/") && b.pathExtension == "mp3")
        #expect(a.lastPathComponent.dropLast(4) == b.lastPathComponent.dropLast(4), "same phrase → same digest across voices")
        #expect(renderer.cachedFileURL(phrase: "never rendered", voice: .kokoro(voiceID: "af_heart")) == nil)
    }

    @MainActor @Test func rendersAKokoroPhraseToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: dir)
        let voice = AcknowledgementCueRenderer.Voice.kokoro(voiceID: "af_heart")
        await renderer.renderMissing(phrases: ["let me check."], voice: voice, kokoroTTSClient: makeMutedKokoroTTSClient())
        let url = try #require(renderer.cachedFileURL(phrase: "let me check.", voice: voice))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 4000, "a real spoken clip, not an empty file")
    }
}

@MainActor
struct SpokenCueArbiterTests {
    @Test func replyTextCancelsPendingFillersAndTurnEndCancelsToo() async throws {
        let arbiter = SpokenCueArbiter(schedule: [
            .init(delaySeconds: 0, phrases: ["okay."]),
            .init(delaySeconds: 0.05, phrases: ["hmm"]),
            .init(delaySeconds: 5, phrases: ["still checking"])
        ], renderer: AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues")))
        arbiter.setVoice(.kokoro(voiceID: "af_heart"))
        arbiter.beginTurn()
        #expect(arbiter.scheduledFillerCountForTesting == 2)
        arbiter.replyBegan()
        #expect(arbiter.scheduledFillerCountForTesting == 0, "the reply's first text drops every pending filler")
        #expect(!arbiter.isCuePlaying)

        arbiter.beginTurn()
        arbiter.turnEnded()
        #expect(arbiter.scheduledFillerCountForTesting == 0, "a routed/failed turn drops them too")
    }

    /// A turn that ends without a spoken reply (a research hand-off, a voice answer to a
    /// research question) keeps its pending acknowledgement: the user still gets the nod.
    @Test func turnEndedKeepsThePendingAcknowledgementButDropsFillers() {
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues"))
        let arbiter = SpokenCueArbiter(schedule: [
            .init(delaySeconds: 1, phrases: ["okay."]),
            .init(delaySeconds: 3, phrases: ["let me look."])
        ], renderer: renderer)
        arbiter.setVoice(.kokoro(voiceID: "af_heart"))
        arbiter.beginTurn()
        arbiter.turnEnded()
        #expect(arbiter.isAcknowledgementPendingForTesting)
        #expect(arbiter.scheduledFillerCountForTesting == 1, "only the acknowledgement remains")
        arbiter.cancelTurn()
        #expect(!arbiter.isAcknowledgementPendingForTesting, "a hard stop cancels it")
    }

    /// A research hand-off must produce exactly ONE acknowledgement, whichever comes first.
    @Test func researchStartIsSkippedWhenTheTurnWasAlreadyAcknowledgedAndReplacesItOtherwise() {
        let renderer = AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues"))
        let arbiter = SpokenCueArbiter(schedule: [.init(delaySeconds: 5, phrases: ["okay."])], renderer: renderer)
        arbiter.setVoice(.kokoro(voiceID: "af_heart"))
        arbiter.setReplyOrRecordingActive(true)   // announcements queue, so they're countable

        // "mm-hm" already spoken → "on it" is dropped.
        arbiter.beginTurn()
        arbiter.markAcknowledgementSpokenForTesting()
        arbiter.announceResearchStart("on it.")
        #expect(arbiter.queuedAnnouncementCountForTesting == 0)

        // Router was quicker than the 1 s beat → the pending "mm-hm" is cancelled and "on it" stands in.
        arbiter.beginTurn()
        #expect(arbiter.isAcknowledgementPendingForTesting)
        arbiter.announceResearchStart("on it.")
        #expect(!arbiter.isAcknowledgementPendingForTesting, "the pending acknowledgement is cancelled")
        #expect(arbiter.queuedAnnouncementCountForTesting == 1, "the research line is the acknowledgement")
        #expect(arbiter.hasSpokenAcknowledgementThisTurnForTesting)
    }
}

@MainActor
struct SpokenCueSurvivalTests {
    /// REGRESSION: `stopAllTTS()` runs at the start of every request, right after the keys
    /// come up. It used to cancel the turn's cues too, so "mm-hm" was cut off (or never heard
    /// when transcription was quick), the fillers never fired, and a queued research
    /// announcement died whenever a follow-up answer started. The request start must leave
    /// the turn's cues alone; only a real stop (re-press, Stop button) cancels them.
    @Test func requestStartKeepsTheTurnsScheduledFillers() {
        let manager = CompanionManager(loadElevenLabsAPIKeyFromKeychain: { nil }, kokoroTTSClient: makeMutedKokoroTTSClient())
        manager.setSelectedTTSEngineForTesting(.kokoro)
        manager.simulateReleaseThenRequestStartForTesting()
        #expect(manager.scheduledCueFillerCountForTesting == 2, "the 1 s ack and the 20 s filler are still armed after the request started")
        manager.cancelQuickAnswer()
        #expect(manager.scheduledCueFillerCountForTesting == 0, "a real Stop cancels them")
    }
}
