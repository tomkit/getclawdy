//
//  ResearchRoutingTests.swift
//  ClawdyTests
//
//  Pure, headless tests for the research-mode routing/parsing logic:
//    1. [RESEARCH] directive parsing + the TTS-suppression prefix check (routing).
//    2. The plan-mode "needs input vs proceed" decision.
//    3. The research stream → progress event → rotating status line mapping.
//
//  All side-effect-free: no process is launched.
//

import Testing
import Foundation
@testable import Clawdy

// MARK: - 1. [RESEARCH] directive parsing / routing

struct ResearchDirectiveTests {

    @Test func parsesAResearchDirectiveAtTheStartOfTheReply() {
        let result = ResearchDirective.parse(from: "[RESEARCH] compare the three best standing desks under $1000")
        #expect(result.isResearchRequest == true)
        #expect(result.taskDescription == "compare the three best standing desks under $1000")
    }

    @Test func toleratesLeadingAndTrailingWhitespaceAroundTheDirective() {
        let result = ResearchDirective.parse(from: "  \n [RESEARCH]   dig into the history of the metric system   \n")
        #expect(result.isResearchRequest == true)
        #expect(result.taskDescription == "dig into the history of the metric system")
    }

    @Test func aNormalSpokenAnswerIsNotRoutedToResearch() {
        // A quick voice answer with a POINT tag must NOT be treated as research.
        let reply = "you'll find it in the toolbar up top. [POINT:1100,42:color inspector]"
        let result = ResearchDirective.parse(from: reply)
        #expect(result.isResearchRequest == false)
        #expect(result.taskDescription == nil)
    }

    @Test func aReplyThatMerelyMentionsTheMarkerMidSentenceIsNotARoute() {
        // The router emits the marker as the ENTIRE reply; a mid-sentence mention is
        // a normal answer, not a route.
        let reply = "i could kick off a [RESEARCH] run but let's just talk it through first."
        let result = ResearchDirective.parse(from: reply)
        #expect(result.isResearchRequest == false)
    }

    @Test func aMarkerWithNoTaskTextStillRoutesButHasNoDescription() {
        let result = ResearchDirective.parse(from: "[RESEARCH]")
        #expect(result.isResearchRequest == true)
        #expect(result.taskDescription == nil)
    }

    // The user-reported scenario: a photo-gathering ask, once the tuned router emits
    // the marker for it, must route (not be spoken as a quick answer). The parser is
    // the only deterministically-testable seam — the live model's routing decision is
    // verified empirically against the real CLI, not here.
    @Test func aPhotoGatheringDirectiveRoutesToResearch() {
        let result = ResearchDirective.parse(from: "[RESEARCH] find photos of aomori and build a gallery page of them.")
        #expect(result.isResearchRequest == true)
        #expect(result.taskDescription == "find photos of aomori and build a gallery page of them.")
    }

    // The counterpart guard: an on-screen POINTING answer ("where do i click…") must
    // stay a quick spoken answer and never route, even though the router considered it.
    @Test func anOnScreenPointingAnswerDoesNotRoute() {
        let reply = "hit the blue submit button at the bottom of the form. [POINT:640,720:submit button]"
        let result = ResearchDirective.parse(from: reply)
        #expect(result.isResearchRequest == false)
        #expect(result.taskDescription == nil)
    }

    // TTS-suppression prefix: while the streamed reply could still BECOME the marker,
    // the voice path must not speak it.

    @Test func suppressesTTSWhileTheStreamedTextCouldStillBecomeTheMarker() {
        #expect(ResearchDirective.looksLikeResearchPrefix("[") == true)
        #expect(ResearchDirective.looksLikeResearchPrefix("[RESE") == true)
        #expect(ResearchDirective.looksLikeResearchPrefix("[RESEARCH]") == true)
        #expect(ResearchDirective.looksLikeResearchPrefix("[RESEARCH] go research the web") == true)
    }

