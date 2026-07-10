//
//  CLIBinaryResolver.swift
//  Clawdy
//
//  Resolves the absolute path to a CLI binary (`claude` / `codex`). A GUI app
//  launched from Finder inherits a minimal PATH (often just /usr/bin:/bin), so
//  binaries installed by any of the many Node/CLI managers under the user's home
//  are invisible unless we look for them explicitly. To cover "installed however
//  the user installed it", resolution happens in three tiers:
//    1. The current PATH, then a broad set of well-known install locations
//       (homebrew, plain npm-global, custom npm prefixes ~/.npm-global &
//       ~/.npm-packages, pnpm, yarn, Volta, asdf shims, n, bun), plus every
//       versioned bin directory under nvm, asdf node installs, and fnm.
//    2. If that still misses, a LOGIN-SHELL PATH PROBE: we run the user's own
//       login shell (`$SHELL -l -c 'command -v <binary> || echo $PATH'`) so we
//       inherit the exact PATH their terminal has — the only reliable way to find
//       a binary a manager injected purely via a shell profile. It costs
//       ~100-300ms, so it runs ONLY after the fast path above fails.
//  The pure logic (directory assembly, output parsing) is split into small pure
//  functions with all filesystem/Process access injected, so it can be
//  unit-tested without touching the real filesystem or spawning a shell.
//

import Foundation

