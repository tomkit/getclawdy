//
//  ClawdySkill.swift
//  Clawdy
//
//  The CODABLE definition of a SKILL the warm voice agent (the ROUTER) can hand a spoken
//  request to, running it in a separate, dedicated agent process instead of answering
//  inline. There are two kinds:
//
//    • CLAWDY skills — written for Clawdy's interface (voice in, a page or a spoken result
//      out). They live in the Clawdy dotfiles dir `~/.clawdy/skills/<name>/SKILL.md` and
//      use the SAME SKILL.md format as Claude Code / Codex skills (frontmatter `name`,
//      `description`, `allowed-tools`, markdown body) plus optional `clawdy-*` frontmatter
//      keys for the things only Clawdy needs (the router tag, the deliverable, budget,
//      timeout, plan phase). `research` is the built-in one and is shipped there on first
//      launch so it can be read and edited.
//    • HARNESS skills — the user's ordinary Claude Code (`~/.claude/skills`) or Codex
//      (`~/.codex/skills`) skills, offered to the router as-is. A harness-skill run asks the
//      dedicated `claude`/`codex` process to invoke that skill for the task; the CLI loads
//      the skill itself (the user's setup is on), and the final answer is SPOKEN.
//
//  A skill's `description` is its ROUTING RULE, exactly as it is for Claude Code's own
//  auto-invocation: it tells the router when a spoken request should go to this skill.
//
//  Prompt TEMPLATES may use these placeholders, substituted per run by `render`:
//    {{task}}        the one-line task the router extracted from the user's words
//    {{outputPath}}  the ABSOLUTE path of the deliverable file (e.g. …/report.html)
//    {{outputDir}}   the ABSOLUTE per-run output directory
//    {{skill}}       the skill's name
//

import Foundation

