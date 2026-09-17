//
//  ClawdySkillTests.swift
//  ClawdyTests
//
//  The skills system: SKILL.md (the same format as Claude Code / Codex skills) round-trips
//  the built-in research skill byte-for-byte (so the shipped file, the statics the engines
//  read, and the in-memory definition can't drift); a plain Clawdy skill needs only a
//  description + body and inherits the rest; harness skills are read from their own
//  SKILL.md (name/description/allowed-tools only) and routed as `[SKILL:name]`; tags are
//  validated; the directive parser routes any loaded marker (longest wins); the router
//  prompt lists every skill; the store installs defaults once, loads Clawdy + harness
//  skills, and skips malformed/duplicate ones; `routeWarmReply` → `.runSkill`; the engines
//  adopt a skill's tools/prompts/deliverable; a plan-less skill STARTS its session
//  (`--session-id`) instead of resuming; a no-deliverable run returns and exposes the
//  spoken result; and the manifest records the `skillID`.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - Fixtures

private let plainClawdySkillMarkdown = """
---
name: trip-planner
description: plans a multi-day trip and builds an itinerary page. use for "plan me N days in <place>". example — user says "plan me 3 days in kyoto": [TRIP_PLANNER] plan a 3-day kyoto itinerary.
---

plan the trip {{task}} and write ONE self-contained HTML page to {{outputPath}} in {{outputDir}}.
"""

private let harnessSkillMarkdown = """
---
name: pdf
description: Fills, reads and summarizes PDF forms and documents. Use when the user mentions a PDF.
allowed-tools: Read, Bash(python:*)
---

# PDF skill
Long instructions the harness loads itself…
"""

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clawdy-skills-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSkill(_ markdown: String, id: String, in directory: URL) throws {
    let folder = directory.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try markdown.write(to: folder.appendingPathComponent(ClawdySkillFile.fileName), atomically: true, encoding: .utf8)
}

// MARK: - Format

struct ClawdySkillFileTests {
    /// The shipped `research/SKILL.md` is rendered from the built-in skill and parses back
    /// to EXACTLY it — description, prompts, tools, budget, timeout, deliverable.
    @Test func builtInResearchRoundTripsThroughSKILLmd() throws {
        let rendered = ClawdySkillFile.render(.builtInResearch)
        let parsed = try ClawdySkillFile.parseClawdySkill(markdown: rendered, id: ClawdySkill.builtInResearchID)
        #expect(parsed == ClawdySkill.builtInResearch)
    }

    /// The engines' prompt statics are the built-in skill's prompts (not a second copy).
    @Test func engineStaticsReadFromTheBuiltInSkill() {
        #expect(ClaudeResearchEngine.planSystemPrompt == ClawdySkill.builtInResearch.planSystemPrompt)
        #expect(ClaudeResearchEngine.executeSystemPrompt == ClawdySkill.builtInResearch.executeSystemPrompt)
        #expect(ClaudeResearchEngine.followUpSystemPrompt == ClawdySkill.builtInResearch.followUpSystemPrompt)
        #expect(ResearchArguments.allowedTools == ClawdySkill.builtInResearch.tools)
        #expect(ClaudeResearchEngine.deliverableFileName == ClawdySkill.builtInResearch.deliverableFileName)
        #expect(CodexResearchEngine.deliverableFileName == ClawdySkill.builtInResearch.deliverableFileName)
    }

