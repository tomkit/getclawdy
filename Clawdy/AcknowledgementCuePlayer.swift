//
//  AcknowledgementCuePlayer.swift
//  Clawdy
//
//  The ONE owner of the "I heard you / still working" audio cues, so nothing can play
//  over the reply. On push-to-talk release it plays the earcon at once, then schedules
//  the verbal fillers from `AcknowledgementCueSchedule`. The reply's first audio
//  PREEMPTS any filler that's mid-play (a quick fade, never a hard cut) and cancels the
//  rest; the turn ending for any other reason (a routing directive, an error, a re-press,
//  a stop) cancels everything. Fillers are rendered in the reply's OWN voice by
//  `AcknowledgementCueRenderer` and cached on disk, so they never cost a network round
//  trip at play time — a filler that isn't rendered yet is simply skipped.
//
//  Fillers play through their own `AVAudioPlayer`, deliberately outside
//  `StreamingResponseSpeaker`'s clip queue, so they can't delay a reply clip and the
//  speaker's `onPlaybackStarted` is the single preempt signal.
//

import AVFoundation
import Foundation

@MainActor
final class AcknowledgementCuePlayer {
    private let schedule: [AcknowledgementCueSchedule.Step]
    private let renderer: AcknowledgementCueRenderer
    private var scheduledTasks: [Task<Void, Never>] = []
    private var earconPlayer: AVAudioPlayer?
    private var fillerPlayer: AVAudioPlayer?
    private var replyAudioHasStarted = false
    private var turnHasEnded = true
    /// The voice the current turn's fillers must match (set per turn by the manager).
    private var currentVoice: AcknowledgementCueRenderer.Voice?

    init(
        schedule: [AcknowledgementCueSchedule.Step] = AcknowledgementCueSchedule.default,
        renderer: AcknowledgementCueRenderer = AcknowledgementCueRenderer()
    ) {
        self.schedule = schedule
        self.renderer = renderer
        if let earconURL = Bundle.main.url(forResource: "ack-earcon", withExtension: "wav") {
            earconPlayer = try? AVAudioPlayer(contentsOf: earconURL)
            earconPlayer?.prepareToPlay()
        }
    }

    /// Push-to-talk released: earcon now, fillers on the schedule, in `voice`.
    func beginTurn(voice: AcknowledgementCueRenderer.Voice) {
        cancel()
        turnHasEnded = false
        replyAudioHasStarted = false
        currentVoice = voice
        for step in schedule {
            switch step.cue {
            case .earcon:
                playEarcon()
            case .filler(let phrases):
                let delayNanoseconds = UInt64(step.delaySeconds * 1_000_000_000)
                scheduledTasks.append(Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    guard !Task.isCancelled, let self else { return }
                    guard AcknowledgementCueSchedule.shouldFire(
                        step: step, replyAudioHasStarted: self.replyAudioHasStarted, turnHasEnded: self.turnHasEnded
                    ) else { return }
                    self.playFiller(from: phrases)
                })
            }
        }
    }

    /// The reply's first audio is starting: fade out a filler in progress, drop the rest.
    func replyAudioStarted() {
        replyAudioHasStarted = true
        cancelScheduledFillers()
        fadeOutFiller()
    }

    /// The turn ended without reply audio (a routing directive, an error, cancellation).
    func turnEnded() {
        turnHasEnded = true
        cancelScheduledFillers()
        fadeOutFiller()
    }

    /// Hard stop: a new press, an app-level stop.
    func cancel() {
        turnHasEnded = true
        cancelScheduledFillers()
        fillerPlayer?.stop()
        fillerPlayer = nil
    }

    var isPlayingFillerForTesting: Bool { fillerPlayer?.isPlaying ?? false }
    var scheduledFillerCountForTesting: Int { scheduledTasks.count }

    // MARK: - Playback

    private func playEarcon() {
        earconPlayer?.currentTime = 0
        earconPlayer?.play()
    }

    private func playFiller(from phrases: [String]) {
        guard let currentVoice, let phrase = phrases.randomElement() else { return }
        // Only a cached render plays; rendering at play time would itself be latency.
        guard let fileURL = renderer.cachedFileURL(phrase: phrase, voice: currentVoice) else { return }
        guard let player = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        fillerPlayer?.stop()
        fillerPlayer = player
        player.volume = 1
        player.play()
    }

    private func fadeOutFiller() {
        guard let player = fillerPlayer, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 0.12)
        let fading = player
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            fading.stop()
            if self?.fillerPlayer === fading { self?.fillerPlayer = nil }
        }
    }

    private func cancelScheduledFillers() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }
}
