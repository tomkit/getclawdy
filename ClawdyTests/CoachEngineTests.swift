//
//  CoachEngineTests.swift
//  ClawdyTests
//
//  Headless unit tests for the CLI-subscription engine layer: binary
//  resolution, CLI argument construction, prompt composition, the streaming
//  output parsers, and the [POINT:...] tag parser. None of these touch the
//  filesystem, network, or a real CLI — they exercise the pure logic.
//

import Testing
import Foundation
import Combine
@testable import Clawdy

struct CoachEngineTests {

    // MARK: - Binary resolution

    @Test func resolveBinaryPathReturnsFirstDirectoryContainingExecutable() {
        let resolvedPath = CLIBinaryResolver.resolveBinaryPath(
            binaryName: "claude",
            searchDirectories: ["/usr/bin", "/opt/homebrew/bin", "/Users/me/.local/bin"],
            isExecutableFile: { candidatePath in
                candidatePath == "/opt/homebrew/bin/claude"
            }
        )

        #expect(resolvedPath == "/opt/homebrew/bin/claude")
    }

    @Test func resolveBinaryPathRespectsSearchOrder() {
        // Both directories contain the binary; the earlier one must win.
        let resolvedPath = CLIBinaryResolver.resolveBinaryPath(
            binaryName: "codex",
            searchDirectories: ["/first/bin", "/second/bin"],
            isExecutableFile: { _ in true }
        )

        #expect(resolvedPath == "/first/bin/codex")
    }

    @Test func resolveBinaryPathReturnsNilWhenNotInstalledAnywhere() {
        let resolvedPath = CLIBinaryResolver.resolveBinaryPath(
            binaryName: "claude",
            searchDirectories: ["/usr/bin", "/opt/homebrew/bin"],
            isExecutableFile: { _ in false }
        )

        #expect(resolvedPath == nil)
    }

