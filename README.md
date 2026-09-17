<p align="center">
  <img src="assets/clawdy-logo.png" width="96" alt="Clawdy" />
</p>

<h1 align="center">Your AI, out of its shell.</h1>

<p align="center">
  <img src="assets/clawdy-hero.png" width="860" alt="Clawdy, a small red lobster, has broken out of a shattered terminal window and stands beside the mouse cursor on a spreadsheet, pointing at a broken cell and saying: This one. It's pointing at a deleted row." />
</p>

<p align="center"><strong>Clawdy is an AI cursor buddy for Mac. It sees your screen, talks back, and points at exactly what it means. In any app.</strong></p>

<p align="center">
  <a href="https://getclawdy.com">getclawdy.com</a> ·
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">Download for Mac</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

Hold **Control + Option**, say what you need, and let go. Clawdy looks at your screen, answers out loud, and a little red claw flies to whatever it's talking about.

Clawdy has no AI of its own. It runs on the **Claude Code** or **Codex** you already have installed, so there is nothing new to sign up for and no separate bill. Your voice never leaves your Mac.

1. It lives in your terminal.
2. Clawdy lets it out.
3. Now it rides along with your cursor and points.

<p align="center">
  <a href="https://github.com/tomkit/getclawdy/releases/latest/download/Clawdy.dmg">
    <img src="assets/download-mac.png" width="230" alt="Download Clawdy for macOS" />
  </a>
</p>

## Hold a key. Say the thing you'd say anyway.

| You say | Clawdy does |
|---|---|
| **"What did I just break?"** (at 11:40pm) | Reads the dialog you've been staring at. *"Nothing's lost. Click Revert to Saved, that one."* The claw is already on it. |
| **"Which of these do I actually need on?"** (in System Settings) | Twelve toggles, zero explanation. Clawdy circles one. *"Just this one. Leave the rest off."* |
| **"I have no idea what this box wants."** (on a government website) | Reads the whole form, not just the box. *"That's your adjusted gross income. It's line 11 on last year's return."* |
| **"What do they actually want from me?"** (six paragraphs deep) | Skips the pleasantries and highlights one sentence. *"The invoice, by Friday. Everything else is padding."* |
| **"Find me three laptops under $900 and put it on one page."** (with 14 tabs open) | Big ask, so it goes and does it: reads the web, builds the comparison with pictures and prices, opens it on your screen. *"Done. The middle one, if you want my pick."* |

Any window, any app, every monitor. If you can see it, Clawdy can see it.

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

**It's your CLI, your tokens.** Clawdy shells out to the `claude` or `codex` binary on your machine. Every answer is billed to the subscription that CLI is signed into. There are no model API keys, no proxy, and no backend. Because it drives the same underlying session, you can hand a conversation off and **resume it in the terminal** (`claude --resume`, `codex resume`) whenever you want.

**Your own setup comes along.** By default Clawdy runs `claude` without `--safe-mode`, so your CLAUDE.md, skills, plugins, hooks, and MCP servers all load, the same as in your terminal. Turn "Use my Claude Code setup" off in the panel to isolate it.

**What happens on each press:**

1. Hold Control + Option. Audio is transcribed on-device with Apple's Speech framework.
2. On release, Clawdy captures one downscaled JPEG (≤800px) per connected display. Only when you press the key, never continuously.
3. Transcript, screenshots, and a coaching system prompt go to your engine: `claude -p` in stream-json print mode (kept warm for the app's lifetime), or `codex exec`.
4. The reply streams back and is spoken sentence by sentence with `AVSpeechSynthesizer`. `[POINT:x,y:label:screenN]` tags in the reply drive the claw to each element. With an ElevenLabs key, the claw's moves are synced to the audio and arrive a beat before each thing is named.

**Research mode.** For big "look this up and build me something" asks, Clawdy runs a separate `claude -p` (or `codex exec`) session with web search and a narrow write allowlist, produces a single self-contained `report.html`, and opens it in an embedded window. Runs are indexed in a History window with follow-up chat.

**Permissions.** Microphone (push-to-talk), Speech Recognition (on-device transcription), Accessibility (the global shortcut, via a listen-only CGEvent tap), Screen Recording (screenshots on hotkey). The app is deliberately not sandboxed because it launches your CLI binaries and captures the screen.

**Verify your download** against the `SHA256SUMS` attached to each release: `shasum -a 256 -c SHA256SUMS`. The DMG is a universal binary, signed with a Developer ID and notarized by Apple. See the [changelog](CHANGELOG.md) for what changed in each version.

## Build from source

Requires Xcode 16+.

```bash
open Clawdy.xcodeproj
```

Select the `Clawdy` scheme, set your signing team under Signing & Capabilities, and hit **Cmd + R**. The app appears in your menu bar (no dock icon).

The landing page lives in [`site/`](site/) (static HTML, deployed to [getclawdy.com](https://getclawdy.com) on every push to `main`).

## Credits and license

Clawdy is an open-source fork of [heyclicky](https://heyclicky.com), rebuilt to run on the coding CLI you already have instead of a hosted backend. Clawdy's own source is under the **MIT License** (`LICENSE`); the upstream MIT notice is retained in `NOTICE`. Bundled third-party components are listed in `THIRD-PARTY-LICENSES.md`.
