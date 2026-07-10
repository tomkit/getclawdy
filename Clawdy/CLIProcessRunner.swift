//
//  CLIProcessRunner.swift
//  Clawdy
//
//  Thin async wrapper around Foundation's Process for running a CLI engine
//  binary, feeding it a prompt on stdin, and reading its stdout line-by-line so
//  callers can stream output as it arrives. Captures stderr and the exit code so
//  failures can be surfaced to the UI as thrown errors.
//

import Foundation

enum CLIProcessRunner {
    struct Result {
        let standardOutput: String
        let standardError: String
        let exitCode: Int32
    }

    enum RunError: LocalizedError {
        case launchFailed(underlying: Error)
        case nonZeroExit(exitCode: Int32, standardError: String)
        case timedOut(seconds: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let underlying):
                return "Couldn't launch the CLI: \(underlying.localizedDescription)"
            case .nonZeroExit(let exitCode, let standardError):
                let trimmedError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedError.isEmpty {
                    return "The CLI exited with status \(exitCode)."
                }
                return "The CLI exited with status \(exitCode): \(trimmedError)"
            case .timedOut(let seconds):
                return "The CLI didn't respond within \(Int(seconds)) seconds and was stopped."
            }
        }
    }

    /// Ignore SIGPIPE process-wide exactly once. Without this, writing the prompt
    /// to a CLI that has already closed its stdin read-end (e.g. it exited
    /// immediately because it isn't signed in) delivers SIGPIPE and crashes the
    /// whole app. With it ignored, the write instead fails with an EPIPE error we
    /// can catch and treat as a normal engine failure.
    private static let ignoreSIGPIPESignalOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Builds an environment dictionary for a child CLI process. A Finder-launched
    /// app has a minimal PATH, which breaks CLIs that shell out to node/git/etc.
    /// We prepend the common install directories to PATH so the CLI's own child
    /// processes resolve, and ensure HOME is set so the CLI finds its config and
    /// stored auth credentials.
    static func makeChildEnvironment(homeDirectoryPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let existingPath = environment["PATH"] ?? ""
        let supplementalPathDirectories = [
            "\(homeDirectoryPath)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let combinedPath = (supplementalPathDirectories + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { accumulator, directory in
                if !accumulator.contains(directory) {
                    accumulator.append(directory)
                }
            }
            .joined(separator: ":")
        environment["PATH"] = combinedPath
        environment["HOME"] = homeDirectoryPath

        return environment
    }

    /// Runs `executablePath` with `arguments`, writing `standardInput` (if any)
    /// to the process's stdin. `onStandardOutputLine` is called for every
    /// complete line of stdout as it arrives (on a background reader thread).
    ///
    /// Returns once the process has exited AND both output pipes have been fully
    /// drained to EOF. Throws `RunError.launchFailed` if the binary can't start,
    /// `RunError.timedOut` if it doesn't finish within `timeoutSeconds`, and
    /// `CancellationError` if the awaiting Task is cancelled (e.g. the user
    /// re-presses push-to-talk). In the timeout and cancellation cases the child
    /// process is terminated so it can't be orphaned. Non-zero exits are returned
    /// in the `Result` so callers can decide how to surface them.
    ///
    /// Concurrency model: rather than `readabilityHandler` + `terminationHandler`
    /// (which race — a late readability callback can run after the termination
    /// drain), each pipe is drained by a dedicated blocking reader that loops on
    /// `availableData` until EOF. EOF happens only after the process closes its
    /// write ends (i.e. at/after exit), so when BOTH readers finish, every byte
    /// of output has been parsed. A `DispatchGroup` joins the two readers and
    /// provides the happens-before barrier guaranteeing the engine's post-await
    /// read observes every parsed line.
    static func run(
        executablePath: String,
        arguments: [String],
        workingDirectoryPath: String,
        environment: [String: String],
        standardInput: String?,
        timeoutSeconds: TimeInterval = 60,
        onStandardOutputLine: @escaping (String) -> Void
    ) async throws -> Result {
        // Make sure a CLI that closes stdin early can't crash us with SIGPIPE.
        _ = Self.ignoreSIGPIPESignalOnce

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath)
        process.environment = environment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardInputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.standardInput = standardInputPipe

        let outputAccumulator = LineAccumulator(onCompleteLine: onStandardOutputLine)
        let errorAccumulator = LineAccumulator(onCompleteLine: { _ in })

        // Single lock-guarded coordinator for the launch / cancel / timeout /
        // resume state machine.
        let coordinator = RunCoordinator(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                // Atomically decide whether to launch: if cancellation was already
                // observed, skip the launch entirely so we never start a child that
                // nothing terminates.
                switch coordinator.launchIfNotCancelled({ try process.run() }) {
                case .skippedDueToCancellation:
                    if coordinator.finish() != nil {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                case .failed(let launchError):
                    if coordinator.finish() != nil {
                        continuation.resume(throwing: RunError.launchFailed(underlying: launchError))
                    }
                    return
                case .launched:
                    break
                }

                // Drain each pipe on its own background thread until EOF. Because a
                // single thread owns each stream, line emission for stdout is
                // strictly ordered, and the trailing (newline-less) line is flushed
                // before the thread leaves the group.
                let readerGroup = DispatchGroup()
                func drainToEndOfFile(_ fileHandle: FileHandle, into accumulator: LineAccumulator) {
                    readerGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        while true {
                            let data = fileHandle.availableData
                            if data.isEmpty { break } // EOF
                            accumulator.append(data)
                        }
                        accumulator.flushRemainder()
                        readerGroup.leave()
                    }
                }
                drainToEndOfFile(standardOutputPipe.fileHandleForReading, into: outputAccumulator)
                drainToEndOfFile(standardErrorPipe.fileHandleForReading, into: errorAccumulator)

                // Feed the prompt on stdin, then close it so the CLI knows input
                // ended. Use the throwing write so a broken pipe (CLI already closed
                // its stdin read-end) surfaces as a caught error instead of
                // crashing; the failure then shows up via the CLI's exit code.
                if let standardInput, let inputData = standardInput.data(using: .utf8) {
                    do {
                        try standardInputPipe.fileHandleForWriting.write(contentsOf: inputData)
                    } catch {
                        print("⚠️ CLIProcessRunner: failed to write prompt to stdin: \(error)")
                    }
                }
                try? standardInputPipe.fileHandleForWriting.close()

                // Arm the timeout. armTimeout is a no-op if the run already
                // finished, so a fast process can't leave a live watchdog.
                coordinator.armTimeout(seconds: timeoutSeconds)

                // Both pipes at EOF ⇒ the process has closed its outputs. Reap it,
                // then resume exactly once. The group barrier guarantees all
                // appends/flushes are visible here.
                readerGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    process.waitUntilExit()
                    // finish() atomically freezes and returns the terminal reason,
                    // so a watchdog/cancel that wakes after this point can't flip a
                    // completed-normal run to timedOut/cancelled.
                    guard let frozenReason = coordinator.finish() else { return }
                    switch frozenReason {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timedOut:
                        continuation.resume(throwing: RunError.timedOut(seconds: timeoutSeconds))
                    case .normal:
                        continuation.resume(returning: Result(
                            standardOutput: outputAccumulator.fullText,
                            standardError: errorAccumulator.fullText,
                            exitCode: process.terminationStatus
                        ))
                    }
                }
            }
        } onCancel: {
            // The awaiting Task was cancelled (e.g. user re-pressed push-to-talk).
            // Terminate the child if it's running; reaching EOF then drives the
            // notify block, which resumes with CancellationError.
            coordinator.cancelAndTerminate()
        }
    }
}