    /// A plain Clawdy skill: description + body. The body is the execute message, the
    /// generic prompts frame it, the tag derives from the name, everything else inherits.
    @Test func plainClawdySkillUsesItsBodyAsTheExecuteMessage() throws {
        let skill = try ClawdySkillFile.parseClawdySkill(markdown: plainClawdySkillMarkdown, id: "trip-planner")
        #expect(skill.kind == .clawdy)
        #expect(skill.name == "trip-planner")
        #expect(skill.tag == "TRIP_PLANNER")
        #expect(skill.directiveMarker == "[TRIP_PLANNER]")
        #expect(skill.description.contains("[TRIP_PLANNER] plan a 3-day kyoto itinerary."))
        #expect(skill.executeMessageTemplate == "plan the trip {{task}} and write ONE self-contained HTML page to {{outputPath}} in {{outputDir}}.")
        #expect(skill.codexExecuteTemplate == skill.executeMessageTemplate)
        #expect(skill.planSystemPrompt == ClawdySkill.genericPlanSystemPrompt)
        #expect(skill.executeSystemPrompt == ClawdySkill.genericExecuteSystemPrompt)
        #expect(skill.followUpSystemPrompt == ClawdySkill.genericFollowUpSystemPrompt)
        #expect(skill.tools == ClawdySkill.builtInResearch.tools)
        #expect(skill.deliverable == .html)
        #expect(skill.deliverableFileName == "report.html")
    }

    @Test func clawdyFrontmatterKeysAndPhaseSectionsOverride() throws {
        let markdown = """
        ---
        name: deep dive
        description: >
          a folded
          description
        allowed-tools: WebSearch Write
        clawdy-tag: DEEP_DIVE
        clawdy-deliverable: none
        clawdy-max-budget-usd: 2.5
        clawdy-plan-phase: no
        clawdy-execute-timeout-seconds: 120
        ---
        ## Execute message
        do it {{task}}
        ## Follow-up message
        answer {{outputDir}}
        """
        let skill = try ClawdySkillFile.parseClawdySkill(markdown: markdown, id: "deep")
        #expect(skill.description == "a folded description")
        #expect(skill.tools == ["WebSearch", "Write"])
        #expect(skill.tag == "DEEP_DIVE")
        #expect(skill.deliverable == .none)
        #expect(skill.maxBudgetUSD == 2.5)
        #expect(skill.planPhase == false)
        #expect(skill.executeTimeoutSeconds == 120)
        #expect(skill.executeMessageTemplate == "do it {{task}}")
        #expect(skill.followUpMessageTemplate == "answer {{outputDir}}")
        // Unspecified phase sections keep the research defaults for a Clawdy skill.
        #expect(skill.planSystemPrompt == ClawdySkill.builtInResearch.planSystemPrompt)
        #expect(skill.codexExecuteTemplate == "do it {{task}}")
    }

    @Test func harnessSkillReadsOnlyRoutingFieldsAndAddsTheSkillTool() throws {
        let skill = try #require(ClawdySkillFile.parseHarnessSkill(markdown: harnessSkillMarkdown, id: "pdf"))
        #expect(skill.kind == .harness)
        #expect(skill.tag == "SKILL:pdf")
        #expect(skill.directiveMarker == "[SKILL:pdf]")
        #expect(skill.description.hasPrefix("Fills, reads and summarizes PDF"))
        #expect(skill.tools == ["Skill", "Read", "Bash(python:*)"])
        #expect(skill.deliverable == .none)
        #expect(skill.planPhase == false)
        #expect(skill.executeMessageTemplate.contains("`{{skill}}` skill"))
        // No allowed-tools → the safe default set, never a shell.
        let bare = try #require(ClawdySkillFile.parseHarnessSkill(markdown: "---\nname: x\ndescription: d\n---", id: "x"))
        #expect(bare.tools.first == "Skill")
        #expect(!bare.tools.contains("Bash"))
        // No description → nothing to route on → not offered.
        #expect(ClawdySkillFile.parseHarnessSkill(markdown: "---\nname: x\n---\nbody", id: "x") == nil)
    }