    @Test func candidateSearchDirectoriesIncludesPathCommonLocationsAndNvm() {
        let directories = CLIBinaryResolver.candidateSearchDirectories(
            pathEnvironmentValue: "/usr/bin:/bin",
            homeDirectoryPath: "/Users/me",
            nvmNodeVersionDirectoryLister: { parentDirectory in
                #expect(parentDirectory == "/Users/me/.nvm/versions/node")
                return ["v22.19.0", "v20.0.0"]
            }
        )

        // PATH entries come first, in order.
        #expect(directories.first == "/usr/bin")
        #expect(directories.contains("/bin"))
        // Common locations a Finder-launched app's PATH misses.
        #expect(directories.contains("/Users/me/.local/bin"))
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.contains("/usr/local/bin"))
        // Every nvm node version's bin directory.
        #expect(directories.contains("/Users/me/.nvm/versions/node/v22.19.0/bin"))
        #expect(directories.contains("/Users/me/.nvm/versions/node/v20.0.0/bin"))
    }

    @Test func candidateSearchDirectoriesDeduplicates() {
        // /usr/bin is on PATH and also a common location — it must appear once.
        let directories = CLIBinaryResolver.candidateSearchDirectories(
            pathEnvironmentValue: "/usr/bin:/opt/homebrew/bin",
            homeDirectoryPath: "/Users/me",
            nvmNodeVersionDirectoryLister: { _ in [] }
        )

        let usrBinOccurrences = directories.filter { $0 == "/usr/bin" }.count
        #expect(usrBinOccurrences == 1)
    }

    @Test func candidateSearchDirectoriesIncludesBroadManagerLocations() {
        let directories = CLIBinaryResolver.candidateSearchDirectories(
            pathEnvironmentValue: "/usr/bin",
            homeDirectoryPath: "/Users/me",
            nvmNodeVersionDirectoryLister: { _ in [] },
            asdfNodeVersionDirectoryLister: { parentDirectory in
                #expect(parentDirectory == "/Users/me/.asdf/installs/nodejs")
                return ["22.19.0"]
            },
            fnmShellDirectoryLister: { parentDirectory in
                #expect(parentDirectory == "/Users/me/.local/state/fnm_multishells")
                return ["abc123"]
            }
        )

        // The additional fixed package-manager / custom-prefix locations.
        #expect(directories.contains("/Users/me/.npm-global/bin"))
        #expect(directories.contains("/Users/me/.npm-packages/bin"))
        #expect(directories.contains("/Users/me/Library/pnpm"))
        #expect(directories.contains("/Users/me/.local/share/pnpm"))
        #expect(directories.contains("/Users/me/.yarn/bin"))
        #expect(directories.contains("/Users/me/.volta/bin"))
        #expect(directories.contains("/Users/me/.asdf/shims"))
        #expect(directories.contains("/Users/me/n/bin"))
        // The versioned asdf-node and fnm bin directories from the injected listers.
        #expect(directories.contains("/Users/me/.asdf/installs/nodejs/22.19.0/bin"))
        #expect(directories.contains("/Users/me/.local/state/fnm_multishells/abc123/bin"))
    }

    // MARK: - Login-shell PATH probe fallback

    @Test func loginShellProbeResolvesDirectCommandVHit() {
        // `command -v claude` succeeded, so the shell printed the binary's path.
        let resolvedPath = CLIBinaryResolver.resolveBinaryPathViaLoginShell(
            binaryName: "claude",
            loginShellPath: "/bin/zsh",
            runLoginShellCommand: { shellPath, command in
                #expect(shellPath == "/bin/zsh")
                #expect(command.contains("command -v claude"))
                return "/Users/me/.volta/bin/claude\n"
            },
            isExecutableFile: { candidatePath in
                candidatePath == "/Users/me/.volta/bin/claude"
            }
        )

        #expect(resolvedPath == "/Users/me/.volta/bin/claude")
    }

    @Test func loginShellProbeScansReturnedPathWhenCommandVMisses() {
        // `command -v` failed, so the shell fell back to printing its PATH; we then
        // scan that PATH directory by directory for the binary.
        let resolvedPath = CLIBinaryResolver.resolveBinaryPathViaLoginShell(
            binaryName: "codex",
            loginShellPath: "/bin/zsh",
            runLoginShellCommand: { _, _ in
                "/usr/bin:/Users/me/.volta/bin:/opt/homebrew/bin"
            },
            isExecutableFile: { candidatePath in
                candidatePath == "/Users/me/.volta/bin/codex"
            }
        )

        #expect(resolvedPath == "/Users/me/.volta/bin/codex")
    }

    @Test func loginShellProbeReturnsNilWhenBinaryNotFoundAnywhere() {
        let resolvedPath = CLIBinaryResolver.resolveBinaryPathViaLoginShell(
            binaryName: "claude",
            loginShellPath: nil,
            runLoginShellCommand: { _, _ in "/usr/bin:/bin" },
            isExecutableFile: { _ in false }
        )

        #expect(resolvedPath == nil)
    }

    @Test func loginShellProbeRejectsBinaryNameWithShellMetacharacters() {
        // A crafted name must never reach the shell: the probe is skipped entirely
        // (the runner closure is never invoked) and it resolves to nil.
        var shellCommandInvocationCount = 0
        for maliciousBinaryName in ["claude; rm -rf /", "claude$(whoami)", "cla ude", "claude`id`", "claude|cat", ""] {
            let resolvedPath = CLIBinaryResolver.resolveBinaryPathViaLoginShell(
                binaryName: maliciousBinaryName,
                loginShellPath: "/bin/zsh",
                runLoginShellCommand: { _, _ in
                    shellCommandInvocationCount += 1
                    return "/anything"
                },
                isExecutableFile: { _ in true }
            )
            #expect(resolvedPath == nil)
        }
        #expect(shellCommandInvocationCount == 0, "no crafted name may ever spawn a shell")
    }

    @Test func binaryNameSafetyWhitelistAcceptsRealNamesAndRejectsMetacharacters() {
        #expect(CLIBinaryResolver.isBinaryNameSafeForShellProbe("claude"))
        #expect(CLIBinaryResolver.isBinaryNameSafeForShellProbe("codex"))
        #expect(CLIBinaryResolver.isBinaryNameSafeForShellProbe("node-v22.1_x"))
        #expect(!CLIBinaryResolver.isBinaryNameSafeForShellProbe(""))
        #expect(!CLIBinaryResolver.isBinaryNameSafeForShellProbe("claude; rm -rf /"))
        #expect(!CLIBinaryResolver.isBinaryNameSafeForShellProbe("claude$(x)"))
        #expect(!CLIBinaryResolver.isBinaryNameSafeForShellProbe("a b"))
        #expect(!CLIBinaryResolver.isBinaryNameSafeForShellProbe("a/b"))
    }

    // MARK: - Fast-path-then-login-shell sequencing

    @Test func fallbackDoesNotSpawnShellWhenFastPathFindsBinary() {
        // When the fast directory scan finds the binary, the (slow) login-shell
        // fallback must NOT run — assert the shell closure records zero calls.
        var shellCommandInvocationCount = 0
        let resolvedPath = CLIBinaryResolver.resolveBinaryPathWithLoginShellFallback(
            binaryName: "claude",
            searchDirectories: ["/opt/homebrew/bin"],
            loginShellPath: "/bin/zsh",
            runLoginShellCommand: { _, _ in
                shellCommandInvocationCount += 1
                return "/should/not/be/used/claude"
            },
            isExecutableFile: { candidatePath in
                candidatePath == "/opt/homebrew/bin/claude"
            }
        )

        #expect(resolvedPath == "/opt/homebrew/bin/claude")
        #expect(shellCommandInvocationCount == 0, "fast-path hit must not spawn the login shell")
    }

    @Test func fallbackSpawnsShellExactlyOnceOnFastPathMiss() {
        // When the fast scan misses everywhere, the login-shell fallback runs once
        // and resolves from its output.
        var shellCommandInvocationCount = 0
        let resolvedPath = CLIBinaryResolver.resolveBinaryPathWithLoginShellFallback(
            binaryName: "claude",
            searchDirectories: ["/usr/bin", "/opt/homebrew/bin"],
            loginShellPath: "/bin/zsh",
            runLoginShellCommand: { _, _ in
                shellCommandInvocationCount += 1
                return "/Users/me/.volta/bin/claude\n"
            },
            isExecutableFile: { candidatePath in
                candidatePath == "/Users/me/.volta/bin/claude"
            }
        )

        #expect(resolvedPath == "/Users/me/.volta/bin/claude")
        #expect(shellCommandInvocationCount == 1, "fast-path miss must spawn the login shell exactly once")
    }

    // MARK: - Login-shell runner is genuinely bounded (real process)

    @Test func loginShellRunnerReturnsNilWithinBoundWhenShellHangs() {
        // A shell that never finishes must NOT hang the caller: the runner has to
        // terminate/kill it and return nil well within the (tiny, injected) budget.
        let startedAt = Date()
        let output = CLIBinaryResolver.runLoginShellCommandCapturingStandardOutput(
            shellPath: "/bin/sh",
            command: "sleep 30",
            timeoutSeconds: 0.3
        )
        let elapsedSeconds = Date().timeIntervalSince(startedAt)

        #expect(output == nil)
        #expect(elapsedSeconds < 5.0, "the probe must be bounded, never wait out the full sleep")
    }

    @Test func loginShellRunnerCapturesStdoutForAFastCommand() {
        // The happy path through the REAL bounded runner still returns the output.
        let output = CLIBinaryResolver.runLoginShellCommandCapturingStandardOutput(
            shellPath: "/bin/sh",
            command: "printf clawdy-probe-ok",
            timeoutSeconds: 2.0
        )

        // A login shell may emit unrelated profile noise, so assert containment.
        #expect(output?.contains("clawdy-probe-ok") == true)
    }

    @Test func loginShellRunnerUnblocksDrainThreadWhenOrphanHoldsStdoutOpen() {
        // Orphan case: the shell backgrounds a long sleep that INHERITS the stdout
        // pipe, then exits immediately. The shell reaps fine (so no SIGKILL), but the
        // orphan keeps the write end open — so the drain thread would block on read
        // for the full 30s unless the forced FD-close on timeout unblocks it. The
        // sleep (30s) far outlasts the 5s drain-completion wait below, so this test
        // FAILS if the close fix is absent.
        let standardOutputDrainFinished = DispatchSemaphore(value: 0)
        let startedAt = Date()
        let output = CLIBinaryResolver.runLoginShellCommandCapturingStandardOutput(
            shellPath: "/bin/sh",
            command: "sleep 30 & exit 0",
            timeoutSeconds: 0.3,
            onStandardOutputDrainFinished: { standardOutputDrainFinished.signal() }
        )
        let elapsedSeconds = Date().timeIntervalSince(startedAt)

        #expect(output == nil)
        #expect(elapsedSeconds < 5.0, "the caller must return within the bound, never wait out the orphan")
        #expect(
            standardOutputDrainFinished.wait(timeout: .now() + 5.0) == .success,
            "the forced read-end close must unblock the drain thread so it can't leak"
        )
    }

    // MARK: - CLI argument construction

    @Test func claudeCodeArgumentsUsePrintModeStreamJSONInputAndNoTools() {
        // Default setting: customizations load (safe-mode OMITTED).
        let arguments = ClaudeCodeEngine.makeArguments(systemPrompt: "you are clawdy", useClaudeCustomizations: true)

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("--append-system-prompt"))
        #expect(arguments.contains("you are clawdy"))
        // Screenshots are now sent INLINE on stdin as base64 image blocks via
        // stream-json input — so num_turns stays 1 (no extra Read-tool turn).
        #expect(arguments.contains("--input-format"))
        #expect(arguments.contains("stream-json"))
        #expect(arguments.contains("--output-format"))
        // All tools disabled (the model no longer touches the filesystem).
        #expect(arguments.contains("--tools"))
        if let toolsIndex = arguments.firstIndex(of: "--tools") {
            #expect(arguments[arguments.index(after: toolsIndex)] == "")
        }
        // `--safe-mode` is deliberately ABSENT. Product decision: we WANT the user's
        // customizations (CLAUDE.md, skills, plugins, hooks, MCP) to load on the warm
        // path, and safe-mode disables exactly those. It also breaks
        // `--input-format stream-json` on claude 2.1.198 (exit 0, empty stdout), so
        // the two must never be combined regardless.
        #expect(!arguments.contains("--safe-mode"))
        #expect(arguments.contains("--exclude-dynamic-system-prompt-sections"))
        // The old Read-tool / temp-dir flags are gone.
        #expect(!arguments.contains("--allowedTools"))
        #expect(!arguments.contains("--add-dir"))
        #expect(!arguments.contains("Read"))
    }

    @Test func codexArgumentsUseExecReadOnlySandboxAndOneImageFlagPerScreenshot() {
        let arguments = CodexEngine.makeArguments(
            workingDirectoryPath: "/tmp/clawdy-engine/xyz",
            imageFilePaths: ["/tmp/clawdy-engine/xyz/screen1.jpg", "/tmp/clawdy-engine/xyz/screen2.jpg"]
        )

        #expect(arguments.first == "exec")
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("-s"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("-C"))
        #expect(arguments.contains("/tmp/clawdy-engine/xyz"))
        #expect(arguments.contains("--json"))
        // The coaching path lowers Codex's reasoning effort for latency: the
        // `-c` config override sits immediately before its `model_reasoning_effort=low`
        // value, ahead of the image flags and the trailing stdin marker.
        let reasoningEffortOverrideIndex = arguments.firstIndex(of: "model_reasoning_effort=low")
        #expect(reasoningEffortOverrideIndex != nil)
        if let reasoningEffortOverrideIndex {
            #expect(arguments[reasoningEffortOverrideIndex - 1] == "-c")
        }
        // One -i per attached screenshot.
        let imageFlagCount = arguments.filter { $0 == "-i" }.count
        #expect(imageFlagCount == 2)
        #expect(arguments.contains("/tmp/clawdy-engine/xyz/screen1.jpg"))
        #expect(arguments.contains("/tmp/clawdy-engine/xyz/screen2.jpg"))
        // The reasoning-effort override must not disturb the `-i`/stdin ordering:
        // it sits before the first image flag, which precedes the trailing "-".
        if let reasoningEffortOverrideIndex,
           let firstImageFlagIndex = arguments.firstIndex(of: "-i") {
            #expect(reasoningEffortOverrideIndex < firstImageFlagIndex)
        }
        // Trailing "-" => prompt is read from stdin.
        #expect(arguments.last == "-")
    }

    // MARK: - Prompt composition

    @Test func claudeInlinePromptDescribesImagesByLabelWithoutReadInstruction() {
        let prompt = CLIPromptComposer.composeClaudeInlinePromptText(
            imageLabels: ["user's screen (cursor is here) (image dimensions: 1280x800 pixels)"],
            userPrompt: "how do i commit"
        )

        #expect(prompt.contains("1280x800"))
        #expect(prompt.contains("how do i commit"))
        // Images are attached inline, described by order — not read from disk.
        #expect(prompt.contains("attached image 1"))
        // The model sees the images directly, so there is NO Read-tool instruction
        // and no temp file name to read.
        #expect(!prompt.contains("Read tool"))
        #expect(!prompt.contains("screen1.jpg"))
    }

    @Test func codexPromptFoldsInSystemPromptAndImageLabels() {
        let screenshotFiles = [
            CLIPromptComposer.WrittenScreenshotFile(
                absolutePath: "/tmp/x/screen1.jpg",
                fileName: "screen1.jpg",
                label: "screen 1 (image dimensions: 1512x982 pixels)"
            )
        ]

        let prompt = CLIPromptComposer.composeCodexPrompt(
            systemPrompt: "SYSTEM-PROMPT-MARKER you emit POINT tags",
            screenshotFiles: screenshotFiles,
            conversationHistory: [],
            userPrompt: "what's this"
        )

        // Codex has no system-prompt flag, so it must be folded into the text.
        #expect(prompt.contains("SYSTEM-PROMPT-MARKER"))
        #expect(prompt.contains("1512x982"))
        #expect(prompt.contains("what's this"))
    }

    @Test func conversationHistoryRendersWhenPresentAndEmptyOtherwise() {
        let empty = CLIPromptComposer.renderConversationHistory([])
        #expect(empty.isEmpty)

        let rendered = CLIPromptComposer.renderConversationHistory([
            (userPlaceholder: "hello", assistantResponse: "hi there")
        ])
        #expect(rendered.contains("hello"))
        #expect(rendered.contains("hi there"))
    }

    @Test func screenshotFileNameIsOneBased() {
        #expect(CLIPromptComposer.screenshotFileName(forScreenIndex: 0) == "screen1.jpg")
        #expect(CLIPromptComposer.screenshotFileName(forScreenIndex: 2) == "screen3.jpg")
    }

    // MARK: - Streaming output parsers

    @Test func claudeStreamEventParsesTextDeltasAndFinalResult() {
        // A wrapped text delta.
        #expect(
            ClaudeStreamEvent.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}}"#)
                == .textDelta("hello ")
        )

        // A non-text event is ignored.
        #expect(ClaudeStreamEvent.parse(line: #"{"type":"system","subtype":"hook_started"}"#) == .other)
        // Blank / unparseable lines are ignored.
        #expect(ClaudeStreamEvent.parse(line: "") == .other)
        #expect(ClaudeStreamEvent.parse(line: "not json") == .other)

        // The terminal result carries the authoritative answer and error flag.
        #expect(
            ClaudeStreamEvent.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"hello world [POINT:none]"}"#)
                == .result(text: "hello world [POINT:none]", isError: false)
        )
        #expect(
            ClaudeStreamEvent.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
                == .result(text: nil, isError: true)
        )
    }

    @Test func codexStreamParserExtractsAgentMessage() {
        let state = CodexStreamParseState()

        #expect(state.consume(line: #"{"type":"thread.started","thread_id":"x"}"#) == nil)
        #expect(state.consume(line: #"{"type":"turn.started"}"#) == nil)

        let agentMessage = state.consume(line: #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"that's the save button [POINT:640,400:save button]"}}"#)
        #expect(agentMessage == "that's the save button [POINT:640,400:save button]")
        #expect(state.latestAgentMessageText == "that's the save button [POINT:640,400:save button]")
    }
}

