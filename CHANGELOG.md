# Changelog

All notable changes to Clawdy are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-07-10

### Added
- **Audio-synced pointing.** When an answer names several places, the claw now visits each in turn (up to ~7), showing each place's name as it arrives. With an ElevenLabs key, each move is timed to the spoken audio and leads it by a beat so you see the target just before you hear it; on Apple TTS the claw visits them in order (untimed).
- **Draggable overlays.** Drag the research toast / idle mini-toast by its body to move it out of the way of whatever's behind it; the position persists across launches and is re-clamped to the current display.
- **Overlays visible in screen recordings.** Clawdy's claw cursor and on-screen annotations now appear in QuickTime/OBS by default (great for demos and tutorials), while still being excluded from the screenshots Clawdy sends to the model.

### Fixed
- **Legible input placeholders.** Text-field placeholder text was dark-on-dark; it now uses a readable muted tone (with VoiceOver labels preserved).
- **Faster, cleaner research.** Removed a redundant per-image `WebFetch` pre-check that caused frequent HTTP 400s and slowed research; broken images are swapped for inline placeholders instead — on both the Claude and Codex research paths.

## [0.0.1] - 2026-07-10

Initial public release. Clawdy is a free, fully-local macOS menu-bar voice companion —
it sees your screen, talks with you, and points at things, running entirely on your own
Claude Code or Codex CLI subscription.

### Added
- **Push-to-talk voice** (Control+Option) with on-device transcription via Apple's Speech framework.
- **Bring-your-own coding CLI**: Claude Code (`claude`) or Codex (`codex`), auto-detected across
  common install layouts (Homebrew, npm/pnpm/yarn, Volta, asdf, fnm, nvm, `n`) with a login-shell
  PATH fallback. Only installed engines are selectable; a friendly prompt appears when neither is found.
- **Multi-monitor screen capture** sent inline to the model, plus a claw **cursor overlay** that flies
  to and points at referenced on-screen elements (`[POINT:...]`).
- **Graffiti annotation**: draw on the screen while holding push-to-talk; strokes are composited into
  the screenshot the model sees. Escape-to-exit and a watchdog guarantee the mode can never wedge.
- **Local text-to-speech** via `AVSpeechSynthesizer`, with optional bring-your-own ElevenLabs key
  (stored in the macOS Keychain).
- **Autonomous research mode** (Claude and Codex): researches the web and builds a self-contained
  HTML page, with a history window, follow-up chat, and **Resume in Terminal**.
- **Lobster-claw branding**: menu-bar icon, shadow cursor, and idle mini-toast all use the claw, on an
  OpenClaw-red accent theme driven by unified design-system tokens.

### Notes
- Requires **macOS 14.2 (Sonoma) or later**. Ships as a single **universal** binary (Intel & Apple Silicon).
- No backend and no API keys — responses are billed to your own Claude Code / Codex subscription.
  Anonymous usage analytics are collected via PostHog.
- Licensed under the MIT License; portions originate from an upstream MIT project (see `NOTICE`).

[Unreleased]: https://github.com/tomkit/getclawdy/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/tomkit/getclawdy/releases/tag/v0.0.2
[0.0.1]: https://github.com/tomkit/getclawdy/releases/tag/v0.0.1
