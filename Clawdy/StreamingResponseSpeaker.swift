//
//  StreamingResponseSpeaker.swift
//  Clawdy
//
//  Speaks a response as it streams in, so audio starts on the FIRST completed
//  sentence instead of waiting for the whole reply. Sentences arrive one at a
//  time (already point-tag-stripped by SentenceStreamBuffer) and are played back
//  strictly in order through whichever TTS provider the user picked.
//
//  Provider behavior (the streaming choice differs per provider on purpose):
//   - Apple (AVSpeechSynthesizer): every sentence is spoken as soon as it
//     completes. Local synthesis is free and instant, so per-sentence playback
//     costs nothing and gives the snappiest, most natural cadence.
//   - ElevenLabs (network, per-request cost): the FIRST sentence is spoken
//     immediately for fast first-audio, then ALL remaining sentences are batched
//     into a SINGLE request sent when the response finishes. This caps the number
//     of network round-trips (and the per-request cost) at two while still
//     cutting the silent gap. If the first-sentence request fails in a
//     fallback-worthy way, every later chunk falls back to Apple.
//
//  Ordering is enforced by chaining each utterance's Task onto the previous one
//  and waiting for playback to actually finish before starting the next, so
//  utterances never overlap or cut each other off. Cancellation (the user
//  re-presses) stops playback on both providers and abandons the queue.
//

import Foundation

/// Reports ONE spoken ElevenLabs clip the moment its audio starts, so the manager can
/// schedule audio-synced cursor advances against THIS clip's own playhead.
///
/// TRAP 2 (per-clip timing): a response is spoken as SEPARATE clips — clip 0 is the first
/// sentence, clip 1 is the batched remainder — and each clip's alignment times are
/// relative to that clip's OWN zero, not a global timeline. The `clipOrdinal` + `clipText`
/// let the manager map each POINT to the word within the SAME clip's substring, and the
/// `timing.playheadSecondsReader` is that clip's own playhead. Apple clips are never
/// reported (they carry no alignment); only the timed ElevenLabs path reports.
struct SpokenClipReport {
    /// 0-based order the clip was spoken in: 0 = first sentence (or the whole reply when
    /// no sentence completed mid-stream), 1 = the batched remainder.
    let clipOrdinal: Int
    /// The exact text spoken in this clip — the substring of the full spoken text the
    /// manager maps POINT positions into.
    let clipText: String
    /// The clip's character-level timing + own playhead (may be nil alignment → degrade).
    let timing: SpokenClipTiming
}

@MainActor
final class StreamingResponseSpeaker {
    private let provider: TTSEngineKind
    /// The Apple TTS client, held as the protocol so a fake can be injected in tests (the
    /// speaker only ever calls `speakText`/`isPlaying`/`stopPlayback` on it). Production passes
    /// the concrete `LocalSpeechTTSClient`.
    private let appleTTSClient: SpeechTTSProviding
    private let elevenLabsTTSClient: ElevenLabsTTSClient
    /// Reads the ElevenLabs API secret ON-DEMAND. Invoked ONLY inside
    /// `speakOneUtterance` when this speaker is actually about to synthesize
    /// through ElevenLabs — never eagerly at construction. Under Apple TTS it is
    /// never called, so an Apple-TTS user's speak path never touches the Keychain
    /// (and never triggers the macOS Keychain-access prompt).
    private let elevenLabsAPIKeyProvider: () -> String?
    private let elevenLabsVoiceID: String
    /// Called once, the moment the very first audio starts playing, so the UI can
    /// flip out of the spinner/processing state.
    private let onPlaybackStarted: @MainActor () -> Void

    /// Called each time an ElevenLabs clip's audio STARTS, carrying that clip's timing so
    /// the manager can schedule audio-synced cursor advances against it. nil (default) for
    /// the non-pointing speak paths and for Apple TTS (which produces no alignment).
    private let onClipSpoken: (@MainActor (SpokenClipReport) -> Void)?

    /// How many ElevenLabs clips have been spoken so far, so each report carries the right
    /// `clipOrdinal` (0 = first sentence, 1 = batched remainder).
    private var elevenLabsClipsSpokenCount = 0

    /// Serializes utterances: each new utterance awaits the previous one's Task.
    private var pendingSpeechChain: Task<Void, Never> = Task {}
    /// Number of utterances queued-but-not-yet-finished. Drives `isSpeaking` so the
    /// transient-cursor fade never triggers in the brief gap between sentences.
    private var queuedUtteranceCount = 0
    private var hasStartedPlayback = false
    private var isCancelled = false

    // ElevenLabs batching state.
    private var elevenLabsFirstSentenceStarted = false
    private var elevenLabsBatchedRemainder = ""
    private var didFallBackToApple = false

    init(
        provider: TTSEngineKind,
        appleTTSClient: SpeechTTSProviding,
        elevenLabsTTSClient: ElevenLabsTTSClient,
        elevenLabsAPIKeyProvider: @escaping () -> String?,
        elevenLabsVoiceID: String,
        onPlaybackStarted: @escaping @MainActor () -> Void,
        onClipSpoken: (@MainActor (SpokenClipReport) -> Void)? = nil
    ) {
        self.provider = provider
        self.appleTTSClient = appleTTSClient
        self.elevenLabsTTSClient = elevenLabsTTSClient
        self.elevenLabsAPIKeyProvider = elevenLabsAPIKeyProvider
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.onPlaybackStarted = onPlaybackStarted
        self.onClipSpoken = onClipSpoken
    }

    /// True while any queued utterance is still pending or audio is playing.
    /// Includes the brief between-sentence gap so the overlay isn't faded early.
    var isSpeaking: Bool {
        if isCancelled { return false }
        return queuedUtteranceCount > 0 || appleTTSClient.isPlaying || elevenLabsTTSClient.isPlaying
    }

