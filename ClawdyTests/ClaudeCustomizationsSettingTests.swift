//
//  ClaudeCustomizationsSettingTests.swift
//  ClawdyTests
//
//  Headless coverage for the single "Use my Claude Code setup" setting
//  (`useClaudeCustomizations`, default true) that controls `--safe-mode` on BOTH the
//  warm quick-answer path AND the research path, plus the guard that turns the known
//  `--safe-mode` + stream-json EMPTY-OUTPUT breakage into SPECIFIC guidance rather
//  than the generic snag. Pure arg vectors + pure decisions, so no process launches.
//

import Testing
import Foundation
@testable import Clawdy

struct ClaudeCustomizationsSettingTests {

    // MARK: - Warm quick-answer path (ClaudeCodeEngine.makeArguments)

    @Test func warmPathOmitsSafeModeWhenCustomizationsEnabled() {
        let args = ClaudeCodeEngine.makeArguments(systemPrompt: "coach", useClaudeCustomizations: true)
        // Customizations load → NO --safe-mode.
        #expect(args.contains("--safe-mode") == false)
        // Invariants regardless of the toggle: never --bare (subscription auth), and
        // the warm path keeps all tools disabled via --tools "".
        #expect(args.contains("--bare") == false)
        let toolsIndex = args.firstIndex(of: "--tools")
        #expect(toolsIndex != nil)
        #expect(args[toolsIndex! + 1] == "")
        #expect(args.contains("--input-format"))
    }

    @Test func warmPathAddsSafeModeWhenCustomizationsDisabled() {
        let args = ClaudeCodeEngine.makeArguments(systemPrompt: "coach", useClaudeCustomizations: false)
        // Isolation → --safe-mode present.
        #expect(args.contains("--safe-mode"))
        // Still subscription-billed and still tool-disabled.
        #expect(args.contains("--bare") == false)
        let toolsIndex = args.firstIndex(of: "--tools")
        #expect(toolsIndex != nil)
        #expect(args[toolsIndex! + 1] == "")
    }

    // MARK: - Research path (ResearchArguments, both phases)

    @Test func researchPlanOmitsSafeModeWhenCustomizationsEnabled() {
        let args = ResearchArguments.makePlanArguments(
            task: "research X", sessionID: "sess-1", systemPrompt: "sys", useClaudeCustomizations: true
        )
        #expect(args.contains("--safe-mode") == false)
        // Plan invariants unchanged: plan mode, no tool allowlist, never --bare.
        #expect(args.contains("--permission-mode"))
        #expect(args.contains("plan"))
        #expect(args.contains("--allowedTools") == false)
        #expect(args.contains("--bare") == false)
    }

    @Test func researchPlanAddsSafeModeWhenCustomizationsDisabled() {
        let args = ResearchArguments.makePlanArguments(
            task: "research X", sessionID: "sess-1", systemPrompt: "sys", useClaudeCustomizations: false
        )
        #expect(args.contains("--safe-mode"))
        #expect(args.contains("plan"))
        #expect(args.contains("--bare") == false)
    }

    @Test func researchExecuteOmitsSafeModeWhenCustomizationsEnabled() {
        let args = ResearchArguments.makeExecuteArguments(
            sessionID: "sess-1", outputDirectoryPath: "/tmp/run", maxBudgetUSD: 5,
            userMessage: "proceed", systemPrompt: "sys", useClaudeCustomizations: true
        )
        #expect(args.contains("--safe-mode") == false)
        // Execute invariants unchanged: the narrow allowlist and budget cap remain,
        // and bypassPermissions / --bare are never granted.
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("WebSearch"))
        #expect(args.contains("WebFetch"))
        #expect(args.contains("Write"))
        #expect(args.contains("--max-budget-usd"))
        #expect(args.contains("bypassPermissions") == false)
        #expect(args.contains("--bare") == false)
    }

    @Test func researchExecuteAddsSafeModeWhenCustomizationsDisabled() {
        let args = ResearchArguments.makeExecuteArguments(
            sessionID: "sess-1", outputDirectoryPath: "/tmp/run", maxBudgetUSD: 5,
            userMessage: "proceed", systemPrompt: "sys", useClaudeCustomizations: false
        )
        #expect(args.contains("--safe-mode"))
        // safe-mode isolates settings sources but NOT the explicit tool grants — the
        // allowlist and budget must still be present when isolated.
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("WebSearch"))
        #expect(args.contains("--max-budget-usd"))
        #expect(args.contains("bypassPermissions") == false)
        #expect(args.contains("--bare") == false)
    }

    // MARK: - Safe-mode empty-output guard (warm path)

    @Test func safeModeEmptyTurnIsRecognizedOnlyUnderIsolation() {
        // Isolation active + a turn that produced no text → the known safe-mode +
        // stream-json empty-output incompatibility.
        #expect(ClaudePersistentSessionPolicy.isLikelySafeModeEmptyOutput(
            safeModeActive: true, producedAnyText: false
        ) == true)
        // A turn that DID stream text is a normal turn, not the empty-output bug.
        #expect(ClaudePersistentSessionPolicy.isLikelySafeModeEmptyOutput(
            safeModeActive: true, producedAnyText: true
        ) == false)
        // With customizations ON (safe-mode inactive) an empty end is a GENERIC crash,
        // never the isolation-specific message.
        #expect(ClaudePersistentSessionPolicy.isLikelySafeModeEmptyOutput(
            safeModeActive: false, producedAnyText: false
        ) == false)
    }

    @Test func isolationUnsupportedErrorCarriesActionableGuidance() {
        let message = ClaudePersistentSession.SessionError.isolationModeUnsupported.errorDescription ?? ""
        // The message must name the setting so the user knows the fix — NOT the generic
        // "ended unexpectedly" text.
        #expect(message.contains("Use my Claude Code setup"))
        #expect(message.contains("ended unexpectedly") == false)
    }

    // MARK: - Spoken fallback selection (generic snag vs. specific guidance)

    @MainActor
    @Test func spokenFallbackGivesSpecificGuidanceForIsolationEmptyOutput() {
        let spoken = CompanionManager.localErrorFallbackUtterance(
            for: ClaudePersistentSession.SessionError.isolationModeUnsupported,
            hasAnyCoachEngineInstalled: true
        )
        // Specific, actionable — mentions the setting; not the generic snag.
        #expect(spoken.contains("use my claude code setup"))
        #expect(spoken.contains("hit a snag") == false)
    }

    @MainActor
    @Test func spokenFallbackGivesGenericSnagForOtherErrors() {
        let spoken = CompanionManager.localErrorFallbackUtterance(
            for: ClaudePersistentSession.SessionError.responseReportedError,
            hasAnyCoachEngineInstalled: true
        )
        #expect(spoken.contains("hit a snag"))
        #expect(spoken.contains("use my claude code setup") == false)
    }

    @MainActor
    @Test func spokenFallbackAsksToInstallWhenNoEngine() {
        // No engine installed wins over everything else.
        let spoken = CompanionManager.localErrorFallbackUtterance(
            for: ClaudePersistentSession.SessionError.isolationModeUnsupported,
            hasAnyCoachEngineInstalled: false
        )
        #expect(spoken.contains("install"))
    }
}