    @Test func rejectsMissingDescriptionInvalidTagsAndReservedMarkers() {
        #expect(throws: ClawdySkillFile.ParseError.missingDescription) {
            try ClawdySkillFile.parseClawdySkill(markdown: "---\nname: x\n---\nbody", id: "x")
        }
        for badTag in ["point", "POINT", "FOLLOWUP", "re search", "9LIVES", "RE-SEARCH"] {
            #expect(throws: ClawdySkillFile.ParseError.invalidTag(badTag)) {
                try ClawdySkillFile.parseClawdySkill(markdown: "---\ndescription: d\nclawdy-tag: \(badTag)\n---\nbody", id: "x")
            }
        }
        #expect(throws: ClawdySkillFile.ParseError.missingFrontmatter) {
            try ClawdySkillFile.parseClawdySkill(markdown: "just a body", id: "x")
        }
        #expect(throws: ClawdySkillFile.ParseError.unsupportedDeliverable("pdf")) {
            try ClawdySkillFile.parseClawdySkill(markdown: "---\ndescription: d\nclawdy-deliverable: pdf\n---\nbody", id: "x")
        }
        #expect(ClawdySkill.derivedTag(fromName: "my cool-skill_2") == "MY_COOL_SKILL_2")
        #expect(ClawdySkill.derivedTag(fromName: "9lives") == "S_9LIVES")
    }

    @Test func templatePlaceholdersRender() {
        let rendered = ClawdySkill.render(
            "{{skill}}: do {{task}} → {{outputPath}} in {{outputDir}}",
            task: "plan kyoto", outputPath: "/runs/1/report.html", outputDir: "/runs/1", skill: "trip"
        )
        #expect(rendered == "trip: do plan kyoto → /runs/1/report.html in /runs/1")
    }
}

// MARK: - Directive + router prompt

struct ClawdySkillDirectiveTests {
    private let trip = try! ClawdySkillFile.parseClawdySkill(markdown: plainClawdySkillMarkdown, id: "trip-planner")
    private let pdf = ClawdySkillFile.parseHarnessSkill(markdown: harnessSkillMarkdown, id: "pdf")!

    @Test func parsesAnyLoadedMarkerAndOnlyAsTheWholeReply() {
        let skills: [ClawdySkill] = [.builtInResearch, trip, pdf]
        #expect(ClawdySkillDirective.parse(from: "[RESEARCH] find photos of aomori", skills: skills)?.skill.id == ClawdySkill.builtInResearchID)
        let routed = ClawdySkillDirective.parse(from: "  [TRIP_PLANNER] plan a 3-day kyoto itinerary.\n", skills: skills)
        #expect(routed?.skill.id == "trip-planner")
        #expect(routed?.taskDescription == "plan a 3-day kyoto itinerary.")
        let harness = ClawdySkillDirective.parse(from: "[SKILL:pdf] summarize the open pdf", skills: skills)
        #expect(harness?.skill.kind == .harness)
        #expect(harness?.taskDescription == "summarize the open pdf")
        #expect(ClawdySkillDirective.parse(from: "[TRIP_PLANNER]", skills: skills)?.taskDescription == nil)
        #expect(ClawdySkillDirective.parse(from: "sure, [TRIP_PLANNER] would fit", skills: skills) == nil)
        #expect(ClawdySkillDirective.parse(from: "[SKILL:unknown] x", skills: skills) == nil)
    }

    @Test func longestMarkerWinsSoAPrefixTagCannotShadowALongerOne() {
        var deep = trip
        deep.id = "deep"; deep.tag = "TRIP_PLANNER_DEEP"
        #expect(ClawdySkillDirective.parse(from: "[TRIP_PLANNER_DEEP] go", skills: [trip, deep])?.skill.id == "deep")
    }

    @Test func prefixSuppressionCoversEveryLoadedMarker() {
        let skills: [ClawdySkill] = [.builtInResearch, trip, pdf]
        for prefix in ["[", "[T", "[TRIP_", "[TRIP_PLANNER]", "[SKILL:", "[SKILL:pdf] sum", "[RESE"] {
            #expect(ClawdySkillDirective.looksLikeDirectivePrefix(prefix, skills: skills) == true, "\(prefix)")
        }
        for notPrefix in ["ah, gotcha.", "[POINT:1,2:x]", "", "   ", "[XYZ] no"] {
            #expect(ClawdySkillDirective.looksLikeDirectivePrefix(notPrefix, skills: skills) == false, "\(notPrefix)")
        }
    }

