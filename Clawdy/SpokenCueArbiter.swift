//
//  SpokenCueArbiter.swift
//  Clawdy
//
//  The ONE owner of every DETERMINISTIC spoken cue — the push-to-talk acknowledgements
//  ("let me check", "still checking") and the research announcements ("on it", "your page is
//  ready") — and the gate the REPLY audio passes through, so no two voice outputs ever
//  overlap, whether they came from a pre-rendered file or from a live API call:
//
//    • A cue plays only when nothing else is speaking. If the reply (or the user's own
//      recording) is active, an announcement waits in a queue and plays when it's over.
//    • The reply never talks over a cue: `StreamingResponseSpeaker` awaits
//      `waitUntilNoCueIsPlaying()` before each clip. Cues are ≤ ~1s, so the worst case is
//      a sub-second wait, and the common case never waits because pending fillers are
//      dropped the moment the reply's first TEXT arrives (audio is then <1s away).
//    • No sound effects, anywhere: every cue is the reply's own voice, pre-rendered by
//      `AcknowledgementCueRenderer` and cached; an un-rendered phrase is skipped.
//

import AVFoundation
import Foundation

@MainActor
final class SpokenCueArbiter {
    private let schedule: [AcknowledgementCueSchedule.Step]
    private let renderer: AcknowledgementCueRenderer
    /// The filler steps (3 s / 8 s / 15 s), cancelled when the turn ends any way.
    private var scheduledTasks: [Task<Void, Never>] = []
    /// The acknowledgement step (the 1 s "let me check"), kept when a turn ends WITHOUT a spoken
    /// reply (a research hand-off, a voice answer to a question) — the user still gets
    /// their nod — and cancelled only by a hard stop or a replacing announcement.
    private var acknowledgementTask: Task<Void, Never>?
    private var cuePlayer: AVAudioPlayer?
    private var replyHasBegun = false
    private var turnHasEnded = true
    /// Whether this turn's acknowledgement ("let me check") has already been spoken, so a research
    /// hand-off doesn't add a second one ("on it…") right behind it.
    private var hasSpokenAcknowledgementThisTurn = false
    /// True while the reply is speaking or the user is recording: announcements queue.
    private var isReplyOrRecordingActive = false
    private var queuedAnnouncements: [String] = []
    /// The voice every cue must match (set per turn / on voice change by the manager).
    private var currentVoice: AcknowledgementCueRenderer.Voice?

    init(
        schedule: [AcknowledgementCueSchedule.Step] = AcknowledgementCueSchedule.default,
        renderer: AcknowledgementCueRenderer = AcknowledgementCueRenderer()
    ) {
        self.schedule = schedule
        self.renderer = renderer
    }

    /// Every phrase the arbiter can speak — the schedule's plus the research announcements.
    nonisolated static var allPhrases: [String] {
        AcknowledgementCueSchedule.allPhrases() + ResearchSpokenCue.allPhrases
    }

    func setVoice(_ voice: AcknowledgementCueRenderer.Voice) { currentVoice = voice }

    // MARK: - Push-to-talk turn

