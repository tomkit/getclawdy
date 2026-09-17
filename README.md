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

Clawdy runs on your own local Claude Code or Codex using your subscription tokens.

- **It sees what you see.** Every window, every app, every monitor.
- **Just say it.** Hold **Control + Option** and talk. No typing, no prompts.
- **It talks back.** Out loud, in plain words, while you keep working.
- **It points.** The claw cursor points things out on your screen.

<p align="center">
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">
    <img src="assets/download-mac.png" width="230" alt="Download Clawdy for macOS" />
  </a>
</p>

## Ask questions like:

- "What did I just break?"
- "Which of these settings do I actually need on?"
- "I have no idea what this box wants."
- "What do they actually want from me in this email?"
- "Find me three laptops under $900 and put it on one page."

Clawdy answers out loud and the claw points things out. For the bigger tasks, it leverages all the work you've put into your local harness and can leverage all the subagents, prompts, and plugins you've set up.

## Example: planning a road trip

**Point at your screen and talk.** Clawdy answers out loud and the claw flies to what it means.

![Clawdy planning a coastal route in Aomori](assets/demo-route.gif)

## Get started

1. **[Download Clawdy.dmg](https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg)**, open it, and drag Clawdy into **Applications**.
2. Launch Clawdy and allow **Microphone**, **Screen Recording**, and **Accessibility** when asked (then relaunch).
3. Make sure one of these is installed and signed in. If you already use it, you're done:
   - [Claude Code](https://docs.anthropic.com/en/docs/claude-code): `npm install -g @anthropic-ai/claude-code`, then run `claude` once to sign in.
   - [Codex](https://github.com/openai/codex): `npm install -g @openai/codex`, then `codex login`.
4. Click the claw in your menu bar, hold **Control + Option**, and talk.

Needs macOS 14.2 (Sonoma) or later. Works on Intel and Apple Silicon.

Optional: add an [ElevenLabs](https://elevenlabs.io) key in the menu-bar panel for a nicer voice. Without it, Clawdy uses the voice built into macOS.

## Use your own CLI harness

- **Your CLI, your tokens.** Clawdy shells out to the `claude` or `codex` binary on your machine. Every answer is billed to whatever subscription that CLI is signed into. No API keys, no proxy, no backend.
- **Your whole setup comes along.** Clawdy runs your CLI as-is, so the CLAUDE.md, skills, plugins, hooks, and MCP servers you've set up all load, same as in your terminal.
- **Pick it up in the shell whenever you want.** Every Clawdy conversation is a real CLI session. Resume one with `claude --resume <id>` or `codex resume <id>`, or hit "Resume in Terminal" in the History window.
- **It runs your skills.** Your existing Claude Code skills work by voice, and you can write Clawdy-specific ones. Details below.

## Skills and routing

Clawdy can give quick spoken answers to most questions. For more complex questions, like "research this and build me a page" or "plan me three days in Kyoto", Clawdy can use your existing skills or Clawdy-specific skills which will trigger a separate agent that goes off, does the work, and comes back with a result.

**How routing works.** Every question goes to Clawdy's voice agent first. It reads the list of skills it knows about and makes a call:

- Quick and answerable right now (from your screen or general knowledge)? It just answers.
- Needs the web, several steps, or a built artifact, or clearly matches a skill's description? It replies with a single line instead of talking, like `[RESEARCH] compare the three best standing desks under $1000 and build a page`, and Clawdy starts that skill in its own process.

**Two kinds of skills.**

1. *Your Claude Code skills.* Anything in `~/.claude/skills` (or `~/.codex/skills` if you use Codex) is already available by voice. Nothing to set up. Clawdy runs the skill in a dedicated `claude` session and reads the result back to you.
2. *Clawdy skills.* Same `SKILL.md` format, but written for Clawdy's interface: voice in, and a page on your screen or a spoken answer out. They live in `~/.clawdy/skills`.

**Bundled Clawdy skills.**

| Skill | You say | What happens |
|---|---|---|
| `research` | "Find the best noise-cancelling headphones and build me a page." | Researches the web, asks a clarifying question if it needs one, builds a self-contained page, and opens it. Keep talking to it to change the page. |
| `trip-planner` | "Plan me three days in Kyoto." | Builds a day-by-day itinerary page with neighborhoods and places to eat.

Edit `research/SKILL.md` to change how research behaves. Changes apply on your next question; no relaunch.

**Adding a new one.** Make a folder in `~/.clawdy/skills` with a `SKILL.md`. The description tells the router when to use it; the body tells the agent what to do.

```markdown
---
name: recipe-finder
description: finds a recipe for what the user has on hand and builds a page with it. use for "what can i make with X", "find me a recipe for Y". example — user says "what can i make with eggs and spinach": [RECIPE_FINDER] find a recipe using eggs and spinach and build a page.
allowed-tools: WebSearch, WebFetch, Write
clawdy-deliverable: html
---

Find a good recipe for: {{task}}. Search the web, pick one, and write ONE self-contained HTML page to {{outputPath}} with ingredients, steps, and how long it takes.
```

Then say "what can I make with eggs and spinach." That's it.

The marker in brackets comes from the name (`recipe-finder` becomes `[RECIPE_FINDER]`). Set `clawdy-deliverable: none` for a skill that should just speak its answer instead of opening a page. For full control over each phase (planning, executing, follow-ups), look at how `research/SKILL.md` is split into sections. `~/.clawdy/skills/README.md` has the complete list of options.

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
4. On first launch, grant **Microphone**, **Speech Recognition**, **Accessibility**, and **Screen Recording** when macOS asks, then quit and relaunch. These are tied to the signed binary, so you'll be asked again if the signature changes.

To run the unit tests, use **Cmd + U**, or from the terminal:

```bash
xcodebuild test -project Clawdy.xcodeproj -scheme Clawdy -destination 'platform=macOS' -only-testing:ClawdyTests CODE_SIGNING_ALLOWED=NO
```

Prefer building from Xcode for day-to-day work. Building with `xcodebuild` from the terminal can invalidate the macOS privacy permissions above, so the app may ask for them again.

**Verifying a release download.** Each release ships a `SHA256SUMS` file. The DMG is a universal binary, signed with a Developer ID and notarized by Apple:

```bash
shasum -a 256 -c SHA256SUMS
```

## Credits and license

Clawdy is an open-source fork of [heyclicky](https://heyclicky.com), rebuilt to run on the coding CLI you already have instead of a hosted backend. Clawdy's own source is under the **MIT License** (`LICENSE`); the upstream MIT notice is retained in `NOTICE`. Bundled third-party components are listed in `THIRD-PARTY-LICENSES.md`.