    @Test func routerPromptListsEverySkillWithItsMarkerAndDescription() {
        let prompt = ClawdySkillRouterPrompt.compose(skills: [.builtInResearch, trip, pdf])
        #expect(prompt.contains("[RESEARCH] — research:"))
        #expect(prompt.contains(ClawdySkill.builtInResearch.description))
        #expect(prompt.contains("[TRIP_PLANNER] — trip-planner:"))
        #expect(prompt.contains("[SKILL:pdf] — pdf:"))
        #expect(prompt.contains("the user's own skills"))
        #expect(prompt.lowercased().contains("pointing question"))
        #expect(prompt.contains("your ENTIRE reply must be exactly one line"))
        // Without harness skills the harness group is absent entirely.
        #expect(!ClawdySkillRouterPrompt.compose(skills: [.builtInResearch]).contains("the user's own skills"))
    }

    /// The real route decision: POINT still wins over everything, research stays
    /// `.newResearch`, and any other skill's marker becomes `.runSkill`.
    @MainActor @Test func warmReplyRouteRunsSkills() {
        let skills: [ClawdySkill] = [.builtInResearch, trip, pdf]
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[TRIP_PLANNER] plan kyoto", isResearchSessionFocused: false, skills: skills)
                == .runSkill(trip, task: "plan kyoto"))
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[SKILL:pdf] summarize it", isResearchSessionFocused: true, skills: skills)
                == .runSkill(pdf, task: "summarize it"))
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[RESEARCH] find hotels", isResearchSessionFocused: false, skills: skills)
                == .newResearch(task: "find hotels"))
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[TRIP_PLANNER] plan kyoto [POINT:1,1:x]", isResearchSessionFocused: true, skills: skills)
                == .speakOrPoint)
        // A skill that ISN'T loaded this turn is never honored.
        #expect(CompanionManager.routeWarmReply(fullResponseText: "[SKILL:pdf] x", isResearchSessionFocused: false, skills: [.builtInResearch])
                == .speakOrPoint)
    }
}

// MARK: - Store

struct ClawdySkillStoreTests {
    @Test func installsDefaultsOnceAndLoadsBuiltInResearchFromDisk() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClawdySkillStore(clawdySkillsDirectory: directory)

        store.installDefaultsIfMissing()
        let researchFile = store.clawdySkillFileURL(id: ClawdySkill.builtInResearchID)
        #expect(FileManager.default.fileExists(atPath: researchFile.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("README.md").path))
        #expect(store.loadSkills() == [.builtInResearch], "the shipped file loads as exactly the built-in skill")

        // The user's edits survive a second install (never overwritten).
        try "---\ndescription: edited\nclawdy-tag: RESEARCH\n---\n## Execute message\nedited {{outputPath}}".write(to: researchFile, atomically: true, encoding: .utf8)
        store.installDefaultsIfMissing()
        let loaded = store.loadSkills()
        #expect(loaded.count == 1)
        #expect(loaded[0].description == "edited")
        #expect(loaded[0].executeMessageTemplate == "edited {{outputPath}}")
        #expect(loaded[0].planSystemPrompt == ClawdySkill.builtInResearch.planSystemPrompt)
    }

    @Test func withNoFilesAtAllTheBuiltInResearchSkillIsStillThere() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClawdySkillStore(clawdySkillsDirectory: directory.appendingPathComponent("missing"))
        #expect(store.loadSkills(harnessSkillsDirectory: directory.appendingPathComponent("also-missing")) == [.builtInResearch])
    }

    @Test func loadsClawdyAndHarnessSkillsSkipsMalformedOnesAndDuplicateTags() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clawdyDirectory = directory.appendingPathComponent("clawdy")
        let harnessDirectory = directory.appendingPathComponent("harness")
        let store = ClawdySkillStore(clawdySkillsDirectory: clawdyDirectory)
        try writeSkill(plainClawdySkillMarkdown, id: "trip-planner", in: clawdyDirectory)
        try writeSkill("not a skill at all", id: "broken", in: clawdyDirectory)
        try writeSkill(plainClawdySkillMarkdown.replacingOccurrences(of: "name: trip-planner", with: "name: dupe\nclawdy-tag: RESEARCH"), id: "zz-dupe", in: clawdyDirectory)
        // A malformed research/SKILL.md must not take research away.
        try writeSkill("---\nname: research\n---\nno description", id: ClawdySkill.builtInResearchID, in: clawdyDirectory)
        try writeSkill(harnessSkillMarkdown, id: "pdf", in: harnessDirectory)
        try writeSkill("---\nname: nodesc\n---\nbody", id: "nodesc", in: harnessDirectory)

        let withoutHarness = store.loadSkills()
        #expect(withoutHarness.map(\.id) == [ClawdySkill.builtInResearchID, "trip-planner"])
        #expect(withoutHarness[0] == .builtInResearch)

        let withHarness = store.loadSkills(harnessSkillsDirectory: harnessDirectory)
        #expect(withHarness.map(\.id) == [ClawdySkill.builtInResearchID, "trip-planner", "pdf"])
        #expect(withHarness[2].kind == .harness)
        #expect(withHarness[2].tag == "SKILL:pdf")
    }

    @Test func harnessDirectoryFollowsTheEngine() {
        #expect(ClawdySkillStore.harnessSkillsDirectory(for: .claudeCode, homeDirectoryPath: "/Users/x").path == "/Users/x/.claude/skills")
        #expect(ClawdySkillStore.harnessSkillsDirectory(for: .codex, homeDirectoryPath: "/Users/x").path == "/Users/x/.codex/skills")
    }
}

