<p align="center">
  <img src="assets/clawdy-logo.png" width="96" alt="Clawdy" />
</p>

<h1 align="center">Your AI, out of its shell.</h1>

<p align="center"><strong>Clawdy is an AI cursor buddy for Mac. It sees your screen, talks back, and points at exactly what it means. In any app.</strong></p>

<p align="center">
  <a href="https://getclawdy.com">getclawdy.com</a> ·
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">Download for Mac</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <img src="assets/clawdy-hero.png" width="860" alt="Clawdy, a small red lobster, bursting out through a jagged hole in a shattered terminal window, next to a spreadsheet with a broken cell." />
</p>

Clawdy has no AI of its own. It runs on the **Claude Code** or **Codex** you already have installed, so there is nothing new to sign up for and no separate bill. Your voice never leaves your Mac.

- **It sees what you see.** Every window, every app, every monitor.
- **Just say it.** Hold **Control + Option** and talk. No typing, no prompts.
- **It talks back.** Out loud, in plain words, while you keep working.
- **It points.** The claw flies to the exact spot on your screen.

<p align="center">
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">
    <img src="assets/download-mac.png" width="230" alt="Download Clawdy for macOS" />
  </a>
</p>

## Things you'd actually say

- "What did I just break?"
- "Which of these settings do I actually need on?"
- "I have no idea what this box wants."
- "What do they actually want from me in this email?"
- "Find me three laptops under $900 and put it on one page."

Clawdy answers out loud and the claw lands on the button, toggle, field, or sentence it's talking about. For the big asks, it goes and researches the web and opens a page on your screen.

## What it looks like

**Point at your screen and talk.** Clawdy answers out loud and the claw flies to what it means.

![Clawdy planning a coastal route in Aomori](assets/demo-route.gif)

## Get started

