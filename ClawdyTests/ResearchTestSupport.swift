//
//  ResearchTestSupport.swift
//  ClawdyTests
//
//  Shared scaffolding for the research/session test suites. Consolidates two
//  pieces of boilerplate that were re-implemented across many files:
//    1. `SilentResearchAudioCuePlayer` — a no-op cue player so a manager's real
//       runs never actually play a system sound during tests. (The cue → transition
//       mapping is asserted separately in the audio suite; everywhere else we only
//       care that firing a cue never throws or blocks.)
//    2. `makeFakeExecutable(scriptBody:)` — writes a `#!/bin/sh` script to a fresh
//       unique temp dir, marks it executable, and returns its path. The per-test
//       script bodies legitimately differ (a hanging fake, a failing fake, a
//       two-phase success fake, …), so callers pass ONLY their body.
//

import Foundation
@testable import Clawdy

/// A silent cue player so a manager's real runs never actually play a system sound
/// during tests. (The cue → transition mapping is asserted separately in the audio
/// suite; here we only care that firing a cue never throws or blocks isolation.)
final class SilentResearchAudioCuePlayer: ResearchAudioCuePlayer {
    func play(_ cue: ResearchAudioCue) {}
}

enum ResearchTestSupport {
    /// Writes `scriptBody` as an executable `#!/bin/sh` script into a fresh, unique
    /// temp directory and returns the absolute path. Each call gets its own temp dir
    /// so concurrent tests never collide.
    static func makeFakeExecutable(scriptBody: String) throws -> String {
        let scriptDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdy-fake-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        let scriptURL = scriptDirectory.appendingPathComponent("fake.sh")
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }
}
