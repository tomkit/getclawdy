//
//  ClawdyActionTests.swift
//  ClawdyTests
//
//  The user-extensible ACTIONS system: the ACTION.md format round-trips the built-in
//  research action byte-for-byte (so the shipped file, the statics the engines read,
//  and the in-memory definition can't drift), a minimal user action inherits every
//  unspecified value from research, tags are validated, the generalized directive
//  parser routes any registered marker (longest wins), the router prompt lists every
//  action, the store installs defaults / loads user actions / skips malformed or
//  duplicate ones, the warm-reply route decision produces `.runAction` for a user
//  action, and the engines actually adopt an action's tools/prompts/deliverable.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Fixtures

private let minimalUserActionMarkdown = """
---
name: Trip planner
tag: TRIP
description: plans a multi-day trip and builds an itinerary page.
---

## when
route here for any "plan me N days in <place>" ask.
- user says "plan me 3 days in kyoto": [TRIP] plan a 3-day kyoto itinerary.

## execute-message
plan the trip {{task}} and write ONE self-contained HTML page to {{outputPath}} in {{outputDir}}.
"""

private func makeTempActionsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clawdy-actions-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeAction(_ markdown: String, id: String, in directory: URL) throws {
    let folder = directory.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try markdown.write(to: folder.appendingPathComponent(ClawdyActionFile.fileName), atomically: true, encoding: .utf8)
}

// MARK: - Format

struct ClawdyActionFileTests {
    /// The shipped `research/ACTION.md` is rendered from the built-in action and parses
    /// back to EXACTLY it — prompts, tools, budget, timeout, deliverable, everything.
    @Test func builtInResearchRoundTripsThroughTheFileFormat() throws {
        let rendered = ClawdyActionFile.render(.builtInResearch)
        let parsed = try ClawdyActionFile.parse(markdown: rendered, id: ClawdyAction.builtInResearchID)
        #expect(parsed == ClawdyAction.builtInResearch)
    }

    /// The engines' prompt statics are the built-in action's prompts (not a second copy).
    @Test func engineStaticsReadFromTheBuiltInAction() {
        #expect(ClaudeResearchEngine.planSystemPrompt == ClawdyAction.builtInResearch.planSystemPrompt)
        #expect(ClaudeResearchEngine.executeSystemPrompt == ClawdyAction.builtInResearch.executeSystemPrompt)
        #expect(ClaudeResearchEngine.followUpSystemPrompt == ClawdyAction.builtInResearch.followUpSystemPrompt)
        #expect(ResearchArguments.allowedTools == ClawdyAction.builtInResearch.tools)
        #expect(ClaudeResearchEngine.deliverableFileName == ClawdyAction.builtInResearch.deliverableFileName)
        #expect(CodexResearchEngine.deliverableFileName == ClawdyAction.builtInResearch.deliverableFileName)
    }

    /// A minimal user action needs only tag/description/when/execute-message; every other
    /// value is inherited from research, and the Claude execute-message doubles as the
    /// Codex stdin prompt when no `## codex-execute` is written.
    @Test func minimalUserActionInheritsResearchDefaults() throws {
        let action = try ClawdyActionFile.parse(markdown: minimalUserActionMarkdown, id: "trip")
        #expect(action.id == "trip")
        #expect(action.name == "Trip planner")
        #expect(action.tag == "TRIP")
        #expect(action.directiveMarker == "[TRIP]")
        #expect(action.whenToRoute.contains("[TRIP] plan a 3-day kyoto itinerary."))
        #expect(action.executeMessageTemplate.contains("{{outputPath}}"))
        #expect(action.codexExecuteTemplate == action.executeMessageTemplate)
        #expect(action.tools == ClawdyAction.builtInResearch.tools)
        #expect(action.maxBudgetUSD == ClawdyAction.builtInResearch.maxBudgetUSD)
        #expect(action.planPhase == ClawdyAction.builtInResearch.planPhase)
        #expect(action.planSystemPrompt == ClawdyAction.builtInResearch.planSystemPrompt)
        #expect(action.followUpSystemPrompt == ClawdyAction.builtInResearch.followUpSystemPrompt)
        #expect(action.deliverableFileName == "report.html")
    }

