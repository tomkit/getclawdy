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
  <img src="assets/clawdy-hero.png" width="860" alt="Clawdy, a small red lobster, has broken out of a shattered terminal window and stands beside the mouse cursor on a spreadsheet, pointing at a broken cell and saying: This one. It's pointing at a deleted row." />
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