    /// Push-to-talk released: the instant acknowledgement now, later fillers on schedule.
    func beginTurn() {
        cancelTurn()
        turnHasEnded = false
        replyHasBegun = false
        hasSpokenAcknowledgementThisTurn = false
        for (stepIndex, step) in schedule.enumerated() {
            let isAcknowledgementStep = stepIndex == 0
            if step.delaySeconds == 0 {
                play(from: step.phrases)
                if isAcknowledgementStep { hasSpokenAcknowledgementThisTurn = true }
                continue
            }
            let delayNanoseconds = UInt64(step.delaySeconds * 1_000_000_000)
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled, let self else { return }
                if isAcknowledgementStep {
                    // The nod fires unless the reply already started talking.
                    guard !self.replyHasBegun else { return }
                } else {
                    guard AcknowledgementCueSchedule.shouldFire(
                        step: step, replyHasBegun: self.replyHasBegun, turnHasEnded: self.turnHasEnded
                    ) else { return }
                }
                self.play(from: step.phrases)
                if isAcknowledgementStep { self.hasSpokenAcknowledgementThisTurn = true }
            }
            if isAcknowledgementStep { acknowledgementTask = task } else { scheduledTasks.append(task) }
        }
    }

    /// The reply's first text arrived: audio is <1s away, so drop every pending filler.
    func replyBegan() {
        replyHasBegun = true
        cancelScheduledFillers()
    }

    /// The turn ended without a spoken reply (a routing directive, a voice answer to a
    /// research question, an error). The fillers are dropped; a not-yet-spoken
    /// acknowledgement still plays — the user gets one nod either way.
    func turnEnded() {
        turnHasEnded = true
        cancelScheduledFillers()
    }

    /// Hard stop of the turn's cues: a new press, an app-level stop.
    func cancelTurn() {
        turnHasEnded = true
        cancelScheduledFillers()
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        cuePlayer?.stop()
        cuePlayer = nil
    }

    // MARK: - Reply / recording gate

    /// The manager flips this as the voice state changes: while the reply is speaking or
    /// the user is recording, announcements wait; when it clears, they drain in order.
    func setReplyOrRecordingActive(_ active: Bool) {
        isReplyOrRecordingActive = active
        if !active { drainQueuedAnnouncements() }
    }

    /// True while a cue clip is playing.
    var isCuePlaying: Bool { cuePlayer?.isPlaying ?? false }

    /// Returns once no cue is playing (bounded, so a stuck player can never wedge a reply).
    func waitUntilNoCueIsPlaying() async {
        var waited: UInt64 = 0
        while isCuePlaying && waited < 2_000_000_000 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 50_000_000
        }
    }

    // MARK: - Announcements (research start / done / error)

    /// A research run is starting from this turn: ONE acknowledgement, not two. If the
    /// turn's "let me check" already played, the "on it…" line is skipped; if it hadn't fired yet
    /// (the router was quick), it's cancelled and the research line IS the acknowledgement.
    func announceResearchStart(_ phrase: String) {
        let alreadyAcknowledged = hasSpokenAcknowledgementThisTurn
        turnEnded()
        guard !alreadyAcknowledged else { return }
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        hasSpokenAcknowledgementThisTurn = true
        announce(phrase)
    }

    /// Speaks `phrase` now if nothing else is speaking, else after the reply/recording ends.
    func announce(_ phrase: String) {
        if isReplyOrRecordingActive || isCuePlaying {
            queuedAnnouncements.append(phrase)
            if isCuePlaying && !isReplyOrRecordingActive { scheduleDrainAfterCurrentCue() }
            return
        }
        play(phrase)
    }

    var queuedAnnouncementCountForTesting: Int { queuedAnnouncements.count }
    var hasSpokenAcknowledgementThisTurnForTesting: Bool { hasSpokenAcknowledgementThisTurn }
    /// Marks the turn's acknowledgement as spoken (as the scheduled step would).
    func markAcknowledgementSpokenForTesting() { hasSpokenAcknowledgementThisTurn = true }
    var scheduledFillerCountForTesting: Int { scheduledTasks.count + (acknowledgementTask == nil ? 0 : 1) }
    var isAcknowledgementPendingForTesting: Bool { acknowledgementTask != nil }

    // MARK: - Playback

    private func play(from phrases: [String]) {
        guard let phrase = phrases.randomElement() else { return }
        play(phrase)
    }

    private func play(_ phrase: String) {
        guard let currentVoice else { return }
        // Only a cached render plays; rendering at play time would itself be latency.
        guard let fileURL = renderer.cachedFileURL(phrase: phrase, voice: currentVoice),
              let player = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        cuePlayer?.stop()
        cuePlayer = player
        player.play()
    }

    private func drainQueuedAnnouncements() {
        guard !isReplyOrRecordingActive, !queuedAnnouncements.isEmpty else { return }
        if isCuePlaying { scheduleDrainAfterCurrentCue(); return }
        let next = queuedAnnouncements.removeFirst()
        play(next)
        if !queuedAnnouncements.isEmpty { scheduleDrainAfterCurrentCue() }
    }

    private func scheduleDrainAfterCurrentCue() {
        Task { [weak self] in
            await self?.waitUntilNoCueIsPlaying()
            self?.drainQueuedAnnouncements()
        }
    }

    private func cancelScheduledFillers() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }
}

/// The spoken research announcements, in place of the former Tink/Glass/Basso sounds.
enum ResearchSpokenCue {
    static func phrase(for cue: ResearchAudioCue) -> String {
        switch cue {
        case .acknowledge: return "sure. i'll put a page together for you."
        case .done: return "your page is ready."
        case .error: return "sorry, that one didn't work out."
        }
    }
    static var allPhrases: [String] { [ResearchAudioCue.acknowledge, .done, .error].map(phrase(for:)) }
}

/// `ResearchAudioCuePlayer` backed by the arbiter: every research cue is a spoken line in
/// the current voice, queued behind any reply so it never talks over one.
@MainActor
final class SpokenResearchAudioCuePlayer: ResearchAudioCuePlayer {
    private let arbiter: SpokenCueArbiter
    init(arbiter: SpokenCueArbiter) { self.arbiter = arbiter }
    func play(_ cue: ResearchAudioCue) {
        let phrase = ResearchSpokenCue.phrase(for: cue)
        if cue == .acknowledge {
            arbiter.announceResearchStart(phrase)
        } else {
            arbiter.announce(phrase)
        }
    }
}