    @Test func frontmatterOptionsOverrideDefaults() throws {
        let markdown = """
        ---
        tag: DEEP_DIVE
        tools: WebSearch, Write
        max_budget_usd: 2.5
        plan_phase: no
        execute_timeout_seconds: 120
        deliverable_file: deep.html
        ---
        ## when
        x
        ## execute-message
        y {{outputPath}}
        """
        let action = try ClawdyActionFile.parse(markdown: markdown, id: "deep")
        #expect(action.tools == ["WebSearch", "Write"])
        #expect(action.maxBudgetUSD == 2.5)
        #expect(action.planPhase == false)
        #expect(action.executeTimeoutSeconds == 120)
        #expect(action.deliverableFileName == "deep.html")
        #expect(action.name == "Deep")
    }

    @Test func rejectsMissingOrInvalidTagsAndReservedMarkers() {
        let noTag = "---\nname: x\n---\n## when\nx\n## execute-message\ny"
        #expect(throws: ClawdyActionFile.ParseError.missingTag) {
            try ClawdyActionFile.parse(markdown: noTag, id: "x")
        }
        for badTag in ["point", "POINT", "FOLLOWUP", "re search", "9LIVES", "RE-SEARCH"] {
            let markdown = "---\ntag: \(badTag)\n---\n## when\nx\n## execute-message\ny"
            #expect(throws: ClawdyActionFile.ParseError.invalidTag(badTag)) {
                try ClawdyActionFile.parse(markdown: markdown, id: "x")
            }
        }
        let noWhen = "---\ntag: OK\n---\n## execute-message\ny"
        #expect(throws: ClawdyActionFile.ParseError.missingSection("when")) {
            try ClawdyActionFile.parse(markdown: noWhen, id: "x")
        }
        #expect(throws: ClawdyActionFile.ParseError.missingFrontmatter) {
            try ClawdyActionFile.parse(markdown: "## when\nx", id: "x")
        }
        #expect(throws: ClawdyActionFile.ParseError.unsupportedDeliverable("pdf")) {
            try ClawdyActionFile.parse(markdown: "---\ntag: OK\ndeliverable: pdf\n---\n## when\nx", id: "x")
        }
    }

    @Test func templatePlaceholdersRender() {
        let rendered = ClawdyAction.render(
            "do {{task}} → {{outputPath}} in {{outputDir}}",
            task: "plan kyoto", outputPath: "/runs/1/report.html", outputDir: "/runs/1"
        )
        #expect(rendered == "do plan kyoto → /runs/1/report.html in /runs/1")
    }
}

// MARK: - Directive + router prompt

struct ClawdyActionDirectiveTests {
    private let trip = try! ClawdyActionFile.parse(markdown: minimalUserActionMarkdown, id: "trip")

    @Test func parsesAnyRegisteredMarkerAndOnlyAsTheWholeReply() {
        let actions: [ClawdyAction] = [.builtInResearch, trip]
        let research = ClawdyActionDirective.parse(from: "[RESEARCH] find photos of aomori", actions: actions)
        #expect(research?.action.id == ClawdyAction.builtInResearchID)
        #expect(research?.taskDescription == "find photos of aomori")

        let routed = ClawdyActionDirective.parse(from: "  [TRIP] plan a 3-day kyoto itinerary.\n", actions: actions)
        #expect(routed?.action.id == "trip")
        #expect(routed?.taskDescription == "plan a 3-day kyoto itinerary.")

        #expect(ClawdyActionDirective.parse(from: "[TRIP]", actions: actions)?.taskDescription == nil)
        #expect(ClawdyActionDirective.parse(from: "sure, [TRIP] would fit", actions: actions) == nil)
        #expect(ClawdyActionDirective.parse(from: "[UNKNOWN] x", actions: actions) == nil)
    }

    @Test func longestMarkerWinsSoAPrefixTagCannotShadowALongerOne() throws {
        var deep = trip
        deep.id = "deep"; deep.tag = "TRIP_DEEP"
        let match = ClawdyActionDirective.parse(from: "[TRIP_DEEP] go", actions: [trip, deep])
        #expect(match?.action.id == "deep")
    }

