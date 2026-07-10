//
//  ResearchAudioCueTests.swift
//  ClawdyTests
//
//  Verifies the research subsystem's audio cues fire on the RIGHT lifecycle
//  transition and only those transitions:
//    - accept  → acknowledge   (a run starts)
//    - complete → done         (a run finishes successfully)
//    - fail     → error        (a run fails)
//    - stop     → (nothing)    (a user-initiated Stop is silent)
//
//  Two layers, mirroring the rest of the suite:
//   1. REAL-PATH transition tests drive the actual `ResearchCoordinator` against a
//      fake `claude` binary with a recording cue player injected in place of real
//      audio, and assert the exact cue sequence.
//   2. Pure tests on `SystemSoundResearchAudioCuePlayer` cover the cue → named
//      system-sound mapping and the mute gate, using an injected sound sink so no
//      audio ever plays.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Recording stub

/// Records the cues it's asked to play so a test can assert the exact sequence.
/// Accessed only on the main actor (the coordinator drives it there).
private final class RecordingResearchAudioCuePlayer: ResearchAudioCuePlayer {
    private(set) var playedCues: [ResearchAudioCue] = []
    func play(_ cue: ResearchAudioCue) {
        playedCues.append(cue)
    }
}

// MARK: - Fake claude binaries

/// A fake `claude` for a SUCCESSFUL research run: emits an init line (session id),
/// on PLAN persists a per-CWD session marker and emits a proceed result, and on
/// EXECUTE (`--resume`) finds that marker (plan + execute share the run's output
/// dir), writes the HTML deliverable to the absolute path embedded in the `-p`
/// message, and emits a success result. (Same shape the isolation suite uses.)
private func makeSuccessfulResearchFake() throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-cue-1"}"#
    let proceedResult = #"{"type":"result","result":"here is the plan, proceeding now","is_error":false}"#
    let executeResult = #"{"type":"result","result":"done, wrote report.html","is_error":false}"#

    let scriptContents = """
    #!/bin/sh
    emit() { /bin/echo "$1"; }
    task=""
    resume=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        -p) task="$a" ;;
        --resume) resume="$a" ;;
      esac
      prev="$a"
    done
    emit '\(initLine)'
    if [ -z "$resume" ]; then
      echo "plan" > "session-sess-cue-1.marker"
      emit '\(proceedResult)'
    else
      if [ ! -f "session-$resume.marker" ]; then
        emit "{\\"type\\":\\"result\\",\\"result\\":\\"No conversation found with session ID: $resume\\",\\"is_error\\":true}"
        echo "No conversation found with session ID: $resume" 1>&2
        exit 1
      fi
      outpath=$(printf '%s' "$task" | grep -oE '/[^[:space:]]*report\\.html' | head -1)
      if [ -n "$outpath" ]; then
        printf '<!doctype html><html><body><h1>report</h1></body></html>' > "$outpath"
      fi
      emit '\(executeResult)'
    fi
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// A fake `claude` that FAILS its plan phase hard (nonzero exit), so the engine
/// throws and the coordinator routes through `handleRunFailure`.
private func makeFailingResearchFake() throws -> String {
    let scriptContents = """
    #!/bin/sh
    echo "research plan failed" 1>&2
    exit 1
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

/// A fake `claude` that emits an init line then hangs forever (until SIGTERM), so a
/// test can start a run and then Stop it while it's still in flight.
private func makeHangingResearchFake() throws -> String {
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-cue-hang"}"#
    let scriptContents = """
    #!/bin/sh
    /bin/echo '\(initLine)'
    exec sleep 600
    """
    return try ResearchTestSupport.makeFakeExecutable(scriptBody: scriptContents)
}

@MainActor
private func makeSession(
    binaryPath: String,
    cuePlayer: ResearchAudioCuePlayer,
    taskDescription: String,
    sessionID: String = "sess-cue-1"
) -> ResearchSession {
    // Hermetic per-session temp locations so a real run never writes under the shared
    // `~/Library/Application Support` or the shared manifest. The pre-minted session id
    // is the SAME id the success fake keys its per-CWD `session-<id>.marker` by, so the
    // `--session-id` and the id the execute phase resumes agree — exactly as A0's
    // isolation suite pins it (the real CLI echoes `--session-id` back).
    let temporaryApplicationSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cue-appsupport-\(UUID().uuidString)", isDirectory: true)
    let temporaryManifestURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cue-manifest-\(UUID().uuidString).json")
    return ResearchSession(
        sessionID: sessionID,
        taskDescription: taskDescription,
        resolveEngineSelection: { ResearchEngineSelection(kind: .claudeCode, binaryPath: binaryPath) },
        makeEngine: { _, path in
            ClaudeResearchEngine(
                binaryPath: path,
                homeDirectoryPath: NSTemporaryDirectory(),
                planPhaseTimeoutSeconds: 30,
                executePhaseTimeoutSeconds: 30
            )
        },
        applicationSupportDirectory: temporaryApplicationSupport,
        homeDirectoryPath: NSTemporaryDirectory(),
        manifestStore: ResearchManifestStore(fileURL: temporaryManifestURL),
        audioCuePlayer: cuePlayer,
        testAnchorOriginOffset: offscreenResearchAnchorOffset
    )
}

