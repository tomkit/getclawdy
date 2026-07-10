//
//  TestEnvironment.swift
//  Clawdy
//
//  A single, reusable detector for "are we running under XCTest right now".
//
//  The unit-test bundle uses the real Clawdy app as its TEST HOST, so the app's
//  normal launch path (`CompanionAppDelegate.applicationDidFinishLaunching` →
//  `CompanionManager.start()`) runs on EVERY `xcodebuild test` invocation. That
//  launch path includes the PROACTIVE screen-recording registration, whose real
//  side effect is an interactive `SCShareableContent` enumeration/capture — which
//  pops the macOS "Clawdy would like to record this computer's screen" TCC prompt.
//  Under the test host that prompt fires on every run.
//
//  This helper lets the launch path SKIP only that real system-prompting side
//  effect under tests. It never changes production behavior (outside tests the
//  detector is false, so the proactive registration fires exactly as before), and
//  it never gates the SILENT status reads (`CGPreflightScreenCaptureAccess()`),
//  which stay live so tests can still read permission status.
//

import Foundation

enum TestEnvironment {
    /// Launch argument tests (or a debugging developer) can pass to force the
    /// screen-recording side-effect suppression on, independent of the XCTest
    /// environment variable.
    static let disableScreenRecordingSideEffectsLaunchArgument = "-clawdyDisableScreenRecordingSideEffects"

    /// True when the current process is hosted by XCTest. XCTest sets
    /// `XCTestConfigurationFilePath` in the environment of the test-host process,
    /// so this is the robust, framework-provided signal. A launch argument is
    /// also honored as a belt-and-suspenders manual override.
    static var isRunningUnderTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(disableScreenRecordingSideEffectsLaunchArgument) {
            return true
        }
        return false
    }
}
