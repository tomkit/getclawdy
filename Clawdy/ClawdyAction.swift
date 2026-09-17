//
//  ClawdyAction.swift
//  Clawdy
//
//  The CODABLE, USER-EXTENSIBLE definition of a Clawdy ACTION: a longer-running job the
//  warm voice agent (the ROUTER) can hand off to a separate, dedicated agent process
//  instead of answering inline — research is the built-in one. An action bundles:
//
//    • how the router recognizes it (`tag` → the `[TAG]` directive marker, plus the
//      `whenToRoute` guidance + examples spliced into the warm system prompt), and
//    • how the dedicated agent runs it (plan/execute/follow-up prompts for `claude`,
//      the Codex stdin prompts, the tool allowlist, the spend cap, the timeout, and the
//      deliverable it produces).
//
//  Users TEACH Clawdy new actions (or retune the built-in one) by editing files in the
//  Clawdy dotfiles directory — `~/.clawdy/actions/<name>/ACTION.md` — see
//  `ClawdyActionFile` for the on-disk format and `ClawdyActionStore` for loading. The
//  built-in `research` action below is the single source of truth for today's research
//  prompts: `ClaudeResearchEngine.planSystemPrompt` & co. read from it, and the shipped
//  `~/.clawdy/actions/research/ACTION.md` is rendered from it, so all three stay identical.
//
//  Prompt TEMPLATES may use these placeholders, substituted per run by `render`:
//    {{task}}        the one-line task the router extracted from the user's words
//    {{outputPath}}  the ABSOLUTE path of the deliverable file (e.g. …/report.html)
//    {{outputDir}}   the ABSOLUTE per-run output directory
//

import Foundation

struct ClawdyAction: Codable, Equatable {
    /// What the action produces. v1 supports only a self-contained HTML page; the field
    /// is reserved so a future "no deliverable" action can be added without a format break.
    enum DeliverableKind: String, Codable, Equatable {
        case html
    }

    /// Stable identifier — the action's directory name under `~/.clawdy/actions/`.
    var id: String
    /// Human-readable name (shown in logs / future UI).
    var name: String
    /// The router directive marker WITHOUT brackets, e.g. `RESEARCH` → `[RESEARCH]`.
    /// Uppercase letters, digits and underscores only; `POINT` and `FOLLOWUP` are reserved.
    var tag: String
    /// One-line summary of what the action does (shown to the router).
    var description: String
    /// Routing guidance for the warm agent: WHEN to hand a spoken request to this action,
    /// with examples of the exact `[TAG] task` line to emit.
    var whenToRoute: String
    /// The `claude --allowedTools` allowlist for the execute + follow-up phases.
    var tools: [String]
    /// The `--max-budget-usd` cap for each tool-using `claude` phase.
    var maxBudgetUSD: Double
    /// Whether to run the PLAN/CLARIFY phase first (Claude only; Codex plans inline).
    var planPhase: Bool
    /// Wall-clock cap on the execute phase.
    var executeTimeoutSeconds: TimeInterval
    /// What the run produces.
    var deliverable: DeliverableKind
    /// The deliverable's file name inside the per-run output directory.
    var deliverableFileName: String

    // Claude prompts
    var planSystemPrompt: String
    var executeSystemPrompt: String
    /// The `-p` user message for the execute phase (the channel guaranteed to survive
    /// `--resume`); the user's clarifying answers are prepended by the engine.
    var executeMessageTemplate: String
    var followUpSystemPrompt: String
    /// The `-p` user message for a follow-up turn; the spoken follow-up is prepended.
    var followUpMessageTemplate: String
    // Codex prompts (Codex has no system-prompt flag; everything goes on stdin)
    var codexExecuteTemplate: String
    var codexFollowUpTemplate: String

    /// The directive marker as the router emits it, e.g. `[RESEARCH]`.
    var directiveMarker: String { "[\(tag)]" }

    /// Substitutes the supported placeholders into a prompt template.
    static func render(_ template: String, task: String, outputPath: String, outputDir: String) -> String {
        template
            .replacingOccurrences(of: "{{task}}", with: task)
            .replacingOccurrences(of: "{{outputPath}}", with: outputPath)
            .replacingOccurrences(of: "{{outputDir}}", with: outputDir)
    }

    /// Tags the router can never be taught: they are the app's own protocol markers.
    static let reservedTags: Set<String> = ["POINT", "FOLLOWUP"]

    /// A valid tag is 1+ uppercase ASCII letters/digits/underscores, starting with a letter,
    /// and not one of the reserved protocol markers.
    static func isValidTag(_ tag: String) -> Bool {
        guard let firstScalar = tag.unicodeScalars.first else { return false }
        let uppercaseLetters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let tagCharacters = uppercaseLetters.union(CharacterSet(charactersIn: "0123456789_"))
        guard uppercaseLetters.contains(firstScalar) else { return false }
        let allCharactersAllowed = tag.unicodeScalars.allSatisfy { tagCharacters.contains($0) }
        return allCharactersAllowed && !reservedTags.contains(tag)
    }