    @Test func doesNotSuppressTTSForOrdinarySpokenAnswers() {
        #expect(ResearchDirective.looksLikeResearchPrefix("ah, gotcha.") == false)
        #expect(ResearchDirective.looksLikeResearchPrefix("html stands for hypertext markup language") == false)
        // An empty buffer isn't a directive prefix.
        #expect(ResearchDirective.looksLikeResearchPrefix("   ") == false)
    }
}

// MARK: - 2. Plan-mode: needs input vs proceed

struct ResearchPlanAnalyzerTests {

    @Test func needsClarificationWhenPlanTextAsksQuestionsAndNoToolsRan() {
        let outcome = ResearchPlanAnalyzer.analyze(
            planResultText: "a couple quick questions: what's your budget? and which region?",
            toolUseCount: 0
        )
        #expect(outcome == .needsClarification(questions: "a couple quick questions: what's your budget? and which region?"))
    }

    @Test func proceedsWhenPlanTextHasNoQuestions() {
        let outcome = ResearchPlanAnalyzer.analyze(
            planResultText: "here's the plan: i'll search for X, compare the top three, then write the page.",
            toolUseCount: 0
        )
        #expect(outcome == .readyToExecute)
    }

    @Test func proceedsWheneverThePlanAgentAlreadyRanTools() {
        // If the agent began acting (ran a tool), don't interrupt it for input even
        // if its text happens to contain a question mark.
        let outcome = ResearchPlanAnalyzer.analyze(
            planResultText: "should be straightforward? starting now.",
            toolUseCount: 2
        )
        #expect(outcome == .readyToExecute)
    }

    @Test func emptyPlanTextProceeds() {
        #expect(ResearchPlanAnalyzer.analyze(planResultText: "", toolUseCount: 0) == .readyToExecute)
        #expect(ResearchPlanAnalyzer.textAsksQuestions("") == false)
        #expect(ResearchPlanAnalyzer.textAsksQuestions("no questions here.") == false)
        #expect(ResearchPlanAnalyzer.textAsksQuestions("really?") == true)
    }
}

// MARK: - 3. Stream parsing → progress event → status line

struct ResearchStreamMappingTests {

    @Test func parsesTheSessionInitLine() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"sonnet"}"#
        #expect(ResearchStreamParser.parse(line: line) == .sessionStarted(sessionID: "abc-123"))
    }

    @Test func mapsWebSearchToolUseToASearchingProgressEvent() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"best standing desks 2026"}}]}}"#
        #expect(ResearchStreamParser.parse(line: line) == .progress(.searchingWeb(query: "best standing desks 2026")))
    }

    @Test func mapsWebFetchToolUseToAReadingProgressEvent() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://www.example.com/review"}}]}}"#
        #expect(ResearchStreamParser.parse(line: line) == .progress(.readingPage(url: "https://www.example.com/review")))
    }

    @Test func mapsWriteToolUseToWritingThePage() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/x/report.html","content":"<html>"}}]}}"#
        #expect(ResearchStreamParser.parse(line: line) == .progress(.writingPage))
    }

    @Test func parsesAssistantTextAndTerminalResult() {
        let textLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"here's my plan"}]}}"#
        #expect(ResearchStreamParser.parse(line: textLine) == .assistantText("here's my plan"))

        let resultLine = #"{"type":"result","result":"done","is_error":false,"session_id":"abc"}"#
        #expect(ResearchStreamParser.parse(line: resultLine) == .result(text: "done", isError: false))
    }

    @Test func ignoresBlankAndUnrelatedLines() {
        #expect(ResearchStreamParser.parse(line: "") == .ignored)
        #expect(ResearchStreamParser.parse(line: "not json") == .ignored)
        let toolResultLine = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        #expect(ResearchStreamParser.parse(line: toolResultLine) == .ignored)
    }

    // Status line mapping (what the user actually sees on the overlay).

    @Test func mapsProgressEventsToRotatingStatusLines() {
        #expect(ResearchStatusLine.text(for: .searchingWeb(query: "marathon record")) == "Searching the web for marathon record…")
        #expect(ResearchStatusLine.text(for: .readingPage(url: "https://www.example.com/a/b")) == "Reading example.com…")
        #expect(ResearchStatusLine.text(for: .writingPage) == "Writing the page…")
        #expect(ResearchStatusLine.text(for: .runningTool(name: "Bash")) == "Running Bash…")
    }

    @Test func searchWithEmptyQueryDegradesGracefully() {
        #expect(ResearchStatusLine.text(for: .searchingWeb(query: "")) == "Searching the web…")
    }

    @Test func displayHostStripsSchemeAndWWWAndPath() {
        #expect(ResearchStatusLine.displayHost(fromURLString: "https://www.nytimes.com/2026/article") == "nytimes.com")
        #expect(ResearchStatusLine.displayHost(fromURLString: "http://example.org") == "example.org")
        #expect(ResearchStatusLine.displayHost(fromURLString: "") == "")
    }
}