/// Single lock-guarded state machine for one `CLIProcessRunner.run`. Serializes
/// the launch / cancel / timeout / resume transitions so the continuation resumes
/// exactly once, the child is never orphaned, never terminated after the run has
/// completed, and — crucially — the terminal reason is frozen at completion so a
/// late watchdog/cancel can't change what outcome the run reports.
///
/// `internal` (not `private`) so the state machine can be unit-tested directly.
final class RunCoordinator: @unchecked Sendable {
    enum Reason: Equatable {
        case normal
        case cancelled
        case timedOut
    }

    enum LaunchOutcome {
        case launched
        case skippedDueToCancellation
        case failed(Error)
    }

    private let lock = NSLock()
    private let process: Process
    private var reasonStorage: Reason = .normal
    private var isCancelled = false
    private var isLaunched = false
    private var isFinished = false
    private var hasResumed = false
    private var watchdogTask: Task<Void, Never>?

    init(process: Process) {
        self.process = process
    }

    /// Atomically launches the process unless cancellation was already observed.
    /// The launch runs under the lock so it can't interleave with
    /// `cancelAndTerminate` — exactly one of {launch-then-terminate, skip-launch}
    /// happens.
    func launchIfNotCancelled(_ launch: () throws -> Void) -> LaunchOutcome {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { return .skippedDueToCancellation }
        do {
            try launch()
            isLaunched = true
            return .launched
        } catch {
            return .failed(error)
        }
    }