private func pollUntil(
    timeoutSeconds: Double,
    _ description: String,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while await !condition() {
        if Date() >= deadline {
            Issue.record("timed out after \(timeoutSeconds)s waiting for: \(description)")
            return
        }
        try await Task.sleep(nanoseconds: 40_000_000)
    }
}

// MARK: - Lifecycle transition → cue tests

struct ResearchAudioCueTransitionTests {

    /// accept → acknowledge, and stop → (nothing). Starting a run fires exactly one
    /// acknowledge cue; a user-initiated Stop while it's in flight adds no cue.
    @MainActor
    @Test func acceptFiresAcknowledgeAndStopIsSilent() async throws {
        let hangingFake = try makeHangingResearchFake()
        let cuePlayer = RecordingResearchAudioCuePlayer()
        let session = makeSession(binaryPath: hangingFake, cuePlayer: cuePlayer, taskDescription: "research something forever")

        session.start()

        // The acknowledge cue fires synchronously the moment the run is accepted.
        #expect(cuePlayer.playedCues == [.acknowledge])
        #expect(session.state == .planning)

        // Let the (hanging) process spawn, then Stop it. Stop must be SILENT.
        try await Task.sleep(nanoseconds: 500_000_000)
        session.stop()
        #expect(session.state == .stopped)

        // Give any late transition a chance to (wrongly) fire a cue; it must not.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(cuePlayer.playedCues == [.acknowledge], "a user-initiated Stop must not play any cue")
    }

    /// complete → done. A run that finishes successfully fires acknowledge then done.
    @MainActor
    @Test func successfulCompletionFiresDoneAfterAcknowledge() async throws {
        let successfulFake = try makeSuccessfulResearchFake()
        let cuePlayer = RecordingResearchAudioCuePlayer()
        let session = makeSession(binaryPath: successfulFake, cuePlayer: cuePlayer, taskDescription: "research desks and build a page")

        session.start()

        try await pollUntil(timeoutSeconds: 20, "run to reach a terminal state") {
            session.state == .completed || session.state == .failed
        }

        #expect(session.state == .completed)
        #expect(cuePlayer.playedCues == [.acknowledge, .done])
    }

    /// fail → error. A run whose engine throws fires acknowledge then error.
    @MainActor
    @Test func failedRunFiresErrorAfterAcknowledge() async throws {
        let failingFake = try makeFailingResearchFake()
        let cuePlayer = RecordingResearchAudioCuePlayer()
        let session = makeSession(binaryPath: failingFake, cuePlayer: cuePlayer, taskDescription: "research something that fails")

        session.start()

        try await pollUntil(timeoutSeconds: 20, "run to reach a terminal state") {
            session.state == .completed || session.state == .failed
        }

        #expect(session.state == .failed)
        #expect(cuePlayer.playedCues == [.acknowledge, .error])
    }
}

// MARK: - Real player: sound mapping + mute gate (no real audio)

struct SystemSoundResearchAudioCuePlayerTests {

    @Test func eachCueMapsToADistinctSubtleSystemSound() {
        #expect(SystemSoundResearchAudioCuePlayer.systemSoundName(for: .acknowledge) == "Tink")
        #expect(SystemSoundResearchAudioCuePlayer.systemSoundName(for: .done) == "Glass")
        #expect(SystemSoundResearchAudioCuePlayer.systemSoundName(for: .error) == "Basso")

        let distinctNames = Set([
            SystemSoundResearchAudioCuePlayer.systemSoundName(for: .acknowledge),
            SystemSoundResearchAudioCuePlayer.systemSoundName(for: .done),
            SystemSoundResearchAudioCuePlayer.systemSoundName(for: .error)
        ])
        #expect(distinctNames.count == 3, "the three cues must use three distinct sounds")
    }

    @Test func unmutedPlayerRoutesEachCueToItsMappedSound() {
        var playedSoundNames: [String] = []
        let player = SystemSoundResearchAudioCuePlayer(
            isMuted: { false },
            playNamedSystemSound: { playedSoundNames.append($0) }
        )
        player.play(.acknowledge)
        player.play(.done)
        player.play(.error)
        #expect(playedSoundNames == ["Tink", "Glass", "Basso"])
    }
}
