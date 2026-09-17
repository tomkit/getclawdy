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
    @Test func instantAcknowledgementThenFillersNoEarlierThanThreeSeconds() {
        let schedule = AcknowledgementCueSchedule.default
        #expect(schedule.first?.delaySeconds == 0, "an instant spoken acknowledgement, not a sound effect")
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
}
