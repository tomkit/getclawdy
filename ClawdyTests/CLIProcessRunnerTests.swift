//
//  CLIProcessRunnerTests.swift
//  ClawdyTests
//
//  Hardening tests for the subprocess runner: it must time out (and kill) a
//  hung CLI, propagate task cancellation by terminating the child, and its
//  stream-parse states must be safe to mutate from concurrent background queues.
//

import Testing
import Foundation
@testable import Clawdy

struct CLIProcessRunnerTests {

    // MARK: - N1: timeout + cancellation

    @Test func runTimesOutAndTerminatesHangingProcess() async {
        let startTime = Date()
        do {
            _ = try await CLIProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                workingDirectoryPath: NSTemporaryDirectory(),
                environment: [:],
                standardInput: nil,
                timeoutSeconds: 1,
                onStandardOutputLine: { _ in }
            )
            Issue.record("expected a timeout error, but run returned normally")
        } catch let error as CLIProcessRunner.RunError {
            guard case .timedOut = error else {
                Issue.record("expected RunError.timedOut, got \(error)")
                return
            }
            // Should give up at ~1s, well before the process's natural 5s exit.
            #expect(Date().timeIntervalSince(startTime) < 4)
        } catch {
            Issue.record("expected RunError.timedOut, got \(error)")
        }
    }

    @Test func runThrowsCancellationWhenTaskCancelled() async {
        let runTask = Task { () throws -> CLIProcessRunner.Result in
            try await CLIProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                workingDirectoryPath: NSTemporaryDirectory(),
                environment: [:],
                standardInput: nil,
                timeoutSeconds: 30,
                onStandardOutputLine: { _ in }
            )
        }

        // Let the process actually start, then cancel.
        try? await Task.sleep(nanoseconds: 400_000_000)
        runTask.cancel()

        do {
            _ = try await runTask.value
            Issue.record("expected cancellation, but run returned normally")
        } catch is CancellationError {
            // success — the subprocess was terminated and cancellation surfaced.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func runCompletesNormallyWithinTimeout() async throws {
        let result = try await CLIProcessRunner.run(
            executablePath: "/bin/echo",
            arguments: ["hello-from-cli"],
            workingDirectoryPath: NSTemporaryDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 10,
            onStandardOutputLine: { _ in }
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("hello-from-cli"))
    }

    // MARK: - N2: thread-safe parse states

    @Test func codexStreamParseStateIsConcurrencySafe() {
        let state = CodexStreamParseState()
        let agentMessageLine = #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"hello"}}"#

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            _ = state.consume(line: agentMessageLine)
        }

        #expect(state.latestAgentMessageText == "hello")
    }

    // MARK: - B1: a fast-completing process leaves no live timeout watchdog

    @Test func fastProcessUnderShortTimeoutLeavesNoLiveTimer() async throws {
        // `true` exits immediately. Under a 1s timeout, the watchdog must be
        // cancelled at completion so it can't fire ~1s later against a finished
        // (or pid-reused) process. We wait past the timeout window and assert the
        // run completed normally and nothing crashed afterward.
        let result = try await CLIProcessRunner.run(
            executablePath: "/usr/bin/true",
            arguments: [],
            workingDirectoryPath: NSTemporaryDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 1,
            onStandardOutputLine: { _ in }
        )
        #expect(result.exitCode == 0)

        // Sleep past the would-be timeout. If a live watchdog terminated a
        // pid-reused process or the continuation double-resumed, this test would
        // crash. Surviving the wait is the assertion.
        try await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(result.exitCode == 0)
    }

    // MARK: - B1-residual: terminal reason is frozen at finish()

    @Test func finishFreezesReasonAgainstLateTimeoutAndCancel() {
        // A normal completion wins finish() first; a watchdog that wakes late or a
        // late cancellation must NOT flip the reported reason away from .normal.
        let coordinator = RunCoordinator(process: Process())

        let frozenReason = coordinator.finish()
        #expect(frozenReason == .normal)

        // These would previously mutate reasonStorage; now they're no-ops because
        // the run already finished. (No process was launched, so neither attempts
        // to terminate.)
        coordinator.timeoutDidFire()
        coordinator.cancelAndTerminate()

        // A second finish() never wins the claim, regardless of the late calls.
        #expect(coordinator.finish() == nil)
    }

    @Test func finishReportsCancellationWhenCancelWonFirst() {
        // If cancellation is recorded before completion, finish() must surface it.
        let coordinator = RunCoordinator(process: Process())
        coordinator.cancelAndTerminate()
        #expect(coordinator.finish() == .cancelled)
    }

    // MARK: - B2: cancellation at/before launch must not orphan a child

    @Test func cancellingBeforeLaunchThrowsCancellationAndSkipsLaunch() async {
        // The run is only reached AFTER the task is already cancelled (the
        // pre-`run` sleep is cancelled, then we still call run). The coordinator
        // must observe cancellation at the launch handshake and skip starting the
        // child entirely — so this returns promptly with CancellationError rather
        // than running /bin/sleep for 5 seconds.
        let startTime = Date()
        let runTask = Task { () throws -> CLIProcessRunner.Result in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return try await CLIProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                workingDirectoryPath: NSTemporaryDirectory(),
                environment: [:],
                standardInput: nil,
                timeoutSeconds: 30,
                onStandardOutputLine: { _ in }
            )
        }
        runTask.cancel()

        do {
            _ = try await runTask.value
            Issue.record("expected cancellation, but run returned normally")
        } catch is CancellationError {
            // success — launch was skipped; no 5s sleep child was started.
            #expect(Date().timeIntervalSince(startTime) < 3)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    // MARK: - B3: trailing output arriving at termination is fully drained

    @Test func trailingOutputAtTerminationIsFullyDrained() async throws {
        // The last line has no trailing newline and arrives right before exit.
        // The drain barrier + flushRemainder must guarantee it's parsed and
        // visible in both the streamed lines and the final aggregated output.
        let collectedLines = ConcurrentLineCollector()
        let result = try await CLIProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'alpha\\nbeta\\ngamma-no-newline'"],
            workingDirectoryPath: NSTemporaryDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 10,
            onStandardOutputLine: { collectedLines.append($0) }
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("gamma-no-newline"))

        let lines = collectedLines.snapshot()
        #expect(lines.contains("alpha"))
        #expect(lines.contains("beta"))
        #expect(lines.contains("gamma-no-newline"))
    }
}

/// Thread-safe collector for stdout lines emitted from the runner's background
/// reader thread.
private final class ConcurrentLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
