<p align="center">
  <img src="assets/clawdy-logo.png" width="96" alt="Clawdy" />
</p>

<h1 align="center">Your AI, out of its shell.</h1>

<p align="center">Talk to your Mac. Clawdy sees your screen, talks back, and points at things.</p>

<p align="center">
  <a href="https://getclawdy.com">getclawdy.com</a> ·
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">Download for Mac</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <img src="assets/clawdy-hero.png" width="860" alt="Clawdy, a small red lobster, climbing out of a broken terminal window next to a spreadsheet." />
</p>

Hold Control + Option and say what you need. Clawdy looks at your screen, answers you out loud, and the claw flies to whatever it's talking about. It's a conversation: ask a follow-up, and it remembers what you were just talking about.

Clawdy runs on your own local Claude Code or Codex, using your subscription tokens. No account, nothing extra to pay for, and your voice stays on your Mac.

- You talk. Hold the keys and speak. No typing.
- It sees what you see. Every window, every monitor.
- Draw on your screen. Circle or scribble on anything while you talk, and Clawdy sees the marks.
- It talks back, out loud, while you keep working.
- It points. The claw cursor lands on the exact spot.

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

Say any of these out loud. Clawdy answers out loud and the claw points things out. Bigger tasks get handed to your local harness, so everything you've set up there (subagents, prompts, plugins, skills) comes along.

## Example: planning a road trip

Point at your screen and talk. Clawdy answers out loud and the claw flies to what it means.

![Clawdy planning a coastal route in Aomori](assets/demo-route.gif)

## Get started

1. [Download Clawdy.dmg](https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg), open it, drag Clawdy into Applications.
2. Launch it. Allow Microphone, Screen Recording, and Accessibility when asked, then relaunch.
3. Have Claude Code or Codex installed and signed in. If you already use one, skip this.
   - Claude Code: `npm install -g @anthropic-ai/claude-code`, then run `claude` once to sign in.
   - Codex: `npm install -g @openai/codex`, then `codex login`.
4. Hold Control + Option and talk.

macOS 14.2 or later, Intel or Apple Silicon.

If you want a nicer voice, put an [ElevenLabs](https://elevenlabs.io) key in the menu bar panel. Otherwise it uses the macOS voice.

## Use your own CLI harness

Clawdy shells out to the `claude` or `codex` binary on your machine. Whatever you ask gets billed to the subscription that CLI is signed into. No API keys, no proxy, no server of ours in the middle.

Because it's your real CLI, your setup comes with it: CLAUDE.md, skills, plugins, hooks, MCP servers. And every conversation is a real session. Pick one up in the terminal with `claude --resume <id>` (or `codex resume`), or click "Resume in Terminal" in the History window.

## Routing

Clawdy is a lead agent. It can answer simple questions on its own and will respond quickly. For bigger questions, it will route to a subagent or trigger a plugin (mcp, skill, tool) to help it answer the question.

The routing prompt is a file you can edit: `~/.clawdy/router.md`.

## Skills

**Clawdy skills** live in `~/.clawdy/skills`. Same `SKILL.md` format, but should be more geared for voice input and spoken output. Two come installed:

| Skill | Say | You get |
|---|---|---|
| `research` | "Find the best noise-cancelling headphones and build me a page." | Web research, one clarifying question if needed, and a page. Keep talking to change it. |
| `trip-planner` | "Plan me three days in Kyoto." | A day-by-day itinerary page with neighborhoods and places to eat. |

**Adding a new skill.** Create a new folder in `~/.clawdy/skills` and one `SKILL.md`. 

```markdown
---
name: recipe-finder
description: finds a recipe for what the user has on hand and builds a page with it. use for "what can i make with X". example, user says "what can i make with eggs and spinach": [RECIPE_FINDER] find a recipe using eggs and spinach and build a page.
allowed-tools: WebSearch, WebFetch, Write
clawdy-deliverable: html
---

Find a good recipe for: {{task}}. Search the web, pick one, and write ONE self-contained HTML page to {{outputPath}} with ingredients, steps, and how long it takes.
```

Now say "what can I make with eggs and spinach."

## Build from source

You need macOS 14.2+ and Xcode 16+. Point the command line tools at it: `sudo xcode-select -s /Applications/Xcode.app`.

```bash
git clone https://github.com/tomkit/getclawdy.git
cd getclawdy
open Clawdy.xcodeproj
```

In Xcode, pick the Clawdy scheme and the My Mac destination, set your team under Signing & Capabilities (a personal Apple ID is fine), and press Cmd + R. The app shows up in the menu bar; there's no dock icon or window. First launch asks for Microphone, Speech Recognition, Accessibility, and Screen Recording. Grant them and relaunch. They're tied to the code signature, so a build signed differently will ask again.

Tests: Cmd + U, or

```bash
xcodebuild test -project Clawdy.xcodeproj -scheme Clawdy -destination 'platform=macOS' -only-testing:ClawdyTests CODE_SIGNING_ALLOWED=NO
```

Build from Xcode for day-to-day work. Terminal `xcodebuild` runs can reset the permissions above.

To check a downloaded release: each one ships a `SHA256SUMS`. The DMG is signed with a Developer ID and notarized by Apple.

```bash
shasum -a 256 -c SHA256SUMS
```

## Credits and license

Clawdy is a fork of [heyclicky](https://heyclicky.com), rebuilt to run on the coding CLI you already have instead of a hosted backend. Clawdy's code is MIT (`LICENSE`); the upstream notice is in `NOTICE`. Bundled third-party components are listed in `THIRD-PARTY-LICENSES.md`.
