//
//  RecordingModeTests.swift
//  ClawdyTests
//
//  Pins the pure `RecordingMode.overlaySharingType` mapping that drives the
//  "Show Clawdy in screen recordings" toggle: ON → `.readOnly` (visible to
//  external recorders), OFF → `.none` (hidden from capture, the default).
//

import Testing
import AppKit
@testable import Clawdy

@MainActor
struct RecordingModeTests {

    /// Recording Mode ON → the overlay windows become `.readOnly`, so external
    /// screen recorders (QuickTime/OBS/ScreenCaptureKit) can capture their pixels.
    @Test func enabledMapsToReadOnly() {
        #expect(RecordingMode.overlaySharingType(recordingEnabled: true) == .readOnly)
    }

    /// Recording Mode OFF (the default) → `.none`, so the overlays stay invisible
    /// to every ScreenCaptureKit consumer, exactly as today.
    @Test func disabledMapsToNone() {
        #expect(RecordingMode.overlaySharingType(recordingEnabled: false) == .none)
    }

    /// Toggling ON then OFF fully reverts to the hidden state — the mapping is a
    /// pure function of the flag, so there's no residual state to leak.
    @Test func togglingBackOffFullyReverts() {
        let on = RecordingMode.overlaySharingType(recordingEnabled: true)
        let backOff = RecordingMode.overlaySharingType(recordingEnabled: false)
        #expect(on == .readOnly)
        #expect(backOff == .none)
        #expect(backOff != on)
    }
}
