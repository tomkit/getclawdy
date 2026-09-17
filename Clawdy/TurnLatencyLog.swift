//
//  TurnLatencyLog.swift
//  Clawdy
//
//  Per-turn latency instrumentation for the push-to-talk → answer pipeline, so the
//  delay a user FEELS can be attributed to a stage instead of guessed at. Every mark is
//  an `os.Logger` line at NOTICE level (info is not persisted, so `log show` would miss
//  it) in subsystem `com.clawdy.Clawdy`, category `latency`, with the
//  seconds since push-to-talk RELEASE, so a Finder-launched build is readable with:
//
//      log show --predicate 'subsystem == "com.clawdy.Clawdy" AND category == "latency"' --last 10m --style compact
//
//  Stages, in order: `ptt-released` → `transcript-ready` (says whether the recognizer's
//  final result arrived or the fallback timer fired) → `capture-ready` (screenshots
//  encoded; hoisted at press or captured now) → `request-sent` (NDJSON written) →
//  `first-text` (first streamed token) → `first-sentence` (first complete sentence handed
//  to TTS) → `tts-requested` (synthesis started) → `first-audio` (playback started) →
//  `result` (full reply). Plus `warm-spawn` whenever the warm
//  `claude` process is (re)started, with the reason, since a cold spawn on a turn is
//  the single biggest avoidable cost.
//

import Foundation
import os

@MainActor
final class TurnLatencyLog {
    static let logger = Logger(subsystem: "com.clawdy.Clawdy", category: "latency")
    /// The pointing walk, step by step (sequence start, each flight, landing, advance,
    /// return), so "it only moved once" can be read off the log:
    /// `log show --predicate 'subsystem == "com.clawdy.Clawdy" AND category == "pointing"' --last 10m`
    static let pointingLogger = Logger(subsystem: "com.clawdy.Clawdy", category: "pointing")

    private var turnStart: Date?
    private var hasLoggedFirstText = false
    private var hasLoggedFirstAudio = false
    private var hasLoggedFirstSentence = false
    private var hasLoggedTTSRequest = false

    /// Marks push-to-talk release as t=0 for this turn.
    func beginTurn() {
        turnStart = Date()
        hasLoggedFirstText = false
        hasLoggedFirstAudio = false
        hasLoggedFirstSentence = false
        hasLoggedTTSRequest = false
        Self.logger.notice("ptt-released t=0.00s")
    }

    func transcriptReady(viaFallback: Bool, characterCount: Int) {
        mark("transcript-ready", detail: "via=\(viaFallback ? "fallback-timer" : "final-result") chars=\(characterCount)")
    }

    func captureReady(imageCount: Int, totalBytes: Int, reused: Bool) {
        mark("capture-ready", detail: "images=\(imageCount) bytes=\(totalBytes) source=\(reused ? "hoisted-at-press" : "captured-now")")
    }

    /// The first complete sentence left the model and was handed to TTS.
    func firstSentence(characterCount: Int) {
        guard !hasLoggedFirstSentence else { return }
        hasLoggedFirstSentence = true
        mark("first-sentence", detail: "chars=\(characterCount)")
    }

    /// TTS synthesis was requested for the first clip (Apple: local; ElevenLabs: network).
    func ttsRequested(provider: String) {
        guard !hasLoggedTTSRequest else { return }
        hasLoggedTTSRequest = true
        mark("tts-requested", detail: "provider=\(provider)")
    }

    func requestSent(imageCount: Int, systemPromptCharacterCount: Int, historyExchangeCount: Int) {
        mark("request-sent", detail: "images=\(imageCount) systemPromptChars=\(systemPromptCharacterCount) history=\(historyExchangeCount)")
    }

    func firstText() {
        guard !hasLoggedFirstText else { return }
        hasLoggedFirstText = true
        mark("first-text")
    }

    func firstAudio() {
        guard !hasLoggedFirstAudio else { return }
        hasLoggedFirstAudio = true
        mark("first-audio")
    }

    func result(characterCount: Int, route: String) {
        mark("result", detail: "chars=\(characterCount) route=\(route)")
    }

    func failed(_ message: String) {
        mark("failed", detail: message)
    }

    /// Not tied to a turn's clock: the warm process was (re)spawned and why.
    nonisolated static func warmSpawn(reason: String, model: String, effort: String) {
        logger.notice("warm-spawn reason=\(reason, privacy: .public) model=\(model, privacy: .public) effort=\(effort, privacy: .public)")
    }

    private func mark(_ stage: String, detail: String = "") {
        let elapsed = turnStart.map { Date().timeIntervalSince($0) } ?? -1
        let elapsedText = String(format: "%.2f", elapsed)
        Self.logger.notice("\(stage, privacy: .public) t=\(elapsedText, privacy: .public)s \(detail, privacy: .public)")
    }
}