// MARK: - Engines run the skill

@MainActor
struct ClawdySkillEngineTests {
    private let trip = try! ClawdySkillFile.parseClawdySkill(
        markdown: plainClawdySkillMarkdown.replacingOccurrences(of: "name: trip-planner", with: "name: trip-planner\nallowed-tools: WebSearch, Write\nclawdy-max-budget-usd: 1\nclawdy-execute-timeout-seconds: 42\nclawdy-deliverable-file: trip.html"),
        id: "trip-planner"
    )

    @Test func claudeExecuteArgumentsUseTheSkillsToolAllowlistAndCanStartAFreshSession() {
        let resumed = ResearchArguments.makeExecuteArguments(
            sessionID: "s", outputDirectoryPath: "/out", maxBudgetUSD: 1, userMessage: "m", systemPrompt: "p",
            useClaudeCustomizations: true, allowedTools: trip.tools
        )
        let toolsIndex = resumed.firstIndex(of: "--allowedTools")!
        #expect(Array(resumed[(toolsIndex + 1)...(toolsIndex + 2)]) == ["WebSearch", "Write"])
        #expect(!resumed.contains("WebFetch"))
        #expect(resumed.contains("--resume"))

        let fresh = ResearchArguments.makeExecuteArguments(
            sessionID: "s", outputDirectoryPath: "/out", maxBudgetUSD: 1, userMessage: "m", systemPrompt: "p",
            useClaudeCustomizations: true, allowedTools: trip.tools, resumesExistingSession: false
        )
        #expect(fresh.contains("--session-id") && !fresh.contains("--resume"))
    }

    @Test func enginesAdoptASkillButKeepInjectedKnobsForBuiltInResearch() {
        let claude = ClaudeResearchEngine(binaryPath: "/bin/true", executePhaseTimeoutSeconds: 7, maxBudgetUSD: 9)
        claude.adoptSkill(.builtInResearch)
        #expect(claude.skill == .builtInResearch)
        #expect(claude.supportsPlanPhase == true)
        claude.adoptSkill(trip)
        #expect(claude.skill.deliverableFileName == "trip.html")
        #expect(claude.skill.tools == ["WebSearch", "Write"])

        let pdf = ClawdySkillFile.parseHarnessSkill(markdown: harnessSkillMarkdown, id: "pdf")!
        claude.adoptSkill(pdf)
        #expect(claude.supportsPlanPhase == false, "a harness skill has no plan phase")

        let codex = CodexResearchEngine(binaryPath: "/bin/true", executePhaseTimeoutSeconds: 7)
        codex.adoptSkill(trip)
        #expect(codex.skill.tag == "TRIP_PLANNER")
    }

