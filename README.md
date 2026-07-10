# Clawdy

Clawdy is a free, fully-local Mac menu bar buddy that lives next to your cursor. It can see your screen, talk to you, and point at stuff — like a teacher sitting next to you.

The twist: **Clawdy runs entirely on your own Claude Code or Codex CLI subscription.** There's no Cloudflare Worker, no API keys, no metering, and nothing sensitive in the app. When you talk to Clawdy, it shells out to the `claude` or `codex` CLI already installed and signed in on your machine, so responses are billed to *your* existing subscription.

Voice is local too: speech-to-text uses Apple's on-device Speech framework, and text-to-speech uses the built-in `AVSpeechSynthesizer`. Nothing leaves your Mac except the CLI's own model call.

## Download

The easiest way to run Clawdy is the signed, notarized build:

1. Download **`Clawdy.dmg`** from the [latest release](https://github.com/tomkit/getclawdy/releases/latest).
2. Open the DMG and drag **Clawdy** into **Applications**.
3. Launch Clawdy, then grant **Screen Recording**, **Accessibility**, and **Microphone** when prompted (and relaunch).
4. Make sure the `claude` or `codex` CLI is installed and signed in (see [Requirements](#requirements)).

The build is a single universal binary (Intel & Apple Silicon), signed with a Developer ID certificate and notarized by Apple, so it opens without Gatekeeper warnings. Verify your download against the `SHA256SUMS` attached to each release:

```bash
shasum -a 256 -c SHA256SUMS
```

See the [changelog](CHANGELOG.md) for what changed in each version.

## How it works

1. Hold **Control + Option** to talk (push-to-talk). Audio is transcribed on-device with Apple Speech.
2. On release, Clawdy captures a screenshot of each connected display (downscaled to ≤1280px, one JPEG per screen, only when you press the hotkey — never continuously).
3. The transcript + screenshots + a coaching system prompt are handed to your selected engine:
   - **Claude Code** → the `claude` CLI in headless print mode.
   - **Codex** → the `codex` CLI in non-interactive `exec` mode.
4. The model's reply is streamed back, spoken aloud via local TTS, and — if the model emitted a `[POINT:x,y:label:screenN]` tag — the claw cursor flies to that on-screen element.

## Requirements

- macOS 14.2 (Sonoma) or later — universal binary (Intel & Apple Silicon)
- Xcode 16+
- **At least one of:**
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`, then `claude` (sign in once)
  - [Codex](https://github.com/openai/codex) — `npm install -g @openai/codex`, then `codex login`

That's it. No API keys, no Cloudflare account, no Node Worker. Clawdy auto-detects which CLIs are installed and lets you pick between them in the menu-bar panel.

## Build & run

```bash
open Clawdy.xcodeproj
```

In Xcode:
1. Select the `Clawdy` scheme.
2. Set your signing team under Signing & Capabilities.
3. Hit **Cmd + R**.

The app appears in your menu bar (no dock icon). Click the icon, grant the permissions it asks for, pick your engine, and start talking.

### Permissions

- **Microphone** — push-to-talk voice capture
- **Speech Recognition** — on-device transcription (Apple Speech)
- **Accessibility** — the global Control + Option shortcut (listen-only CGEvent tap)
- **Screen Recording** / **Screen Content** — screenshots when you press the hotkey

The app is intentionally **not sandboxed** (`com.apple.security.app-sandbox = false`) because it shells out to your CLI binaries and captures the screen.

## The exact CLI invocations

Clawdy builds these command lines (working directory = a private per-request temp dir holding only the screenshots):

**Claude Code** (`ClaudeCodeEngine`):
```
claude -p "<prompt>" \
  --append-system-prompt "<coaching system prompt>" \
  --allowedTools Read \
  --add-dir "<temp dir>" \
  --output-format stream-json --verbose --include-partial-messages
```
The prompt lists each screenshot file and asks Claude to `Read` them; `--allowedTools Read` + `--add-dir` grant read-only access to just the temp dir so the tool call runs without an interactive permission prompt. Streamed `text_delta` events drive progressive UI; the final `result` event is the authoritative answer.

**Codex** (`CodexEngine`):
```
codex exec --skip-git-repo-check -s read-only -C "<temp dir>" --json \
  -i "<temp dir>/screen1.jpg" [-i "<temp dir>/screen2.jpg" ...] -
```
The prompt (with the coaching system prompt folded in, since `codex exec` has no system-prompt flag) is fed on **stdin** via the trailing `-`. Images are attached natively with `-i` so the model sees them directly. The final answer is the `agent_message` item in the `--json` stream.

Both engines resolve their binary via PATH plus common install locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, every `~/.nvm/versions/node/*/bin`) because a Finder-launched app inherits a minimal PATH.

## Architecture

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. The push-to-talk pipeline records audio, transcribes it on-device, captures screenshots, and hands everything to a `CoachEngine`. `CoachEngine` is a protocol; `ClaudeCodeEngine` and `CodexEngine` are the two CLI-backed implementations, selected at runtime based on what's installed. The model can embed `[POINT:x,y:label:screenN]` tags to make the cursor fly to specific UI elements across monitors.

Full technical breakdown lives in `AGENTS.md` (aliased as `CLAUDE.md`).

## Project structure

```
Clawdy/                      # Swift source
  CompanionManager.swift       # Central state machine
  CompanionPanelView.swift     # Menu bar panel UI (engine picker)
  CoachEngine.swift            # Engine protocol + kinds + detection types
  CoachEngineRegistry.swift    # Detects installed CLIs, builds engines
  ClaudeCodeEngine.swift       # `claude` CLI engine
  CodexEngine.swift            # `codex` CLI engine
  CLIBinaryResolver.swift      # PATH / install-location binary resolution
  CLIProcessRunner.swift       # Async Process wrapper, line-streamed stdout
  CLIPromptComposer.swift      # Builds prompt text + screenshot file list
  CLIEngineWorkspace.swift     # Per-request temp dir + screenshot writing
  LocalSpeechTTSClient.swift   # Local AVSpeechSynthesizer TTS
  AppleSpeechTranscriptionProvider.swift  # On-device STT (default)
  OverlayWindow.swift          # Blue cursor overlay
  BuddyDictation*.swift        # Push-to-talk pipeline
ClawdyTests/                 # Unit tests (binary resolution, args, parsing)
AGENTS.md / CLAUDE.md        # Full architecture doc (agents read this)
```

## License

Clawdy's own source is licensed under the **MIT License** (see `LICENSE` and `NOTICE`). Third-party components bundled in the app are listed in `THIRD-PARTY-LICENSES.md`.

The client in this repository is free and permissively licensed (MIT) — bring your own Claude Code or Codex CLI and it is yours to use, modify, and self-host. A future managed/hosted tier (run against our own provider accounts, no CLI required) is planned separately under a source-available license (Fair Source / FSL); that license will ship with the hosted component if and when it is added. The client in this repository stays MIT.
