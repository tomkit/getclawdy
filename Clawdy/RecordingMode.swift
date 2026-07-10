//
//  RecordingMode.swift
//  Clawdy
//
//  Central mapping for the user-facing "Show Clawdy in screen recordings" toggle
//  (a.k.a. Recording Mode). When ON, Clawdy's on-screen overlays — the claw
//  shadow cursor, the annotation strokes, and the research toasts / badge /
//  detail / HUD — become VISIBLE to external screen recorders (QuickTime / OBS /
//  ScreenCaptureKit) for demos. When OFF (the historical default), those overlays
//  stay invisible to capture.
//
//  CRITICAL INVARIANT: this flips ONLY the overlay windows' `sharingType`. It
//  NEVER affects the model screenshots Clawdy captures for its OWN vision — those
//  exclude every Clawdy window at the APPLICATION level regardless of this setting
//  (see `CompanionScreenCaptureUtility`). So annotation strokes still appear
//  exactly once (burned in by the software `AnnotationImageCompositor`) and the
//  model's view of the screen is byte-for-byte identical in both modes.
//

import AppKit

enum RecordingMode {
    /// The `sharingType` an overlay window should adopt for the given setting
    /// value. `.readOnly` lets external screen recorders capture the window's
    /// pixels; `.none` hides it from every ScreenCaptureKit consumer (the default).
    static func overlaySharingType(recordingEnabled: Bool) -> NSWindow.SharingType {
        recordingEnabled ? .readOnly : .none
    }
}