    /// A plan-less skill: the plan phase launches NOTHING and reports ready; the execute
    /// phase STARTS the session under the pre-minted id. With no deliverable, the run
    /// returns the output directory and exposes the final text for TTS.
    @Test func planLessNoDeliverableSkillRunsOneFreshExecuteAndExposesTheSpokenResult() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A fake `claude` that records its args and answers like the real stream.
        let binary = directory.appendingPathComponent("claude").path
        let argsFile = directory.appendingPathComponent("args.txt").path
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsFile)"
        /bin/echo '{"type":"system","subtype":"init","session_id":"sess-x"}'
        /bin/echo '{"type":"result","result":"i summarized the pdf: three pages about lobsters.","is_error":false}'
        """.write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)

        let engine = ClaudeResearchEngine(binaryPath: binary, homeDirectoryPath: directory.path)
        engine.adoptSkill(ClawdySkillFile.parseHarnessSkill(markdown: harnessSkillMarkdown, id: "pdf")!)
        let outputDirectory = directory.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let plan = try await engine.runPlanPhase(task: "summarize the pdf", sessionID: "sess-x", outputDirectory: outputDirectory, onProgress: { _ in })
        #expect(plan.outcome == .readyToExecute)
        #expect(!FileManager.default.fileExists(atPath: argsFile), "the plan phase must not launch a process for a plan-less skill")

        let result = try await engine.runExecutePhase(sessionID: "sess-x", outputDirectory: outputDirectory, clarificationAnswers: nil, onProgress: { _ in })
        #expect(result == outputDirectory)
        #expect(engine.lastExecuteSpokenResult == "i summarized the pdf: three pages about lobsters.")
        let arguments = try String(contentsOfFile: argsFile, encoding: .utf8).components(separatedBy: "\n")
        #expect(arguments.contains("--session-id") && !arguments.contains("--resume"))
        let message = arguments[arguments.firstIndex(of: "-p")! + 1]
        #expect(message.contains("use your `pdf` skill to do this: summarize the pdf"))
        #expect(arguments.contains("Skill"))
    }

    @Test func composersRenderTheSkillTemplateWithThePath() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/out/trip.html",
            clarificationAnswers: "three days",
            template: ClawdySkill.render(trip.executeMessageTemplate, task: "kyoto", outputPath: "/out/trip.html", outputDir: "/out")
        )
        #expect(message == "three days\n\nplan the trip kyoto and write ONE self-contained HTML page to /out/trip.html in /out.")
        // The default (no template) is still the built-in research text.
        let defaultMessage = ClaudeResearchEngine.composeExecuteUserMessage(outputFileAbsolutePath: "/out/report.html", clarificationAnswers: nil)
        #expect(defaultMessage == ClawdySkill.render(ClawdySkill.builtInResearch.executeMessageTemplate, task: "", outputPath: "/out/report.html", outputDir: "/out"))
    }

    @Test func manifestRecordsTheSkillID() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchManifestStore(fileURL: directory.appendingPathComponent("manifest.json"), dateProvider: { Date(timeIntervalSince1970: 0) })
        store.recordResearchSessionStarted(sessionId: "a", title: "t", task: "k", workingDir: "/w", transcriptPath: "", engineKind: .claudeCode, skillID: "pdf")
        store.recordResearchSessionStarted(sessionId: "b", title: "t", task: "k", workingDir: "/w", transcriptPath: "")
        let entries = store.loadSessions()
        #expect(entries.first { $0.sessionId == "a" }?.skillID == "pdf")
        #expect(entries.first { $0.sessionId == "b" }?.skillID == ClawdySkill.builtInResearchID)
    }

    @Test func overlayReportsADoneRunWithoutAPageAsDoneNotViewResults() {
        var state = ResearchOverlayState()
        state.markCompleted(hasDeliverable: false)
        #expect(state.statusLine == ResearchStatusLine.skillDone)
        var withPage = ResearchOverlayState()
        withPage.markCompleted()
        #expect(withPage.statusLine == ResearchStatusLine.viewResults)
    }
}
