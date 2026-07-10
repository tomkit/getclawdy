//
//  ThinkingCueTests.swift
//  ClawdyTests
//
//  Headless tests for the pure show/hide timing logic behind the visual
//  "thinking" cue (ThinkingCueState). These assert the cue appears only after
//  the threshold elapses with a still-in-flight request and nothing heard/seen
//  yet, and hides the instant audio/answer starts or the request ends — and that
//  the logic never implies a timeout or retry (it only ever decides visibility).
//

import Testing
import Foundation
@testable import Clawdy

struct ThinkingCueTests {

    private var threshold: TimeInterval { ThinkingCueState.appearanceDelaySeconds }

    // MARK: - Appears only after the threshold

    @Test func doesNotShowBeforeThresholdElapses() {
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: threshold - 0.1
        )
        #expect(shouldShow == false)
    }

    @Test func showsExactlyAtThreshold() {
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: threshold
        )
        #expect(shouldShow == true)
    }

    @Test func showsAfterThreshold() {
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: threshold + 5
        )
        #expect(shouldShow == true)
    }

    // MARK: - Hides the instant audio/answer starts

    @Test func neverShowsOnceAnswerOrAudioStarted() {
        // Even far past the threshold, if audio/answer has begun the cue is hidden.
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: true,
            elapsedSeconds: threshold + 30
        )
        #expect(shouldShow == false)
    }

    // MARK: - Hides the instant the request ends

    @Test func neverShowsOnceRequestEnded() {
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: false,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: threshold + 30
        )
        #expect(shouldShow == false)
    }

    @Test func endedAndStartedBothSuppressTheCue() {
        let shouldShow = ThinkingCueState.shouldShowCue(
            isRequestInFlight: false,
            hasAnswerOrAudioStarted: true,
            elapsedSeconds: threshold + 30
        )
        #expect(shouldShow == false)
    }

    // MARK: - Threshold constant

    @Test func appearanceDelayIsTenSeconds() {
        #expect(ThinkingCueState.appearanceDelaySeconds == 10)
    }

    @Test func customThresholdIsHonored() {
        // The threshold is a parameter so callers/tests can override it.
        #expect(ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: 3,
            appearanceDelaySeconds: 2
        ) == true)
        #expect(ThinkingCueState.shouldShowCue(
            isRequestInFlight: true,
            hasAnswerOrAudioStarted: false,
            elapsedSeconds: 1,
            appearanceDelaySeconds: 2
        ) == false)
    }
}