1. **[Download Clawdy.dmg](https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg)**, open it, and drag Clawdy into **Applications**.
2. Launch Clawdy and allow **Microphone**, **Screen Recording**, and **Accessibility** when asked (then relaunch).
3. Make sure one of these is installed and signed in. If you already use it, you're done:
   - [Claude Code](https://docs.anthropic.com/en/docs/claude-code): `npm install -g @anthropic-ai/claude-code`, then run `claude` once to sign in.
   - [Codex](https://github.com/openai/codex): `npm install -g @openai/codex`, then `codex login`.
4. Click the claw in your menu bar, then hold **Control + Option** and talk.

Needs macOS 14.2 (Sonoma) or later. Works on Intel and Apple Silicon.

Optional: add an [ElevenLabs](https://elevenlabs.io) key in the menu-bar panel for a nicer voice. Without it, Clawdy uses the voice built into macOS.

## For the technically curious

- **Your CLI, your tokens.** Clawdy shells out to the `claude` or `codex` binary on your machine. Every answer is billed to the subscription that CLI is signed into. No API keys, no proxy, no backend.
- **Your whole setup comes along.** Clawdy runs your CLI as-is, so the CLAUDE.md, skills, plugins, hooks, and MCP servers you've configured in your harness all load, exactly as they do in your terminal.
- **Pick it up in the shell whenever you want.** Clawdy drives a real CLI session, so you can resume any conversation in the terminal with `claude --resume <id>` or `codex resume <id>` (there's a "Resume in Terminal" button in the History window).
- **It runs your skills.** Your ordinary Claude Code skills (`~/.claude/skills`) are offered to Clawdy's router as-is, and you can write Clawdy-specific ones in `~/.clawdy/skills` using the same `SKILL.md` format. See [Skills and routing](#skills-and-routing).

## Skills and routing

Every question you ask goes to the warm voice agent first. It is also the **router**: based on the loaded skills, it either answers out loud right away, or hands the request to a skill that runs in its own agent process. Its decision rule is the same one a coding agent uses to decide between just doing a task and stopping to plan: quick, single-step, answerable-now questions are answered inline; anything that needs gathering from the web, several steps, a built artifact, or clearly matches a skill's description gets routed. On-screen pointing questions ("where do I click?") are always answered inline, never routed.

Routing is a one-line reply from the agent that Clawdy intercepts instead of speaking:

```
[RESEARCH] compare the three best standing desks under $1000 and build a page
[SKILL:pdf] summarize the PDF that's open
```

**Two kinds of skills are available:**

- **Your harness skills.** Anything in `~/.claude/skills/*/SKILL.md` (or `~/.codex/skills` when Codex is selected). Nothing to configure: the skill's `description` is the routing rule, exactly as it is for the CLI's own auto-invocation, and its `allowed-tools` govern the run. Clawdy starts a dedicated `claude -p` run that invokes the skill for your task, then **speaks the result back**. Requires "Use my Claude Code setup" to be on (the default).
- **Clawdy skills.** Skills written for Clawdy's interface (voice in; a page on your screen or a spoken answer out), in `~/.clawdy/skills/<name>/SKILL.md`. Same format, plus optional `clawdy-*` frontmatter keys. The built-in `research` skill is written there on first launch; edit it to retune research, or add a folder to teach Clawdy something new. Changes apply on your next question.

A minimal Clawdy skill:

```markdown
---
name: trip-planner
description: plans a multi-day trip and builds an itinerary page. use for "plan me N days in <place>". example — user says "plan me 3 days in kyoto": [TRIP_PLANNER] plan a 3-day kyoto itinerary.
allowed-tools: WebSearch, WebFetch, Write
clawdy-deliverable: html      # or `none` for a spoken result
---

Plan the trip {{task}} and write ONE self-contained HTML page to {{outputPath}}.
```

Only `description` is required; the body is what the agent does. For full control over each phase (plan / execute / follow-up, Claude and Codex variants) split the body into `## Plan`, `## Execute`, `## Execute message`, `## Follow-up`, `## Follow-up message`, `## Codex execute`, `## Codex follow-up`, the way `research/SKILL.md` does. Placeholders: `{{task}}`, `{{outputPath}}`, `{{outputDir}}`, `{{skill}}`. `POINT` and `FOLLOWUP` are reserved markers.

How a routed run works: a page-producing skill runs a plan/clarify phase (it may ask you one round of questions) and then an execute phase with a narrow tool allowlist, a spend cap, and a scoped output directory; the page opens in Clawdy's results window and you can keep talking to it. A spoken-result skill runs one execute turn and reads its final answer aloud. Either way the run is a real CLI session you can resume in the terminal.

## Build from source

You'll need **macOS 14.2+** and **Xcode 16+** (from the Mac App Store or [developer.apple.com](https://developer.apple.com/xcode/)). Make sure the command-line tools point at it: `sudo xcode-select -s /Applications/Xcode.app`.

```bash
git clone https://github.com/tomkit/getclawdy.git
cd getclawdy
open Clawdy.xcodeproj
```

In Xcode:

1. Select the **Clawdy** scheme and the **My Mac** destination.
2. Under the **Clawdy** target → **Signing & Capabilities**, pick your **Team**. Automatic signing with a personal Apple ID is fine for running locally.
3. Press **Cmd + R**. The app appears in your menu bar (there's no dock icon and no main window).
4. On first launch, grant **Microphone**, **Speech Recognition**, **Accessibility**, and **Screen Recording** when macOS asks, then quit and relaunch. These are tied to the signed binary, so you'll be asked again whenever the signature changes.

To run the unit tests, use **Cmd + U**, or from the terminal:

```bash
xcodebuild test -project Clawdy.xcodeproj -scheme Clawdy -destination 'platform=macOS' -only-testing:ClawdyTests CODE_SIGNING_ALLOWED=NO
```

Prefer building from Xcode for day-to-day work: building with `xcodebuild` from the terminal can invalidate the macOS privacy permissions above, so the app may ask for them again.

**Verifying a release download.** Each release ships a `SHA256SUMS` file. The DMG is a universal binary, signed with a Developer ID and notarized by Apple:

```bash
shasum -a 256 -c SHA256SUMS
```

## Credits and license

Clawdy is an open-source fork of [heyclicky](https://heyclicky.com), rebuilt to run on the coding CLI you already have instead of a hosted backend. Clawdy's own source is under the **MIT License** (`LICENSE`); the upstream MIT notice is retained in `NOTICE`. Bundled third-party components are listed in `THIRD-PARTY-LICENSES.md`.