// MARK: - Argument vector construction (exact command lines)

struct ResearchArgumentsTests {

    @Test func planArgumentsUsePlanModeAndDoNotEnableTools() {
        // Default setting: customizations load, so `--safe-mode` is OMITTED on the
        // research path too (isolation is opt-in via the toggle; see the dedicated
        // customization-toggle tests below).
        let args = ResearchArguments.makePlanArguments(task: "research X", sessionID: "sess-7", systemPrompt: "sys", useClaudeCustomizations: true)
        #expect(args.contains("--permission-mode"))
        #expect(args.contains("plan"))
        #expect(args.contains("--safe-mode") == false)
        // The plan phase must NOT carry a tool allowlist — plan mode runs no tools.
        #expect(args.contains("--allowedTools") == false)
        // Never `--bare` (that would force API-key auth instead of the subscription).
        #expect(args.contains("--bare") == false)
        // Task is the print-mode prompt.
        let printIndex = args.firstIndex(of: "-p")
        #expect(printIndex != nil)
        #expect(args[printIndex! + 1] == "research X")
    }

    /// The plan phase must PRE-ASSIGN the pre-minted id via `--session-id`, and the
    /// execute phase must continue that SAME id via `--resume`, so both phases append
    /// to the one `<sessionId>.jsonl` transcript in the shared working directory.
    @Test func sessionIDIsPreAssignedOnPlanAndResumedOnExecute() {
        let sessionID = "44f7cc5d-16b2-4efd-b41a-5aba67c976d3"
        let planArgs = ResearchArguments.makePlanArguments(task: "research X", sessionID: sessionID, systemPrompt: "sys", useClaudeCustomizations: true)
        let planSessionIndex = planArgs.firstIndex(of: "--session-id")
        #expect(planSessionIndex != nil)
        #expect(planArgs[planSessionIndex! + 1] == sessionID)
        // Plan pre-assigns, it does not resume.
        #expect(planArgs.contains("--resume") == false)

        let executeArgs = ResearchArguments.makeExecuteArguments(
            sessionID: sessionID,
            outputDirectoryPath: "/tmp/run",
            maxBudgetUSD: 5,
            userMessage: "proceed",
            systemPrompt: "sys",
            useClaudeCustomizations: true
        )
        let resumeIndex = executeArgs.firstIndex(of: "--resume")
        #expect(resumeIndex != nil)
        #expect(executeArgs[resumeIndex! + 1] == sessionID)
    }

    @Test func executeArgumentsResumeWithNarrowAllowlistAndScopedDirAndBudget() {
        let args = ResearchArguments.makeExecuteArguments(
            sessionID: "sess-9",
            outputDirectoryPath: "/tmp/run",
            maxBudgetUSD: 5,
            userMessage: "proceed",
            systemPrompt: "sys",
            useClaudeCustomizations: true
        )
        #expect(args.contains("--resume"))
        let resumeIndex = args.firstIndex(of: "--resume")!
        #expect(args[resumeIndex + 1] == "sess-9")

        #expect(args.contains("acceptEdits"))
        // The exact narrow allowlist — and nothing broader.
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("WebSearch"))
        #expect(args.contains("WebFetch"))
        #expect(args.contains("Write"))
        #expect(args.contains("bypassPermissions") == false)
        #expect(args.contains("--dangerously-skip-permissions") == false)