    /// Cancellation observed. Does nothing once the run has finished (the reason is
    /// frozen). Otherwise records the reason and terminates the child if it's
    /// already running; if it hasn't launched yet, the flag makes the launch skip.
    func cancelAndTerminate() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        if reasonStorage == .normal { reasonStorage = .cancelled }
        isCancelled = true
        let shouldTerminate = isLaunched
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    /// The timeout watchdog fired. Does nothing once the run has finished, so a
    /// completed-normal run can never be flipped to `.timedOut` (B1-residual).
    func timeoutDidFire() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        if reasonStorage == .normal { reasonStorage = .timedOut }
        let shouldTerminate = isLaunched
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    /// Arms the timeout watchdog, but only if the run hasn't already finished or
    /// been cancelled — so a process that completes before this call can't leave a
    /// live timer behind (B1).
    func armTimeout(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, !isCancelled else { return }
        watchdogTask = Task { [weak self] in
            let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            self?.timeoutDidFire()
        }
    }

    /// Claims the single resume, marks the run finished, cancels the watchdog, and
    /// atomically captures + returns the now-frozen terminal reason. Returns nil
    /// for any caller that didn't win the claim. Because this freezes `isFinished`
    /// and reads `reasonStorage` under the same lock acquisition, no later
    /// `cancelAndTerminate`/`timeoutDidFire` can change the reported reason.
    func finish() -> Reason? {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return nil
        }
        hasResumed = true
        isFinished = true
        let frozenReason = reasonStorage
        let watchdogToCancel = watchdogTask
        watchdogTask = nil
        lock.unlock()
        watchdogToCancel?.cancel()
        return frozenReason
    }
}

/// Incrementally decodes a raw byte stream as UTF-8 ACROSS chunk boundaries. A
/// single multibyte codepoint (emoji, CJK, '…' = E2 80 A6, '—') can straddle two
/// pipe reads; decoding each `Data` chunk independently as UTF-8 would fail and
/// DROP the whole chunk when that happens. This keeps a rolling byte buffer,
/// decodes as much valid UTF-8 as it can on each call, and RETAINS any trailing
/// bytes that form an incomplete codepoint so they complete on (are prepended to)
/// the next chunk. Nothing decodable is ever lost.
///
/// Not thread-safe on its own — each caller either owns one decoder per single
/// reader thread or guards it with the same lock that guards its other state.
/// `internal` (not `private`) so the boundary-decode is unit-testable directly.
struct UTF8StreamDecoder {
    /// Bytes carried over from previous reads because they form an incomplete
    /// trailing codepoint (or, transiently, precede one).
    private var pendingBytes = Data()

    /// The maximum number of trailing bytes that can legitimately be an INCOMPLETE
    /// UTF-8 codepoint: a 4-byte codepoint missing its final byte leaves 3 held.
    private static let maxIncompleteTrailingByteCount = 3