    /// Enqueues one freshly-completed sentence (point tag already stripped).
    func enqueueSentence(_ sentence: String) {
        guard !isCancelled else { return }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch provider {
        case .apple:
            appendUtterance(trimmed, preferElevenLabs: false)
        case .elevenLabs:
            if !elevenLabsFirstSentenceStarted {
                elevenLabsFirstSentenceStarted = true
                appendUtterance(trimmed, preferElevenLabs: true)
            } else {
                // Batch the rest into one request sent at finish().
                elevenLabsBatchedRemainder += elevenLabsBatchedRemainder.isEmpty ? trimmed : " " + trimmed
            }
        }
    }

    /// Called once the authoritative final text is known. `finalRemainder` is the
    /// still-unspoken tail (usually the last sentence, which has no trailing space
    /// to confirm it mid-stream). `fullSpokenText` is the entire point-tag-stripped
    /// reply, used only when not a single sentence completed mid-stream.
    func finish(finalRemainder: String?, fullSpokenText: String) {
        guard !isCancelled else { return }
        let trimmedRemainder = finalRemainder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedFull = fullSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch provider {
        case .apple:
            if !trimmedRemainder.isEmpty {
                appendUtterance(trimmedRemainder, preferElevenLabs: false)
            }
        case .elevenLabs:
            var remainder = elevenLabsBatchedRemainder
            if !trimmedRemainder.isEmpty {
                remainder += remainder.isEmpty ? trimmedRemainder : " " + trimmedRemainder
            }
            if !elevenLabsFirstSentenceStarted {
                // No sentence ever completed mid-stream — speak the whole reply once.
                if !trimmedFull.isEmpty {
                    appendUtterance(trimmedFull, preferElevenLabs: true)
                }
            } else if !remainder.isEmpty {
                appendUtterance(remainder, preferElevenLabs: true)
            }
        }
    }

    /// Awaits the current speech chain draining — i.e. every queued utterance finishing (or
    /// being cancelled/failing). Returns immediately when nothing is (or ever was) queued, so
    /// it also settles the no-op / suppressed-TTS case. Used by callers that must restore panel
    /// state (e.g. `voiceState = .idle`) ONLY after the utterance has actually finished playing.
    func awaitAllPlaybackFinished() async {
        await pendingSpeechChain.value
    }

    /// Stops playback on both providers and abandons the queue. Idempotent.
    func cancel() {
        isCancelled = true
        pendingSpeechChain.cancel()
        appleTTSClient.stopPlayback()
        elevenLabsTTSClient.stopPlayback()
        queuedUtteranceCount = 0
    }

    // MARK: - Private

    private func appendUtterance(_ text: String, preferElevenLabs: Bool) {
        queuedUtteranceCount += 1
        let previousChain = pendingSpeechChain
        pendingSpeechChain = Task { [weak self] in
            await previousChain.value
            guard let self else { return }
            if !self.isCancelled && !Task.isCancelled {
                await self.speakOneUtterance(text, preferElevenLabs: preferElevenLabs && !self.didFallBackToApple)
            }
            self.queuedUtteranceCount = max(0, self.queuedUtteranceCount - 1)
        }
    }

    private func speakOneUtterance(_ text: String, preferElevenLabs: Bool) async {
        if preferElevenLabs {
            // ON-DEMAND secret read: only reached when ElevenLabs is the active
            // provider AND we're about to synthesize this utterance.
            elevenLabsTTSClient.apiKey = elevenLabsAPIKeyProvider()
            elevenLabsTTSClient.voiceID = elevenLabsVoiceID
            do {
                // Speak through the with-timestamps path so we get this clip's character
                // alignment + playhead. TRAP 2: report it tagged with THIS clip's ordinal
                // and text, so the manager syncs each POINT to the word within the SAME
                // clip's own (zero-based) timeline — never a global one.
                let clipTiming = try await elevenLabsTTSClient.speakTextReportingTiming(text)
                markPlaybackStartedIfNeeded()
                let clipOrdinal = elevenLabsClipsSpokenCount
                elevenLabsClipsSpokenCount += 1
                onClipSpoken?(SpokenClipReport(clipOrdinal: clipOrdinal, clipText: text, timing: clipTiming))
                await waitForPlaybackToFinish(isPlaying: { [weak self] in self?.elevenLabsTTSClient.isPlaying ?? false })
                return
            } catch {
                // Cancellation must NOT fall back (the user spoke again).
                guard TTSProviderSelection.shouldFallBackToApple(for: error) else { return }
                didFallBackToApple = true
                print("⚠️ ElevenLabs streaming TTS failed, falling back to Apple: \(error)")
                // Fall through and speak this same chunk via Apple.
            }
        }

        do {
            try await appleTTSClient.speakText(text)
            markPlaybackStartedIfNeeded()
            await waitForPlaybackToFinish(isPlaying: { [weak self] in self?.appleTTSClient.isPlaying ?? false })
        } catch {
            print("⚠️ Apple streaming TTS error: \(error)")
        }
    }

    private func markPlaybackStartedIfNeeded() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        onPlaybackStarted()
    }

    /// Polls until the given provider stops playing (or we're cancelled), so the
    /// next utterance doesn't start until this one's audio has finished. Bounded
    /// so a stuck delegate callback can never wedge the queue forever.
    private func waitForPlaybackToFinish(isPlaying: @escaping () -> Bool) async {
        let pollIntervalNanoseconds: UInt64 = 50_000_000 // 50ms
        let maximumPolls = 1_200 // ~60s safety ceiling
        var pollsRemaining = maximumPolls
        while isPlaying() && pollsRemaining > 0 {
            if isCancelled || Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            pollsRemaining -= 1
        }
    }
}