enum CLIBinaryResolver {
    /// Finds `binaryName` by checking each directory in `searchDirectories` in
    /// order and returning the first one that contains an executable file with
    /// that name. Pure — all filesystem access is injected via `isExecutableFile`
    /// so this is fully unit-testable.
    static func resolveBinaryPath(
        binaryName: String,
        searchDirectories: [String],
        isExecutableFile: (String) -> Bool
    ) -> String? {
        for directory in searchDirectories {
            let trimmedDirectory = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmedDirectory.isEmpty else { continue }
            let candidatePath = (trimmedDirectory as NSString).appendingPathComponent(binaryName)
            if isExecutableFile(candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    /// Assembles the ordered list of directories to search for a CLI binary:
    /// every entry in the current PATH, followed by the common install locations
    /// a GUI app's minimal PATH usually misses (~/.local/bin, homebrew, /usr/local,
    /// the various npm/pnpm/yarn/Volta/asdf/n prefixes), and finally every versioned
    /// bin directory under nvm, asdf node installs, and fnm. PATH entries come first
    /// so an explicitly configured location wins. Pure — every directory listing is
    /// injected; the asdf/fnm/nvm listers default to empty so existing pure callers
    /// (and tests) that only care about nvm keep working unchanged.
    static func candidateSearchDirectories(
        pathEnvironmentValue: String?,
        homeDirectoryPath: String,
        nvmNodeVersionDirectoryLister: (String) -> [String],
        asdfNodeVersionDirectoryLister: (String) -> [String] = { _ in [] },
        fnmShellDirectoryLister: (String) -> [String] = { _ in [] }
    ) -> [String] {
        var orderedDirectories: [String] = []
        var alreadyIncludedDirectories = Set<String>()

        func appendDirectoryIfNew(_ directory: String) {
            let trimmedDirectory = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmedDirectory.isEmpty else { return }
            guard !alreadyIncludedDirectories.contains(trimmedDirectory) else { return }
            alreadyIncludedDirectories.insert(trimmedDirectory)
            orderedDirectories.append(trimmedDirectory)
        }

        // 1. Everything already on PATH.
        if let pathEnvironmentValue {
            for pathEntry in pathEnvironmentValue.split(separator: ":", omittingEmptySubsequences: true) {
                appendDirectoryIfNew(String(pathEntry))
            }
        }

        // 2. Common locations a Finder-launched app's PATH usually misses.
        appendDirectoryIfNew("\(homeDirectoryPath)/.local/bin")
        appendDirectoryIfNew("/opt/homebrew/bin")
        appendDirectoryIfNew("/usr/local/bin")
        appendDirectoryIfNew("/usr/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/.bun/bin")
        // Additional package-manager / custom-prefix install locations. Kept right
        // after ~/.bun/bin (and before the versioned managers below) so the fixed
        // well-known dirs are all grouped together.
        appendDirectoryIfNew("\(homeDirectoryPath)/.npm-global/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/.npm-packages/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/Library/pnpm")
        appendDirectoryIfNew("\(homeDirectoryPath)/.local/share/pnpm")
        appendDirectoryIfNew("\(homeDirectoryPath)/.yarn/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/.volta/bin")
        appendDirectoryIfNew("\(homeDirectoryPath)/.asdf/shims")
        appendDirectoryIfNew("\(homeDirectoryPath)/n/bin")

        // 3. Every node version installed under nvm, e.g.
        //    ~/.nvm/versions/node/v22.19.0/bin
        let nvmNodeVersionsParentDirectory = "\(homeDirectoryPath)/.nvm/versions/node"
        for nodeVersionDirectoryName in nvmNodeVersionDirectoryLister(nvmNodeVersionsParentDirectory) {
            appendDirectoryIfNew("\(nvmNodeVersionsParentDirectory)/\(nodeVersionDirectoryName)/bin")
        }

        // 4. Every node version installed under asdf, e.g.
        //    ~/.asdf/installs/nodejs/22.19.0/bin
        let asdfNodeVersionsParentDirectory = "\(homeDirectoryPath)/.asdf/installs/nodejs"
        for nodeVersionDirectoryName in asdfNodeVersionDirectoryLister(asdfNodeVersionsParentDirectory) {
            appendDirectoryIfNew("\(asdfNodeVersionsParentDirectory)/\(nodeVersionDirectoryName)/bin")
        }

        // 5. Every active fnm shell environment, e.g.
        //    ~/.local/state/fnm_multishells/<id>/bin
        let fnmShellsParentDirectory = "\(homeDirectoryPath)/.local/state/fnm_multishells"
        for shellDirectoryName in fnmShellDirectoryLister(fnmShellsParentDirectory) {
            appendDirectoryIfNew("\(fnmShellsParentDirectory)/\(shellDirectoryName)/bin")
        }

        return orderedDirectories
    }

    /// Interprets the raw stdout of the login-shell probe
    /// (`command -v <binary> || echo $PATH`) into a resolved binary path. Pure:
    /// `isExecutableFile` is injected. Handles both probe outcomes —
    ///   • `command -v` succeeded → stdout is the absolute path to the binary; or
    ///   • it failed → stdout is the shell's PATH value, which we then scan.
    static func resolveBinaryPathFromLoginShellOutput(
        binaryName: String,
        loginShellOutput: String,
        isExecutableFile: (String) -> Bool
    ) -> String? {
        let trimmedOutput = loginShellOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return nil }

        // Case 1: `command -v` resolved the binary directly. Its output is a single
        // absolute path (no colons, so it can't be a PATH value) ending in the
        // binary name — verify it's actually executable before trusting it.
        let firstOutputLine = trimmedOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmedOutput
        if firstOutputLine.hasPrefix("/"),
           !firstOutputLine.contains(":"),
           (firstOutputLine as NSString).lastPathComponent == binaryName,
           isExecutableFile(firstOutputLine) {
            return firstOutputLine
        }

        // Case 2: fall back to scanning the login shell's PATH value directory by
        // directory (same first-match-wins scan the fast path uses).
        let loginShellPathDirectories = trimmedOutput
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        return resolveBinaryPath(
            binaryName: binaryName,
            searchDirectories: loginShellPathDirectories,
            isExecutableFile: isExecutableFile
        )
    }

    /// A binary name is only safe to interpolate into the `sh -c` probe string if it
    /// contains nothing but the characters a real CLI binary name uses. This is a
    /// strict whitelist (letters, digits, `_`, `.`, `-`) so no shell metacharacter —
    /// space, `;`, `|`, `$`, backtick, quote, `&`, `(`, newline, … — can ever reach
    /// the shell. Pure; used to gate the login-shell probe.
    static func isBinaryNameSafeForShellProbe(_ binaryName: String) -> Bool {
        guard !binaryName.isEmpty else { return false }
        let allowedCharacters = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return binaryName.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    /// The login-shell PATH probe fallback. Runs the user's own login shell so we
    /// inherit the exact PATH their terminal has, then resolves the binary from its
    /// output. Pure/testable: both the shell execution and the executable check are
    /// injected. Only meaningful AFTER the fast path misses (it spawns a process).
    static func resolveBinaryPathViaLoginShell(
        binaryName: String,
        loginShellPath: String?,
        runLoginShellCommand: (_ shellPath: String, _ command: String) -> String?,
        isExecutableFile: (String) -> Bool
    ) -> String? {
        // Never build a shell command from an unvalidated name — a crafted name must
        // be impossible to inject. If it isn't a plain binary name, skip the probe
        // entirely (the fast path already covers every real install location).
        guard isBinaryNameSafeForShellProbe(binaryName) else { return nil }

        // Prefer the user's configured $SHELL; fall back to zsh (the macOS default).
        let resolvedShellPath = (loginShellPath?.isEmpty == false) ? loginShellPath! : "/bin/zsh"
        // `command -v` prints the binary's path (and exits 0) when it's on the login
        // shell's PATH; otherwise we print the PATH itself so we can scan it. The name
        // is whitelist-validated above, so this interpolation cannot inject shell.
        let probeCommand = "command -v \(binaryName) 2>/dev/null || printf '%s' \"$PATH\""
        guard let loginShellOutput = runLoginShellCommand(resolvedShellPath, probeCommand) else {
            return nil
        }
        return resolveBinaryPathFromLoginShellOutput(
            binaryName: binaryName,
            loginShellOutput: loginShellOutput,
            isExecutableFile: isExecutableFile
        )
    }

    /// Resolves `binaryName` fast-path first (scan `searchDirectories`), and ONLY on
    /// a miss falls back to the login-shell probe. Pure: the executable check and the
    /// shell exec are injected, so a test can prove the sequencing — the shell exec is
    /// never invoked when the fast path already found the binary. Production wires the
    /// real FileManager + Process via `resolveInstalledBinaryPath`.
    static func resolveBinaryPathWithLoginShellFallback(
        binaryName: String,
        searchDirectories: [String],
        loginShellPath: String?,
        runLoginShellCommand: (_ shellPath: String, _ command: String) -> String?,
        isExecutableFile: (String) -> Bool
    ) -> String? {
        if let fastPathResolved = resolveBinaryPath(
            binaryName: binaryName,
            searchDirectories: searchDirectories,
            isExecutableFile: isExecutableFile
        ) {
            return fastPathResolved
        }

        return resolveBinaryPathViaLoginShell(
            binaryName: binaryName,
            loginShellPath: loginShellPath,
            runLoginShellCommand: runLoginShellCommand,
            isExecutableFile: isExecutableFile
        )
    }

    /// Real-filesystem convenience that wires the pure helpers above to
    /// FileManager. Returns the absolute path to `binaryName`, or nil if it is
    /// not installed anywhere we know to look. Tries the fast hardcoded/PATH scan
    /// first; only if that misses does it pay for the login-shell probe.
    static func resolveInstalledBinaryPath(binaryName: String) -> String? {
        let fileManager = FileManager.default
        let homeDirectoryPath = NSHomeDirectory()

        let listVersionedManagerDirectories: (String) -> [String] = { parentDirectory in
            (try? fileManager.contentsOfDirectory(atPath: parentDirectory)) ?? []
        }

        let searchDirectories = candidateSearchDirectories(
            pathEnvironmentValue: ProcessInfo.processInfo.environment["PATH"],
            homeDirectoryPath: homeDirectoryPath,
            nvmNodeVersionDirectoryLister: listVersionedManagerDirectories,
            asdfNodeVersionDirectoryLister: listVersionedManagerDirectories,
            fnmShellDirectoryLister: listVersionedManagerDirectories
        )

        let isExecutableFile: (String) -> Bool = { candidatePath in
            fileManager.isExecutableFile(atPath: candidatePath)
        }

        // Fast hardcoded/PATH scan first; only on a miss does this pay for the
        // (slower) login-shell PATH probe so a binary installed by ANY manager the
        // user configured purely in their shell profile is still found.
        return resolveBinaryPathWithLoginShellFallback(
            binaryName: binaryName,
            searchDirectories: searchDirectories,
            loginShellPath: ProcessInfo.processInfo.environment["SHELL"],
            // Wrap the runner (which has a defaulted timeout param) in a plain
            // two-arg closure so it matches the `(shellPath, command) -> String?`
            // seam the fallback expects.
            runLoginShellCommand: { shellPath, command in
                runLoginShellCommandCapturingStandardOutput(shellPath: shellPath, command: command)
            },
            isExecutableFile: isExecutableFile
        )
    }

    /// How long the login-shell probe is allowed to run before we give up. A login
    /// shell can hang forever (a slow profile, a prompt) — this ceiling guarantees the
    /// probe can never freeze the caller.
    static let loginShellProbeTimeoutSeconds: TimeInterval = 2.0

    /// After SIGTERM, how long the shell gets to exit before we escalate to SIGKILL.
    /// Short — the child is already over its budget; this just lets a well-behaved
    /// shell exit cleanly before we force-kill a stubborn one.
    static let loginShellProbeTerminationGraceSeconds: TimeInterval = 0.2

    /// Default login-shell runner used in production: runs `<shellPath> -l -c
    /// <command>` and returns its stdout. `-l` makes it a LOGIN shell so it sources
    /// the user's profile and thus their real PATH. Genuinely bounded and
    /// self-reaping — it can never hang or leak a child:
    ///   • stderr goes to /dev/null so a chatty shell can't deadlock on a full,
    ///     undrained stderr pipe;
    ///   • stdout is drained on a background thread so a large write can't deadlock;
    ///   • BOTH the stdout drain AND the process exit are reaped on background
    ///     threads and gated by ONE DispatchGroup, so the single bounded wait below
    ///     covers the WHOLE probe — there is no unbounded `waitUntilExit` on any path;
    ///   • on timeout it escalates SIGTERM → (grace) → SIGKILL so even a
    ///     SIGTERM-ignoring shell (or a descendant holding stdout open) is guaranteed
    ///     to die, then returns nil gracefully.
    /// `timeoutSeconds` is injectable so a test can drive the timeout path fast.
    /// `onStandardOutputDrainFinished` is a test-only hook fired when the drain thread
    /// exits — it lets a test prove the drain never leaks even in the orphan case.
    static func runLoginShellCommandCapturingStandardOutput(
        shellPath: String,
        command: String,
        timeoutSeconds: TimeInterval = loginShellProbeTimeoutSeconds,
        onStandardOutputDrainFinished: (() -> Void)? = nil
    ) -> String? {
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: shellPath)
        shellProcess.arguments = ["-l", "-c", command]

        let standardOutputPipe = Pipe()
        shellProcess.standardOutput = standardOutputPipe
        // Send stderr straight to /dev/null: we never read it, and an undrained
        // stderr pipe would deadlock a shell that writes enough to fill it.
        shellProcess.standardError = FileHandle.nullDevice

        do {
            try shellProcess.run()
        } catch {
            return nil
        }

        // Close OUR copy of the write end now that the child has inherited it, so the
        // reader sees EOF the moment the child (and any descendant) closes theirs —
        // otherwise this lingering write end keeps the read blocked forever.
        try? standardOutputPipe.fileHandleForWriting.close()

        // One group covers BOTH background reapers: the stdout drain and the process
        // exit. Waiting on it bounds the ENTIRE probe. The captured buffer is
        // lock-guarded so there is no unsynchronized cross-thread access.
        let probeCompletion = DispatchGroup()
        let outputBufferLock = NSLock()
        var collectedStandardOutputData = Data()
        let standardOutputReadHandle = standardOutputPipe.fileHandleForReading
        let standardOutputReadDescriptor = standardOutputReadHandle.fileDescriptor

        probeCompletion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            // Drain via raw POSIX read() so a concurrent force-close (below) can never
            // raise an unhandled ObjC NSFileHandleOperationException / crash: read()
            // just returns 0 (EOF, once all write ends close) or -1 (e.g. EBADF after
            // the forced close). Either way the loop exits, so this thread can never
            // leak — even when a profile-spawned descendant still holds the write end
            // open and only the forced close unblocks the read.
            var drainedStandardOutputData = Data()
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = readBuffer.withUnsafeMutableBytes { rawBuffer in
                    read(standardOutputReadDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                }
                guard bytesRead > 0 else { break }
                drainedStandardOutputData.append(contentsOf: readBuffer[0..<bytesRead])
            }
            outputBufferLock.lock()
            collectedStandardOutputData = drainedStandardOutputData
            outputBufferLock.unlock()
            probeCompletion.leave()
            onStandardOutputDrainFinished?()
        }

        probeCompletion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            // Reap the child off the calling thread so the wait below stays bounded;
            // a SIGKILL guarantees this returns.
            shellProcess.waitUntilExit()
            probeCompletion.leave()
        }

        if probeCompletion.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            // Over budget. Escalate SIGTERM → (grace) → SIGKILL so the shell can
            // NEVER outlive the bound. (Never a negative-pid group kill — Foundation
            // children aren't group leaders, so that would signal our OWN process
            // group.)
            shellProcess.terminate()
            if probeCompletion.wait(timeout: .now() + loginShellProbeTerminationGraceSeconds) == .timedOut {
                if shellProcess.isRunning {
                    kill(shellProcess.processIdentifier, SIGKILL)
                }
            }
            // Killing the shell isn't enough: a profile-spawned BACKGROUND child can
            // have inherited the stdout write end and keep it open, leaving the drain
            // thread blocked on read forever. FORCE-CLOSE the read end so that read
            // unblocks immediately (EOF / caught error). Closing through the FileHandle
            // marks it closed, so there's no double-close when the pipe deallocates.
            try? standardOutputReadHandle.close()
            return nil
        }

        // Both stdout EOF and process exit happened within the bound.
        outputBufferLock.lock()
        let capturedStandardOutputData = collectedStandardOutputData
        outputBufferLock.unlock()
        return String(data: capturedStandardOutputData, encoding: .utf8)
    }
}