struct ClawdySkill: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        /// A Clawdy-specific skill from `~/.clawdy/skills` (or the built-in research one).
        case clawdy
        /// One of the user's ordinary harness skills (`~/.claude/skills`, `~/.codex/skills`).
        case harness
    }

    /// What a run produces: a self-contained HTML page opened on screen, or nothing on
    /// disk — just a spoken result (the default for harness skills).
    enum DeliverableKind: String, Codable, Equatable {
        case html
        case none
    }

    /// Stable identifier — the skill's directory name.
    var id: String
    /// The skill's `name` (frontmatter), defaulting to the directory name.
    var name: String
    var kind: Kind
    /// The router directive marker WITHOUT brackets: a Clawdy skill's `clawdy-tag` (or its
    /// name upper-cased, e.g. `trip-planner` → `TRIP_PLANNER`); a harness skill's is
    /// `SKILL:<name>`. `POINT` and `FOLLOWUP` are reserved.
    var tag: String
    /// The routing rule: WHEN a spoken request should go to this skill (Claude Code's own
    /// `description` semantics), ideally with examples of the `[TAG] task` line to emit.
    var description: String
    /// The `--allowedTools` allowlist for the dedicated `claude` run (`allowed-tools`).
    var tools: [String]
    var maxBudgetUSD: Double
    /// Whether to run the PLAN/CLARIFY phase first (Claude only; Codex plans inline).
    var planPhase: Bool
    var executeTimeoutSeconds: TimeInterval
    var deliverable: DeliverableKind
    var deliverableFileName: String

    // Claude prompts
    var planSystemPrompt: String
    var executeSystemPrompt: String
    /// The `-p` user message for the execute phase (the channel guaranteed to survive
    /// `--resume`); the user's clarifying answers are prepended by the engine.
    var executeMessageTemplate: String
    var followUpSystemPrompt: String
    var followUpMessageTemplate: String
    // Codex prompts (Codex has no system-prompt flag; everything goes on stdin)
    var codexExecuteTemplate: String
    var codexFollowUpTemplate: String

    /// The directive marker as the router emits it, e.g. `[RESEARCH]` / `[SKILL:pdf]`.
    var directiveMarker: String { "[\(tag)]" }

    /// Substitutes the supported placeholders into a prompt template.
    static func render(_ template: String, task: String, outputPath: String, outputDir: String, skill: String = "") -> String {
        template
            .replacingOccurrences(of: "{{task}}", with: task)
            .replacingOccurrences(of: "{{outputPath}}", with: outputPath)
            .replacingOccurrences(of: "{{outputDir}}", with: outputDir)
            .replacingOccurrences(of: "{{skill}}", with: skill)
    }

    /// Tags the router can never be taught: they are the app's own protocol markers.
    static let reservedTags: Set<String> = ["POINT", "FOLLOWUP"]

    /// A valid Clawdy-skill tag is uppercase ASCII letters/digits/underscores, starting
    /// with a letter, and not a reserved protocol marker. (Harness tags are `SKILL:<name>`.)
    static func isValidTag(_ tag: String) -> Bool {
        guard let firstScalar = tag.unicodeScalars.first else { return false }
        let uppercaseLetters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let tagCharacters = uppercaseLetters.union(CharacterSet(charactersIn: "0123456789_"))
        guard uppercaseLetters.contains(firstScalar) else { return false }
        let allCharactersAllowed = tag.unicodeScalars.allSatisfy { tagCharacters.contains($0) }
        return allCharactersAllowed && !reservedTags.contains(tag)
    }

    /// Derives a tag from a skill name: `trip-planner` → `TRIP_PLANNER`.
    static func derivedTag(fromName name: String) -> String {
        let mapped = name.uppercased().unicodeScalars.map { scalar -> Character in
            let isAllowed = ("A"..."Z").contains(String(scalar)) || ("0"..."9").contains(String(scalar))
            return isAllowed ? Character(scalar) : "_"
        }
        var tag = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let first = tag.first, !("A"..."Z").contains(String(first)) { tag = "S_" + tag }
        return tag.isEmpty ? "SKILL" : tag
    }

    // MARK: - Harness skills

    static let harnessTagPrefix = "SKILL:"

    /// The tools a harness skill run gets when its SKILL.md declares no `allowed-tools`:
    /// enough to read, search the web and write inside the scoped run directory — never a
    /// shell. `Skill` is always added so the model can actually invoke the skill.
    static let defaultHarnessTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "Write", "Edit"]

    /// Builds the definition for one of the user's ordinary harness skills. The harness
    /// loads the skill's own instructions itself; Clawdy only tells the dedicated run to
    /// invoke it for the task and to finish with a short spoken summary.
    static func harness(name: String, description: String, allowedTools: [String]?) -> ClawdySkill {
        var tools = allowedTools ?? defaultHarnessTools
        if !tools.contains("Skill") { tools.insert("Skill", at: 0) }
        return ClawdySkill(
            id: name,
            name: name,
            kind: .harness,
            tag: harnessTagPrefix + name,
            description: description,
            tools: tools,
            maxBudgetUSD: builtInResearch.maxBudgetUSD,
            planPhase: false,
            executeTimeoutSeconds: builtInResearch.executeTimeoutSeconds,
            deliverable: .none,
            deliverableFileName: builtInResearch.deliverableFileName,
            planSystemPrompt: genericPlanSystemPrompt,
            executeSystemPrompt: genericExecuteSystemPrompt,
            executeMessageTemplate: harnessExecuteMessageTemplate,
            followUpSystemPrompt: genericFollowUpSystemPrompt,
            followUpMessageTemplate: genericFollowUpMessageTemplate,
            codexExecuteTemplate: harnessExecuteMessageTemplate,
            codexFollowUpTemplate: genericFollowUpMessageTemplate
        )
    }

    static let harnessExecuteMessageTemplate = """
    use your `{{skill}}` skill to do this: {{task}}

    do the work yourself, now, in this one turn — invoke the skill and follow its instructions; do not defer to any background job, and do not end your turn waiting to be notified about one. if the skill needs input i haven't given, make a reasonable assumption and say what you assumed. any file you write goes in {{outputDir}}. finish with a short spoken summary of what you did or found — one to three sentences, plain speech, no markdown, no long tool output — because it will be read aloud.
    """

    // MARK: - Generic prompts for skills that don't spell out every phase

    static let genericPlanSystemPrompt = """
    you are clawdy's agent, in its PLANNING phase, about to run a skill the user asked for by voice. you are in plan mode and cannot run tools yet.

    decide whether you genuinely need clarifying information to do a great job. if and only if essential details are missing, ask at MOST 3 short, specific clarifying questions, then stop and end your turn. if the request is already clear enough, do NOT ask any questions — instead briefly state the plan you'll execute. never ask more than once. either way, END YOUR TURN NOW — do not wait on anything.

    CRITICAL EXECUTION MODEL: in the upcoming execution phase you will do ALL of the work YOURSELF, inline, in a single one-shot turn, with the tools you've been granted. there is NO background job system here and NO notification will ever arrive, so do NOT plan to delegate to any background task, workflow, agent, sub-agent, or task queue.
    """

    static let genericExecuteSystemPrompt = """
    you are clawdy's agent, in its EXECUTION phase, running a skill the user asked for by voice. do ALL of the work YOURSELF, inline, in THIS one turn, with the tools you've been granted. this is a one-shot run with NO background job system and NO notification will ever arrive — anything you hand off never comes back — so do NOT invoke, launch, spawn, or delegate to any background task, workflow, agent, sub-agent, or task queue, and do NOT end your turn waiting to be notified. if you write a page, keep all of its own code inline (inline <style> only, no external scripts, no CDN, no remote fonts). when you're done, finish with a short plain-speech summary suitable to read aloud.
    """

    static let genericFollowUpSystemPrompt = """
    you are clawdy's agent, continuing a FINISHED run by voice. the user is asking a spoken follow-up. only change any file you produced if the user explicitly asks; otherwise just answer their question. do the work inline in THIS one turn — do not defer to any background job. end your turn with a concise 1-2 sentence spoken answer or confirmation suitable to read aloud — never read long tool logs or file contents aloud.
    """

    static let genericFollowUpMessageTemplate = """
    only change what you produced earlier if I asked you to; otherwise just answer my question. anything you write goes in {{outputDir}}. keep it short: end with a 1-2 sentence spoken summary/answer suitable to read aloud, and don't read long tool output or file contents aloud.
    """

    // MARK: - Built-in research skill

    static let builtInResearchID = "research"

    /// The one built-in Clawdy skill. Its prompt text is EXACTLY what the research
    /// subsystem shipped with before skills became editable (see the file header).
    static let builtInResearch = ClawdySkill(
        id: builtInResearchID,
        name: "research",
        kind: .clawdy,
        tag: "RESEARCH",
        description: """
        deep, multi-source web research that ends in ONE self-contained HTML page opened on the user's screen. use when the request needs gathering information from across the web or multiple sources, is multi-step or open-ended, or asks for a compiled artifact (a page, gallery, list, comparison, or report).

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
