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
    @Test func earconIsInstantAndFillersStartNoEarlierThanThreeSeconds() {
        let schedule = AcknowledgementCueSchedule.default
        #expect(schedule.first == AcknowledgementCueSchedule.Step(delaySeconds: 0, cue: .earcon))
        let fillerDelays = schedule.compactMap { step -> TimeInterval? in
            if case .filler = step.cue { return step.delaySeconds }
            return nil
        }
        #expect(fillerDelays.min()! >= 3.0, "a verbal filler before ~3s would collide with an easy answer's first audio (~2–2.5s)")
        #expect(fillerDelays == fillerDelays.sorted())
        #expect(!AcknowledgementCueSchedule.allPhrases().isEmpty)
    }

    @Test func fillersFireOnlyWhileTheReplyIsSilentAndTheTurnIsLive() {
        let step = AcknowledgementCueSchedule.Step(delaySeconds: 3, cue: .filler(phrases: ["hmm"]))
        #expect(AcknowledgementCueSchedule.shouldFire(step: step, replyAudioHasStarted: false, turnHasEnded: false))
        #expect(!AcknowledgementCueSchedule.shouldFire(step: step, replyAudioHasStarted: true, turnHasEnded: false))
        #expect(!AcknowledgementCueSchedule.shouldFire(step: step, replyAudioHasStarted: false, turnHasEnded: true))
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
struct AcknowledgementCuePlayerTests {
    @Test func replyAudioCancelsPendingFillersAndTurnEndCancelsToo() async throws {
        let player = AcknowledgementCuePlayer(schedule: [
            .init(delaySeconds: 0, cue: .earcon),
            .init(delaySeconds: 0.05, cue: .filler(phrases: ["hmm"])),
            .init(delaySeconds: 5, cue: .filler(phrases: ["still checking"]))
        ], renderer: AcknowledgementCueRenderer(cacheRootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-cues")))
        player.beginTurn(voice: .apple(voiceIdentifier: nil))
        #expect(player.scheduledFillerCountForTesting == 2)
        player.replyAudioStarted()
        #expect(player.scheduledFillerCountForTesting == 0, "reply audio drops every pending filler")
        #expect(!player.isPlayingFillerForTesting)

        player.beginTurn(voice: .apple(voiceIdentifier: nil))
        player.turnEnded()
        #expect(player.scheduledFillerCountForTesting == 0, "a routed/failed turn drops them too")
    }
}
