# Changelog

All notable changes to Clawdy are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **A built-in voice.** Clawdy now talks back with its own bundled voice (Kokoro, running on your Mac — nothing is sent anywhere) instead of the robotic system voice. Six voices to pick from in the panel; "Heart" is the default. ElevenLabs is still there if you'd rather use your own key. Teach it names and product words in `~/.clawdy/pronunciations.txt`. The download is about 170 MB bigger for it.
- **Draw, then ask about it.** When you draw on the screen while asking, Clawdy is now told the red strokes are your annotation, so "this road" means the one you traced (and it points at the marked thing, not a look-alike elsewhere).
- **Research asks out loud.** When a research run needs a quick answer first, Clawdy now asks the question in its voice (at the next quiet moment) and the pill turns into the thing you're talking to — the question, a mic, and "⌃⌥ to answer". Hold the keys and answer; the run continues. The typed box is still there if you click the pill.
- The research pill shows the brand claw and a quiet elapsed-time clock, so a minutes-long run never looks stuck.
- **Speed settings.** Pick the model and effort for quick answers in the menu bar panel; the control is the same for both engines. Sonnet + low effort is now the default for Claude (about a second faster to the first spoken word than Opus at half the cost, and no multi-second silent think before a longer answer: low effort halved time-to-first-text on substantive questions in testing). For Codex, low effort is about 2× faster than medium.
- **Instant feedback, all in Clawdy's voice.** About a second after you release the keys Clawdy says "let me check" / "let me take a look" (a natural beat, not the instant you stop), and if the answer is taking a while it says "checking now" / "still looking, bear with me" at sensible intervals — the register of a voice assistant, not a status line. Research runs now say "sure, I'll put a page together", "your page is ready", and "sorry, that one didn't work out" instead of playing system sounds. There are no sound effects, and no two voice outputs ever overlap: a research announcement waits until you and Clawdy are both quiet.
- **Fast mode switch.** Turns on the engine's own fast tier for quick answers: Claude Code fast mode (Opus only) or Codex `service_tier=fast` (about a second faster per reply). Off by default; both cost more.
- Per-turn latency log (`log show --predicate 'subsystem == "com.clawdy.Clawdy" AND category == "latency"'`) so slow turns can be attributed to transcription, the model, or speech.

### Changed
- **Research pages and History are real windows now.** While one is open Clawdy shows in the Dock and Cmd-Tab, so a page can't get lost behind other apps.
- **Codex model picker.** The panel shows your Codex default model and lets you pick any model Codex lists.
- **Quieter recents list and History.** The claw's recents list is a compact "Recent" list sized to its rows; History rows show the skill and time on a second line with a status dot only for running/failed runs, and the detail header shows skill · engine · time.
- **Simpler menu bar panel.** One right edge for every control, quieter hierarchy, the hotkey shown as keycaps, History and Quit on one row, no close button (click outside or press Escape). The "Use my Claude Code setup" toggle is gone: your setup always loads.

### Removed
- The macOS system voice. The built-in Kokoro voice replaces it entirely (ElevenLabs remains as the bring-your-own-key option).

### Fixed
- The instant "let me check" was being cut off (and the "let me look" fillers and a queued "your page is ready" were being cancelled) by the request's own teardown right after key release. Cues now survive the request start; only a re-press or Stop cancels them. A research hand-off says one thing, not "okay" and then "on it".
- Opening or closing a research results page no longer forces a cold restart of the warm `claude` process on the next question.

## [0.0.3] - 2026-09-16

### Added
- **Skills.** Clawdy can hand a spoken request to a skill that runs in its own agent. Your Claude Code skills (`~/.claude/skills`, or `~/.codex/skills` with Codex) work by voice with nothing to set up; the result is spoken back. Clawdy-specific skills live in `~/.clawdy/skills/<name>/SKILL.md`, the same format as Claude Code / Codex skills plus optional `clawdy-*` keys. `research` and an example `trip-planner` ship there on first launch; edit them or add your own. Changes apply on the next question.
- **Editable routing prompt.** `~/.clawdy/router.md` is the prompt the voice agent uses to decide between answering inline and routing to a skill.
- Skills without a page (`clawdy-deliverable: none`) speak their result instead of opening a results window.

### Changed
- **The idle claw badge opens on click, not hover.** Hovering the resting badge no longer pops the recents list open; click it. Once open, moving the pointer off it still auto-collapses it.
- New landing page at [getclawdy.com](https://getclawdy.com) and a simpler README.

### Fixed
- The system prompt and docs described the claw cursor as blue; it has been red since the brand change.

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
