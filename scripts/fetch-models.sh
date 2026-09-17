#!/usr/bin/env bash
# Downloads the Kokoro-82M ONNX model (fp16, ~170 MB) that Clawdy bundles for its built-in
# voice into Clawdy/Models/ (git-ignored — too large for the repo). Idempotent: skips the
# download when the file is present and its SHA-256 matches. Run automatically by the Xcode
# "Fetch voice model" build phase and by scripts/release.sh; safe to run by hand.
set -euo pipefail

MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Clawdy/Models"
MODEL_FILE="$MODEL_DIR/kokoro-v1.0.fp16.onnx"
MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx"
MODEL_SHA256="c1610a859f3bdea01107e73e50100685af38fff88f5cd8e5c56df109ec880204"

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$MODEL_FILE" && "$(checksum "$MODEL_FILE")" == "$MODEL_SHA256" ]]; then
  exit 0
fi

mkdir -p "$MODEL_DIR"
echo "⬇️  Downloading Kokoro voice model (~170 MB) to $MODEL_FILE"
curl -fL --progress-bar -o "$MODEL_FILE.partial" "$MODEL_URL"
if [[ "$(checksum "$MODEL_FILE.partial")" != "$MODEL_SHA256" ]]; then
  rm -f "$MODEL_FILE.partial"
  echo "❌ Kokoro model checksum mismatch — download corrupted or the file changed upstream." >&2
  exit 1
fi
mv "$MODEL_FILE.partial" "$MODEL_FILE"
echo "✅ Kokoro voice model ready"
