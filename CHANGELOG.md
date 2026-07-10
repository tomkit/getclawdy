# Changelog

All notable changes to Clawdy are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/tomkit/getclawdy/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/tomkit/getclawdy/releases/tag/v0.0.1