    @Test func prefixSuppressionCoversEveryLoadedMarker() {
        let actions: [ClawdyAction] = [.builtInResearch, trip]
        for prefix in ["[", "[T", "[TRI", "[TRIP]", "[TRIP] plan", "[RESE", "[RESEARCH] x"] {
            #expect(ClawdyActionDirective.looksLikeDirectivePrefix(prefix, actions: actions) == true, "\(prefix)")
        }
        for notPrefix in ["ah, gotcha.", "[POINT:1,2:x]", "", "   ", "[XYZ] no"] {
            #expect(ClawdyActionDirective.looksLikeDirectivePrefix(notPrefix, actions: actions) == false, "\(notPrefix)")
        }
    }

    @Test func routerPromptListsEveryActionWithItsMarkerAndGuidance() {
        let prompt = ClawdyActionRouterPrompt.compose(actions: [.builtInResearch, trip])
        #expect(prompt.contains("[RESEARCH] — research:"))
        #expect(prompt.contains(ClawdyAction.builtInResearch.whenToRoute))
        #expect(prompt.contains("[TRIP] — trip planner:"))
        #expect(prompt.contains(trip.whenToRoute))
        #expect(prompt.lowercased().contains("pointing question"))
        #expect(prompt.contains("your ENTIRE reply must be exactly one line"))
    }

    /// The real route decision: POINT still wins over everything, research stays
    /// `.newResearch`, and a user action's marker becomes `.runAction`.
    @MainActor @Test func warmReplyRouteRunsUserActions() {
        let actions: [ClawdyAction] = [.builtInResearch, trip]
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[TRIP] plan kyoto", isResearchSessionFocused: false, actions: actions)
                == .runAction(trip, task: "plan kyoto"))
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[RESEARCH] find hotels", isResearchSessionFocused: false, actions: actions)
                == .newResearch(task: "find hotels"))
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[TRIP] plan kyoto [POINT:1,1:x]", isResearchSessionFocused: true, actions: actions)
                == .speakOrPoint)
        // An action that ISN'T loaded this turn is never honored.
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[TRIP] plan kyoto", isResearchSessionFocused: false, actions: [.builtInResearch])
                == .speakOrPoint)
    }
}

// MARK: - Store

struct ClawdyActionStoreTests {
    @Test func installsDefaultsOnceAndLoadsBuiltInResearchFromDisk() throws {
        let directory = try makeTempActionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClawdyActionStore(actionsDirectory: directory)

        store.installDefaultsIfMissing()
        let researchFile = store.actionFileURL(id: ClawdyAction.builtInResearchID)
        #expect(FileManager.default.fileExists(atPath: researchFile.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("README.md").path))

        // The user's edits survive a second install (never overwritten).
        try "---\ntag: RESEARCH\n---\n## when\nedited\n## execute-message\nedited {{outputPath}}".write(to: researchFile, atomically: true, encoding: .utf8)
        store.installDefaultsIfMissing()
        let loaded = store.loadActions()
        #expect(loaded.count == 1)
        #expect(loaded[0].whenToRoute == "edited")
        #expect(loaded[0].planSystemPrompt == ClawdyAction.builtInResearch.planSystemPrompt)
    }

    @Test func withNoFilesAtAllTheBuiltInResearchActionIsStillThere() throws {
        let directory = try makeTempActionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClawdyActionStore(actionsDirectory: directory.appendingPathComponent("missing"))
        #expect(store.loadActions() == [.builtInResearch])
    }

    @Test func loadsUserActionsSkipsMalformedOnesAndDuplicateTags() throws {
        let directory = try makeTempActionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClawdyActionStore(actionsDirectory: directory)
        try writeAction(minimalUserActionMarkdown, id: "trip", in: directory)
        try writeAction("not an action at all", id: "broken", in: directory)
        try writeAction(minimalUserActionMarkdown.replacingOccurrences(of: "tag: TRIP", with: "tag: RESEARCH"), id: "zz-dupe", in: directory)
        // A malformed research/ACTION.md must not take research away.
        try writeAction("---\ntag: RESEARCH\n---\nno when section", id: ClawdyAction.builtInResearchID, in: directory)

        let loaded = store.loadActions()
        #expect(loaded.map(\.id) == [ClawdyAction.builtInResearchID, "trip"])
        #expect(loaded[0] == .builtInResearch)
        #expect(loaded[1].tag == "TRIP")
    }
}