    // MARK: - Built-in research action

    static let builtInResearchID = "research"

    /// The one built-in action. Its prompt text is EXACTLY what the research subsystem
    /// shipped with before actions became editable (see the file header).
    static let builtInResearch = ClawdyAction(
        id: builtInResearchID,
        name: "Research",
        tag: "RESEARCH",
        description: "deep, multi-source web research that ends in ONE self-contained HTML page opened on the user's screen.",
        whenToRoute: """
        so these ROUTE, because each needs web gathering and/or a compiled result: "find photos of aomori", "find the best noise-cancelling headphones", "gather everything on the tohoku earthquake", "put together a page of ramen spots in tokyo", "compare the top three standing desks and build a page". and these you ANSWER yourself, because each is immediately answerable in a sentence or two: "what's the capital of japan", "what does this error mean", "how do i center a div", "where do i click to submit". notice "find/gather/compile X" that lives out on the web is research even when the user never literally says "build a page" — the deliverable is implied.

        examples:
        - user says "find photos of aomori": [RESEARCH] find photos of aomori and build a gallery page of them.
        - user says "research the three best standing desks under a thousand dollars and build me a page comparing them": [RESEARCH] research the three best standing desks under $1000 and build a self-contained comparison page.
        """,
        tools: ["WebSearch", "WebFetch", "Write"],
        maxBudgetUSD: 5,
        planPhase: true,
        executeTimeoutSeconds: 600,
        deliverable: .html,
        deliverableFileName: "report.html",
        planSystemPrompt: """
        you are clawdy's research agent, in its PLANNING phase. the user asked for something that needs deep, multi-source web research that ends in a single self-contained HTML page. you are in plan mode and cannot run tools yet.

        decide whether you genuinely need clarifying information to produce a great result. if and only if essential details are missing, ask at MOST 3 short, specific clarifying questions, then stop and end your turn. if the request is already clear enough, do NOT ask any questions — instead briefly state the plan you'll execute. never ask more than once. either way, END YOUR TURN NOW — do not wait on anything.

        CRITICAL EXECUTION MODEL: in the upcoming execution phase you will do ALL of the research YOURSELF, inline, in a single one-shot turn, using ONLY the WebSearch, WebFetch and Write tools. there is NO background job system here and NO notification will ever arrive. so DO NOT plan to invoke, launch, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin — those never resume in this mode and would hang forever. your plan must be to perform the searches directly and write the HTML yourself. do NOT end your turn saying you'll wait to be notified about a background job.
        """,
        executeSystemPrompt: """
        you are clawdy's research agent, in its EXECUTION phase. research the task thoroughly using WebSearch and WebFetch, then produce ONE self-contained HTML page and Write it to a file named report.html in the working output directory you've been granted.

        DO ALL OF THIS YOURSELF, INLINE, IN THIS ONE TURN, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run with NO background job system and NO notification will ever arrive — anything you hand off never comes back. so DO NOT invoke, launch, spawn, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified that a background job finished. if you notice yourself about to launch a background workflow or skill, STOP and instead perform the WebSearch/WebFetch calls directly and Write the HTML now, in this turn.

        the HTML MUST keep all of its OWN code inline so it renders with no local dependencies: inline <style> only, no external stylesheet links, no external script src, no CDN references, no remote fonts. the ONE exception is images: when the task is about photos or images, you SHOULD embed the real images you found via <img src="https://..."> pointing at the actual remote image URLs you discovered while researching — that's how the user sees them. use genuine image URLs from your research, not placeholders, and NEVER fabricate or guess an image URL. prefer DIRECT image-file URLs (ones ending in .jpg/.jpeg/.png/.webp/.gif or that clearly serve the raw image file) taken straight from your search results or well-known sources. prefer canonical, original-resolution image URLs and do NOT guess or construct sized thumbnail paths (e.g. never fabricate Wikimedia /thumb/.../NNNpx- variants). do NOT WebFetch, open, or otherwise verify image URLs before embedding them — WebFetch on a raw image binary just fails and wastes a tool call; embed the image URL directly. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. reserve WebFetch for reading actual page/article content, not images. everything else stays inline. make it clean, readable, and well organized with clear headings. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents like rules or key highlights, and optionally a very light red background tint — keep it tasteful and restrained, keep body text high-contrast and readable, and never tint photos/images or force red where it hurts legibility. do not write any file other than report.html. when you're done, briefly confirm in your final message.
        """,
        executeMessageTemplate: """
        proceed with the research now, yourself, inline, in THIS one turn, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run: there is NO background job system and NO notification will ever arrive, so DO NOT invoke, launch, or delegate to any background task, skill, workflow, agent, sub-agent, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified about a background job — if you catch yourself about to launch one, instead run the searches directly and write the HTML now. use WebSearch and WebFetch to research the task thoroughly, then write ONE self-contained HTML page to the absolute path {{outputPath}}. the page MUST keep all of its OWN code inline: inline <style> only, no external stylesheet links, no external script src, no CDN or remote font references. the ONE exception is images — when the task is about photos or images, embed the real images you found via <img src="https://..."> using the actual remote image URLs you discovered while researching (genuine URLs, not placeholders), so the user can actually see them. NEVER fabricate or guess an image URL: prefer DIRECT image-file URLs (ending in .jpg/.jpeg/.png/.webp/.gif or that clearly serve the raw image) taken straight from your search results or well-known sources. prefer canonical, original-resolution image URLs and do NOT guess or construct sized thumbnail paths (e.g. never fabricate Wikimedia /thumb/.../NNNpx- variants). do NOT WebFetch, open, or otherwise verify image URLs before embedding them — WebFetch on a raw image binary just fails and wastes a tool call; embed the image URL directly. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. reserve WebFetch for reading actual page/article content, not images. everything else stays inline. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents, and optionally a very light red background tint — keep it tasteful, keep body text high-contrast and readable, and never tint photos/images or force red where it hurts legibility. do not write any file other than that one report.html. when you're done, briefly confirm.
        """,
        followUpSystemPrompt: """
        you are clawdy's research agent, continuing a FINISHED research session by voice. the self-contained report.html you already produced is in your context. the user is asking a spoken follow-up. only modify the page if the user explicitly asks you to change it; otherwise just answer their question and write nothing. if you do edit, rewrite the SAME report.html in place (inline <style> only, no external script src, no CDN or remote font references; a remote <img src="https://…"> is allowed for image tasks). end your turn with a concise 1-2 sentence spoken answer or confirmation suitable to read aloud — never read long tool logs or file contents aloud.

        DO ALL OF THIS YOURSELF, INLINE, IN THIS ONE TURN, using ONLY the WebSearch, WebFetch and Write tools. this is a one-shot run with NO background job system and NO notification will ever arrive — anything you hand off never comes back. so DO NOT invoke, launch, spawn, or delegate to any background task, skill, workflow, agent, sub-agent, task queue, or the deep-research skill / Workflow plugin, and DO NOT end your turn waiting to be notified that a background job finished. if you notice yourself about to launch a background workflow or skill, STOP and instead perform the WebSearch/WebFetch calls directly and Write the HTML now, in this turn.
        """,
        followUpMessageTemplate: """
        the research page you produced is at {{outputPath}}. only modify the page if I asked you to change it; otherwise just answer my question and write nothing. if you DO change it, rewrite that same report.html in place. keep it short: end with a 1-2 sentence spoken summary/answer suitable to read aloud, and don't read long tool output or file contents aloud.
        """,
        codexExecuteTemplate: """
        you are clawdy's research agent. research the task thoroughly using web search NOW, in THIS one turn, yourself — do the searches and reading directly, do not defer or wait to be notified about any background job. then write ONE self-contained HTML page to the absolute path {{outputPath}}. the page MUST keep all of its OWN code inline so it renders with no local dependencies: inline <style> only, no external stylesheet links, no external script src, no CDN or remote font references. the ONE exception is images — when the task is about photos or images, embed the real images you found via <img src="https://..."> using the actual remote image URLs you discovered while researching (genuine URLs, not placeholders), so the user can actually see them. NEVER fabricate or guess an image URL. prefer canonical, original-resolution image URLs and do NOT guess or construct sized thumbnail paths (e.g. never fabricate Wikimedia /thumb/.../NNNpx- variants). do NOT open, fetch, or otherwise verify image URLs before embedding them — that just wastes a tool call; embed the image URL directly from your search results. broken or unreachable images are handled automatically after the page is written (they're swapped for a clean placeholder), so never spend tool calls checking images. give the page a subtle OpenClaw red brand accent (#E5342B): use it for headings, links, and small primary accents, and optionally a very light red background tint — keep it tasteful, keep body text high-contrast and readable, and never tint photos/images. do not write any file other than that one report.html. when you're done, briefly confirm in your final message.
        """,
        codexFollowUpTemplate: """
        the research page you produced is at {{outputPath}}. only modify the page if I asked you to change it; otherwise just answer my question and write nothing. if you DO change it, rewrite that same report.html in place (inline <style> only, no external script src, no CDN or remote font references; a remote <img src="https://…"> is allowed for image tasks). do the work inline in THIS turn — do not defer to any background job. keep it short: end with a 1-2 sentence spoken summary/answer suitable to read aloud, and don't read long tool output or file contents aloud.
        """
    )
}