/// Real-path tests for the engine RESCAN → published-availability wiring: installing a
/// CLI while Clawdy runs must make the picker re-render even when the selected engine
/// doesn't move. Applies a crafted detected set directly (the DETECTION half runs off
/// the main actor and hits the real filesystem, which a unit test can't control).
@MainActor
struct CoachEngineRescanAvailabilityTests {

    private static let selectedEngineDefaultsKey = "selectedCoachEngine"

    @Test func rescanPublishesGrownAvailabilityEvenWhenSelectionUnchanged() {
        // Pin the persisted choice to Codex so restore/validation keeps Codex selected
        // across the grow — isolating "availability changed" from "selection changed".
        let previousPersistedValue = UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey)
        defer {
            if let previousPersistedValue {
                UserDefaults.standard.set(previousPersistedValue, forKey: Self.selectedEngineDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedEngineDefaultsKey)
            }
        }
        UserDefaults.standard.set(CoachEngineKind.codex.rawValue, forKey: Self.selectedEngineDefaultsKey)

        let manager = CompanionManager()

        // Baseline: only Codex present and selected. (Codex has no warm process, so
        // any prewarm here is a no-op — no real CLI is spawned.)
        manager.applyRescannedEngines([DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex")])
        #expect(manager.availableEngineKinds == [.codex])
        #expect(manager.selectedEngineKind == .codex)

        // Claude Code gets installed while running: the detected SET grows but the
        // SELECTED engine stays Codex (so nothing is prewarmed). The manager must still
        // publish objectWillChange so the picker re-renders off availableEngineKinds.
        var publishedChange = false
        let changeSubscription = manager.objectWillChange.sink { publishedChange = true }
        defer { changeSubscription.cancel() }

        manager.applyRescannedEngines([
            DetectedCoachEngine(kind: .claudeCode, binaryPath: "/fake/bin/claude"),
            DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex"),
        ])

        #expect(publishedChange, "growing the detected set must publish objectWillChange")
        #expect(manager.availableEngineKinds == [.claudeCode, .codex])
        #expect(manager.hasAnyCoachEngineInstalled)
        #expect(manager.selectedEngineKind == .codex, "selection stays put; only availability grew")
    }

    @Test func rescanWithUnchangedDetectedSetDoesNotRepublish() {
        let previousPersistedValue = UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey)
        defer {
            if let previousPersistedValue {
                UserDefaults.standard.set(previousPersistedValue, forKey: Self.selectedEngineDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedEngineDefaultsKey)
            }
        }
        UserDefaults.standard.set(CoachEngineKind.codex.rawValue, forKey: Self.selectedEngineDefaultsKey)

        let manager = CompanionManager()
        manager.applyRescannedEngines([DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex")])

        // Re-applying the SAME detected set must be a no-op: no republish, no churn.
        var publishedChange = false
        let changeSubscription = manager.objectWillChange.sink { publishedChange = true }
        defer { changeSubscription.cancel() }

        manager.applyRescannedEngines([DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex")])

        #expect(!publishedChange, "an unchanged detected set must not republish")
        #expect(manager.availableEngineKinds == [.codex])
    }

    @Test func staleGenerationRescanApplyIsDroppedInFavorOfNewer() {
        let previousPersistedValue = UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey)
        defer {
            if let previousPersistedValue {
                UserDefaults.standard.set(previousPersistedValue, forKey: Self.selectedEngineDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedEngineDefaultsKey)
            }
        }
        UserDefaults.standard.set(CoachEngineKind.codex.rawValue, forKey: Self.selectedEngineDefaultsKey)

        let manager = CompanionManager()
        manager.applyRescannedEngines([DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex")])
        #expect(manager.availableEngineKinds == [.codex])

        // Two overlapping rescans start; the newer supersedes the older.
        let olderRescanGeneration = manager.beginNextEngineRescanGeneration()
        let newerRescanGeneration = manager.beginNextEngineRescanGeneration()

        // The NEWER scan (found both engines) applies and grows availability.
        manager.applyRescannedEngines(
            [
                DetectedCoachEngine(kind: .claudeCode, binaryPath: "/fake/bin/claude"),
                DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex"),
            ],
            forRescanGeneration: newerRescanGeneration
        )
        #expect(manager.availableEngineKinds == [.claudeCode, .codex])

        // The slow OLDER scan (found only Codex) arrives LATE. It must be DROPPED —
        // not revert availability to the stale [.codex] nor mis-move the selection.
        manager.applyRescannedEngines(
            [DetectedCoachEngine(kind: .codex, binaryPath: "/fake/bin/codex")],
            forRescanGeneration: olderRescanGeneration
        )
        #expect(manager.availableEngineKinds == [.claudeCode, .codex], "a stale older-generation apply must be ignored")
        #expect(manager.selectedEngineKind == .codex)
    }

    // MARK: - UTF-8 decoding across pipe-read boundaries (P2)

    /// The '…' codepoint is E2 80 A6. When those three bytes are split across two
    /// reads, decoding each chunk independently as UTF-8 fails and drops the whole
    /// chunk. `UTF8StreamDecoder` must hold the incomplete leading bytes and emit the
    /// complete character once the last byte arrives — losing nothing.
    @Test func utf8StreamDecoderReassemblesThreeByteCodepointSplitAcrossReads() {
        var decoder = UTF8StreamDecoder()

        // First read ends mid-codepoint: "hi" + the first byte of '…'.
        let firstChunk = "hi".data(using: .utf8)! + Data([0xE2])
        let firstDecoded = decoder.decode(firstChunk)
        #expect(firstDecoded == "hi", "the incomplete leading codepoint byte must be held back, not dropped")

        // Second read delivers the remaining two bytes of '…', completing it.
        let secondChunk = Data([0x80, 0xA6])
        let secondDecoded = decoder.decode(secondChunk)
        #expect(secondDecoded == "…", "the codepoint completes and is emitted intact on the next read")

        // No bytes left dangling once the codepoint completed.
        #expect(decoder.flush() == "")
    }

    /// A 4-byte emoji (😀 = F0 9F 98 80) split so that THREE bytes arrive in the first
    /// read and the final byte in the second must also reassemble intact — the
    /// maximum-length incomplete trailing sequence the decoder has to hold.
    @Test func utf8StreamDecoderReassemblesFourByteEmojiSplitAcrossReads() {
        var decoder = UTF8StreamDecoder()

        let firstChunk = Data([0xF0, 0x9F, 0x98]) // first 3 bytes of 😀
        #expect(decoder.decode(firstChunk) == "", "an incomplete 4-byte codepoint yields nothing yet")

        let secondChunk = Data([0x80]) // final byte of 😀
        #expect(decoder.decode(secondChunk) == "😀")
        #expect(decoder.flush() == "")
    }

    /// The full 4-byte-split matrix: 1/3 (one byte, then the last three) and 2/2 (two
    /// bytes, then the last two) must BOTH reassemble 😀 intact — covering every
    /// boundary offset the 3/1 test above doesn't.
    @Test func utf8StreamDecoderReassemblesFourByteEmojiAtEveryBoundaryOffset() {
        // 1/3 split.
        var decoderOneThree = UTF8StreamDecoder()
        #expect(decoderOneThree.decode(Data([0xF0])) == "", "1 byte of a 4-byte codepoint yields nothing yet")
        #expect(decoderOneThree.decode(Data([0x9F, 0x98, 0x80])) == "😀")
        #expect(decoderOneThree.flush() == "")

        // 2/2 split.
        var decoderTwoTwo = UTF8StreamDecoder()
        #expect(decoderTwoTwo.decode(Data([0xF0, 0x9F])) == "", "2 bytes of a 4-byte codepoint yields nothing yet")
        #expect(decoderTwoTwo.decode(Data([0x98, 0x80])) == "😀")
        #expect(decoderTwoTwo.flush() == "")
    }

    /// An incomplete multibyte sequence still buffered at EOF must be surfaced by
    /// `flush()` (lossily, as a replacement char) — never silently dropped — AND the
    /// valid text decoded before it must already have been emitted intact.
    @Test func utf8StreamDecoderFlushSurfacesIncompleteTrailingSequenceAtEOF() {
        var decoder = UTF8StreamDecoder()

        // "ok" plus the first two bytes of '…' (E2 80) — the codepoint never completes.
        let decoded = decoder.decode("ok".data(using: .utf8)! + Data([0xE2, 0x80]))
        #expect(decoded == "ok", "the valid prefix is emitted; the incomplete tail is held")

        // At EOF the held bytes are flushed lossily rather than vanishing.
        let flushed = decoder.flush()
        #expect(flushed.contains("\u{FFFD}"), "the incomplete trailing codepoint surfaces as U+FFFD at EOF")
        #expect(decoder.flush() == "", "nothing remains after the flush")
    }

    /// Genuine corruption (an invalid byte that is NOT merely a short incomplete
    /// trailing sequence) falls back to a lossy decode that DOES NOT truncate the
    /// valid data around it, and leaves the buffer empty (bounded — it can't grow
    /// without bound on a stream of invalid bytes).
    @Test func utf8StreamDecoderLossyFallbackKeepsValidDataAndBoundsBuffer() {
        var decoder = UTF8StreamDecoder()

        // A leading invalid byte (0xFF is never valid UTF-8) followed by valid text.
        let decoded = decoder.decode(Data([0xFF]) + "abc".data(using: .utf8)!)
        #expect(decoded.contains("abc"), "valid data is never truncated by the lossy fallback")
        #expect(decoded.contains("\u{FFFD}"), "the invalid byte becomes a replacement char")
        #expect(decoder.flush() == "", "the buffer is fully drained — no unbounded growth")

        // A subsequent clean codepoint still decodes normally after the fallback.
        #expect(decoder.decode("d".data(using: .utf8)!) == "d")
    }

    /// End-to-end through `LineAccumulator` (the CLIProcessRunner stdout path): a full
    /// line whose multibyte character straddles two `append` (read) calls must be
    /// reassembled and emitted as ONE complete, correct line — not silently dropped.
    @Test func lineAccumulatorReassemblesLineWithMultibyteCharSplitAcrossReads() {
        var emittedLines: [String] = []
        let accumulator = LineAccumulator(onCompleteLine: { emittedLines.append($0) })

        // The line "hi…" followed by a newline, with '…' (E2 80 A6) split across the
        // two reads: read 1 = "hi" + E2, read 2 = 80 A6 + '\n'.
        accumulator.append("hi".data(using: .utf8)! + Data([0xE2]))
        #expect(emittedLines.isEmpty, "no complete line yet — the codepoint and newline haven't arrived")

        accumulator.append(Data([0x80, 0xA6]) + "\n".data(using: .utf8)!)

        #expect(emittedLines == ["hi…"], "the multibyte char survives the read boundary and the line is intact")
        #expect(accumulator.fullText == "hi…\n")
    }

    /// The `accumulatesFullText: false` mode (used by the app-lifetime warm
    /// `ClaudePersistentSession` reader) still emits every complete line and the
    /// trailing remainder identically — it just does NOT retain the running
    /// `fullText`, so an app-lifetime reader can't grow unbounded.
    @Test func lineAccumulatorWithoutFullTextStillEmitsLinesButRetainsNoText() {
        var emittedLines: [String] = []
        let accumulator = LineAccumulator(accumulatesFullText: false, onCompleteLine: { emittedLines.append($0) })

        accumulator.append("first line\nsecond line\ntrailing".data(using: .utf8)!)
        #expect(emittedLines == ["first line", "second line"], "complete lines are emitted as they arrive")

        accumulator.flushRemainder()
        #expect(emittedLines == ["first line", "second line", "trailing"], "the non-newline-terminated remainder is flushed")
        #expect(accumulator.fullText == "", "no running text is retained in this mode")
    }
}