        // Scoped write dir + cost cap.
        let addDirIndex = args.firstIndex(of: "--add-dir")!
        #expect(args[addDirIndex + 1] == "/tmp/run")
        let budgetIndex = args.firstIndex(of: "--max-budget-usd")!
        #expect(args[budgetIndex + 1] == "5")
        #expect(args.contains("--bare") == false)
    }

    @Test func executeUserMessageFoldsInClarificationAnswers() {
        let withAnswers = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: "budget is $800, US region"
        )
        #expect(withAnswers.contains("budget is $800, US region"))
        #expect(withAnswers.contains("report.html"))

        let withoutAnswers = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: nil
        )
        #expect(withoutAnswers.contains("report.html"))
    }

    // Blocking #1 regression: the execute-phase instructions (run tools now; ONE
    // self-contained page, inline-only/no CDN; report.html) MUST ride in the `-p`
    // user message — the channel guaranteed to survive `--resume` — not rely on
    // `--append-system-prompt`. Fails before the fix (old message only said
    // "proceed… write report.html", no tool/self-containment instructions).
    @Test func executeUserMessageCarriesToolAndSelfContainmentInstructionsForResume() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run-xyz/report.html",
            clarificationAnswers: nil
        )
        // Run-the-tools-now instruction survives resume via -p.
        #expect(message.contains("WebSearch"))
        #expect(message.contains("WebFetch"))
        // Self-containment constraints survive resume via -p.
        #expect(message.lowercased().contains("self-contained"))
        #expect(message.contains("inline <style>"))
        #expect(message.lowercased().contains("no cdn") || message.lowercased().contains("no external"))
        // Report filename present.
        #expect(message.contains("report.html"))
    }

    // Photo/image output: an image-gathering research result is useless if the page
    // can't show the photos it found. The execute message MUST permit embedding real
    // remote images via <img src="https://…">. Fails before the fix (old message said
    // the page renders "offline" with "everything inline" — no remote-image exception).
    @Test func executeUserMessageAllowsEmbeddingRemoteImages() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: nil
        )
        // The remote <img> allowance is explicit.
        #expect(message.contains("<img src=\"https://"))
        // But the no-remote-script / no-CDN-JS / inline-<style> security rules stay.
        #expect(message.contains("inline <style>"))
        #expect(message.lowercased().contains("no external script src"))
        #expect(message.lowercased().contains("no cdn"))
    }

    // Same allowance must live in the execute SYSTEM prompt too (defense in depth):
    // remote <img> permitted, but scripts/CDN/inline-style rules unchanged.
    @Test func executeSystemPromptAllowsRemoteImagesButKeepsScriptRules() {
        let prompt = ClaudeResearchEngine.executeSystemPrompt.lowercased()
        #expect(prompt.contains("<img src=\"https://"))
        #expect(prompt.contains("no external script src"))
        #expect(prompt.contains("no cdn"))
        #expect(prompt.contains("inline <style>"))
    }

    // HTTP-400 regression: WebFetch against a raw image binary returns HTTP 400, so
    // the old "WebFetch a candidate image URL before embedding it" instruction made
    // every image pre-check a failing round-trip — and it's redundant, since the
    // deterministic post-write ResearchImageValidator already swaps broken images.
    // The execute SYSTEM prompt + user message MUST NOT tell the model to fetch/verify
    // image URLs before embedding them; they MUST tell it to embed directly and that
    // broken images are handled automatically. (WebFetch stays allowed for page content.)
    @Test func executeSystemPromptDoesNotInstructImagePreFetching() {
        let prompt = ClaudeResearchEngine.executeSystemPrompt.lowercased()
        // No pre-embed fetch/verify of image URLs.
        #expect(!prompt.contains("webfetch a candidate image"))
        #expect(!prompt.contains("webfetching them first"))
        #expect(!prompt.contains("confirmed are reachable"))
        // Positive guidance: embed directly, broken images handled automatically.
        #expect(prompt.contains("do not webfetch"))
        #expect(prompt.contains("handled automatically"))
        // WebFetch remains available for actual page/content research.
        #expect(prompt.contains("webfetch"))
    }

    @Test func executeUserMessageDoesNotInstructImagePreFetching() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: nil
        ).lowercased()
        #expect(!message.contains("webfetching them first"))
        #expect(!message.contains("confirmed are reachable"))
        #expect(message.contains("do not webfetch"))
        #expect(message.contains("handled automatically"))
        // WebFetch still permitted for page content.
        #expect(message.contains("webfetch"))
    }

    // Background-delegation guard: the plan-phase `claude -p` runs the user's OWN
    // customizations (no --safe-mode by default), so it can load a deep-research skill
    // / Workflow plugin and LAUNCH IT AS A BACKGROUND TASK — which never resumes in a
    // one-shot `-p` run, so the process hangs the full plan watchdog and produces no
    // report.html. The plan system prompt MUST forbid delegating to any background
    // task/skill/workflow/agent and forbid ending the turn waiting to be notified.
    @Test func planSystemPromptForbidsBackgroundDelegation() {
        let prompt = ClaudeResearchEngine.planSystemPrompt.lowercased()
        #expect(prompt.contains("background"))
        #expect(prompt.contains("workflow"))
        #expect(prompt.contains("deep-research") || prompt.contains("deep research"))
        #expect(prompt.contains("do not") && prompt.contains("delegate"))
        #expect(prompt.contains("notif"))
    }

    // Same guard on the execute SYSTEM prompt (defense in depth): do the research
    // inline with WebSearch/WebFetch/Write only, never launch a background workflow.
    @Test func executeSystemPromptForbidsBackgroundDelegation() {
        let prompt = ClaudeResearchEngine.executeSystemPrompt.lowercased()
        #expect(prompt.contains("background"))
        #expect(prompt.contains("workflow"))
        #expect(prompt.contains("delegate"))
        #expect(prompt.contains("notif"))
        #expect(prompt.contains("inline"))
    }

    // Same guard on the execute USER MESSAGE — the channel guaranteed to survive
    // `--resume` — so the constraint reaches the resumed execute turn even if the
    // append-system-prompt is ever dropped on resume.
    @Test func executeUserMessageForbidsBackgroundDelegation() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/tmp/run/report.html",
            clarificationAnswers: nil
        ).lowercased()
        #expect(message.contains("background"))
        #expect(message.contains("workflow"))
        #expect(message.contains("delegate"))
        #expect(message.contains("notif"))
        #expect(message.contains("inline"))
    }

    // Same guard on the FOLLOW-UP system prompt: a voice (or typed-enqueue) follow-up
    // resumes the finished session and can equally trigger the deep-research skill / a
    // background Workflow and hang the same way. It MUST forbid delegating to any
    // background task/skill/workflow/agent and forbid ending the turn waiting to be
    // notified — do the work inline in this turn.
    @Test func followUpSystemPromptForbidsBackgroundDelegation() {
        let prompt = ClaudeResearchEngine.followUpSystemPrompt.lowercased()
        #expect(prompt.contains("background"))
        #expect(prompt.contains("workflow"))
        #expect(prompt.contains("delegate"))
        #expect(prompt.contains("notif"))
        #expect(prompt.contains("inline"))
    }

    // Blocking #2 regression (message half): the ABSOLUTE output path must be in the
    // -p message so deliverable discovery is unambiguous regardless of CWD. Fails
    // before the fix (old message used the relative "report.html" only).
    @Test func executeUserMessageContainsTheAbsoluteOutputPath() {
        let message = ClaudeResearchEngine.composeExecuteUserMessage(
            outputFileAbsolutePath: "/private/var/folders/abc/clawdy-research/run-1/report.html",
            clarificationAnswers: nil
        )
        #expect(message.contains("/private/var/folders/abc/clawdy-research/run-1/report.html"))
    }
}
