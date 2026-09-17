# ClawdyVoice

Clawdy's built-in, fully local voice: the Misaki English grapheme-to-phoneme engine and the
Kokoro-82M speech model on ONNX Runtime. No network, no key, no espeak.

## What's in here

- `Sources/ClawdyVoice/G2P/` — a fork of [MisakiSwift](https://github.com/mlalma/MisakiSwift) 1.0.1
  (Apache-2.0), itself a port of [misaki](https://github.com/hexgrad/misaki). Changes from upstream:
  - The MLX dependency is gone. The out-of-vocabulary fallback network (a tiny BART) is a
    plain-Swift + Accelerate port (`EnglishFallbackNetwork.swift`) reading the same
    `us_bart.safetensors`, so it runs on Intel Macs and macOS 14. `MToken` is vendored from
    MLXUtilsLibrary. Only the US-English resources are shipped.
  - Fixes verified against Python misaki / transformers (see the tests): decimals were read as
    dotted abbreviations, "twenty" was missing from num2words, currency detached from decimal
    amounts, "%" was swallowed, intra-word hyphens were spoken as a dash, a lowercase sentence
    start glued the period onto the previous word, and the fallback network is fed lowercase.
- `KokoroSynthesizer.swift` — the ONNX session, tokenization against the Kokoro v1.0 vocabulary,
  the 510-token chunker, voice loading, and the `[word](/phonemes/)` pronunciation-override pass.
- `SpokenTextNormalizer.swift` — reply text → speakable words (markdown, URLs, times, key chords).
- `Resources/voices/` — six Kokoro voices as raw float32 style tables (Heart is the default).
  The model file itself (`kokoro-v1.0.fp16.onnx`) lives in the app at `Clawdy/Models/`, fetched by
  `scripts/fetch-models.sh`.

## Tools

```bash
swift run g2pdump "Open Settings > Privacy & Security."   # phonemes Clawdy will speak
swift run g2pdump --tokens "mm-hm."                         # per-token breakdown
swift run -c release g2pdump --bench                        # synthesis latency on this Mac
swift test                                                  # G2P references + inference (skips without the model)
```

The reference fixtures under `Tests/ClawdyVoiceTests/Fixtures` were produced with Python
`misaki` 0.9 (lexicon path), `transformers` on the same BART weights (fallback network) and
`kokoro-onnx` 0.6 with the fp16 model (a raw waveform). Regenerate them if the lexicon or weights change.