    /// Appends `data` to the rolling buffer and returns the longest run of newly
    /// decodable UTF-8 text, holding back any trailing incomplete-codepoint bytes
    /// for the next call. Returns "" when the whole (small) buffer is still just an
    /// incomplete codepoint awaiting more bytes.
    mutating func decode(_ data: Data) -> String {
        pendingBytes.append(data)

        // Fast path: the entire buffer is already valid UTF-8.
        if let wholeBuffer = String(data: pendingBytes, encoding: .utf8) {
            pendingBytes.removeAll(keepingCapacity: true)
            return wholeBuffer
        }

        // The buffer doesn't decode as a whole. If the ONLY problem is a short
        // incomplete codepoint at the very end, trimming 1…3 trailing bytes will
        // reveal a valid prefix — decode that and hold the trimmed tail for next time.
        let maxTrailingBytesToTry = min(Self.maxIncompleteTrailingByteCount, pendingBytes.count)
        if maxTrailingBytesToTry >= 1 {
            for trailingByteCount in 1...maxTrailingBytesToTry {
                let prefixEndIndex = pendingBytes.count - trailingByteCount
                let prefixBytes = Data(pendingBytes.prefix(prefixEndIndex))
                if let decodedPrefix = String(data: prefixBytes, encoding: .utf8) {
                    pendingBytes = Data(pendingBytes.suffix(trailingByteCount))
                    return decodedPrefix
                }
            }
        }

        // The invalid bytes are NOT merely a short trailing incomplete sequence —
        // this is genuine corruption. Decode lossily (invalid bytes become U+FFFD)
        // so the buffer can't grow without bound, retaining nothing.
        let lossilyDecoded = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: true)
        return lossilyDecoded
    }

    /// Flushes any bytes still buffered at EOF, decoding them lossily (a genuinely
    /// incomplete trailing codepoint becomes a replacement char). Returns "" when
    /// the buffer is empty.
    mutating func flush() -> String {
        guard !pendingBytes.isEmpty else { return "" }
        let trailingText = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: true)
        return trailingText
    }
}

/// Accumulates incoming Data into the full text and emits complete (newline
/// terminated) lines to a callback. Thread-safe via an internal lock: `append`
/// runs on a background reader thread while `fullText` is read after the run's
/// drain barrier. `internal` (not `private`) so the boundary-decode behavior is
/// unit-testable directly.
final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    /// Decodes raw bytes as UTF-8 across read boundaries so a multibyte codepoint
    /// split between two `availableData` chunks is never dropped.
    private var utf8StreamDecoder = UTF8StreamDecoder()
    private var pendingLineBuffer = ""
    private var accumulatedText = ""
    private let onCompleteLine: (String) -> Void
    /// When false, the full running text is NOT retained (only the small pending
    /// partial line is buffered). Callers that only consume complete lines and
    /// never read `fullText` — e.g. the app-lifetime warm `ClaudePersistentSession`
    /// reader, where retaining every stdout byte forever would grow unbounded —
    /// pass false. Defaults to true so existing callers are byte-for-byte unchanged.
    private let accumulatesFullText: Bool

    init(accumulatesFullText: Bool = true, onCompleteLine: @escaping (String) -> Void) {
        self.accumulatesFullText = accumulatesFullText
        self.onCompleteLine = onCompleteLine
    }

    func append(_ data: Data) {
        lock.lock()
        // Decode across the read boundary rather than per-chunk, so a codepoint
        // straddling two reads isn't discarded.
        let text = utf8StreamDecoder.decode(data)
        guard !text.isEmpty else {
            lock.unlock()
            return
        }
        if accumulatesFullText { accumulatedText += text }
        pendingLineBuffer += text

        // Split off every complete (newline-terminated) line, keeping any
        // trailing partial line in the buffer until the next chunk arrives.
        var completedLines: [String] = []
        let segments = pendingLineBuffer.components(separatedBy: "\n")
        if segments.count > 1 {
            completedLines = Array(segments.dropLast())
            pendingLineBuffer = segments.last ?? ""
        }
        lock.unlock()

        for line in completedLines {
            onCompleteLine(line)
        }
    }

    /// Emits any trailing text that wasn't newline-terminated.
    func flushRemainder() {
        lock.lock()
        // Flush any bytes the decoder was still holding (a codepoint that completed
        // on the final read) so no trailing multibyte character is lost at EOF.
        let decoderTail = utf8StreamDecoder.flush()
        if !decoderTail.isEmpty {
            if accumulatesFullText { accumulatedText += decoderTail }
            pendingLineBuffer += decoderTail
        }
        let remainder = pendingLineBuffer
        pendingLineBuffer = ""
        lock.unlock()
        if !remainder.isEmpty {
            onCompleteLine(remainder)
        }
    }

    var fullText: String {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedText
    }
}