// MARK: - Engines adopt the action

@MainActor
struct ClawdyActionEngineAdoptionTests {
    private let trip = try! ClawdyActionFile.parse(
        markdown: minimalUserActionMarkdown.replacingOccurrences(of: "tag: TRIP", with: "tag: TRIP\ntools: WebSearch, Write\nmax_budget_usd: 1\nexecute_timeout_seconds: 42\ndeliverable_file: trip.html"),
        id: "trip"
    )

    @Test func claudeExecuteArgumentsUseTheActionsToolAllowlist() {
        let arguments = ResearchArguments.makeExecuteArguments(
            sessionID: "s", outputDirectoryPath: "/out", maxBudgetUSD: 1, userMessage: "m", systemPrompt: "p",
            useClaudeCustomizations: true, allowedTools: trip.tools
        )
        let toolsIndex = arguments.firstIndex(of: "--allowedTools")!
        #expect(Array(arguments[(toolsIndex + 1)...(toolsIndex + 2)]) == ["WebSearch", "Write"])
        #expect(!arguments.contains("WebFetch"))
    }

    @Test func enginesAdoptAUserActionButKeepInjectedKnobsForBuiltInResearch() {
        let claude = ClaudeResearchEngine(binaryPath: "/bin/true", executePhaseTimeoutSeconds: 7, maxBudgetUSD: 9)
        claude.adoptAction(.builtInResearch)
        #expect(claude.action == .builtInResearch)
        claude.adoptAction(trip)
        #expect(claude.action.deliverableFileName == "trip.html")
        #expect(claude.action.tools == ["WebSearch", "Write"])

        let codex = CodexResearchEngine(binaryPath: "/bin/true", executePhaseTimeoutSeconds: 7)
        codex.adoptAction(trip)
        #expect(codex.action.tag == "TRIP")
    }

    @Test func composersRenderTheActionTemplateWithThePath() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/out/trip.html",
            clarificationAnswers: "three days",
            template: ClawdyAction.render(trip.executeMessageTemplate, task: "kyoto", outputPath: "/out/trip.html", outputDir: "/out")
        )
        #expect(message.hasPrefix("three days\n\n"))
        #expect(message.contains("plan the trip kyoto and write ONE self-contained HTML page to /out/trip.html in /out."))

        let codexPrompt = CodexResearchEngine.composeExecutePrompt(
            task: "kyoto", outputFileAbsolutePath: "/out/trip.html", clarificationAnswers: nil,
            template: ClawdyAction.render(trip.codexExecuteTemplate, task: "kyoto", outputPath: "/out/trip.html", outputDir: "/out")
        )
        #expect(codexPrompt.hasPrefix("research task: kyoto\n\n"))
        #expect(codexPrompt.contains("/out/trip.html"))

        // The default (no template) is still the built-in research text.
        let defaultMessage = ClaudeResearchEngine.composeExecuteUserMessage(outputFileAbsolutePath: "/out/report.html", clarificationAnswers: nil)
        #expect(defaultMessage == ClawdyAction.render(ClawdyAction.builtInResearch.executeMessageTemplate, task: "", outputPath: "/out/report.html", outputDir: "/out"))
    }

    /// A session records WHICH action produced the run in the manifest.
    @Test func manifestRecordsTheActionID() throws {
        let directory = try makeTempActionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchManifestStore(fileURL: directory.appendingPathComponent("manifest.json"), dateProvider: { Date(timeIntervalSince1970: 0) })
        store.recordResearchSessionStarted(sessionId: "a", title: "t", task: "k", workingDir: "/w", transcriptPath: "", engineKind: .claudeCode, actionID: "trip")
        store.recordResearchSessionStarted(sessionId: "b", title: "t", task: "k", workingDir: "/w", transcriptPath: "")
        let entries = store.loadSessions()
        #expect(entries.first { $0.sessionId == "a" }?.actionID == "trip")
        #expect(entries.first { $0.sessionId == "b" }?.actionID == ClawdyAction.builtInResearchID)
    }
}
