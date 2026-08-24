#!/bin/bash
# One-time setup: install llama.cpp (for Gemma cleanup) and download models.
# Idempotent — safe to re-run; resumes partial downloads.
set -euo pipefail

# Hardware check, not process arch — a Rosetta-translated shell reports
# x86_64 on Apple Silicon.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
  echo "error: zeldaFlow needs an Apple Silicon Mac." >&2
  echo "       Whisper and Gemma run on Metal; the build targets arm64." >&2
  exit 1
fi

MODELS="$HOME/Library/Application Support/zeldaFlow/models"
mkdir -p "$MODELS"

echo "==> llama.cpp (Gemma cleanup server)"
# Check the same two paths the app itself probes.
if [ ! -x /opt/homebrew/bin/llama-server ] && [ ! -x /usr/local/bin/llama-server ]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "    Homebrew not found — skipping llama.cpp." >&2
    echo "    Dictation works without it; AI cleanup and voice commands need it." >&2
    echo "    Install Homebrew (https://brew.sh), then re-run scripts/setup.sh." >&2
  else
    brew install llama.cpp
  fi
else
  echo "    already installed"
fi

dl() { # dl <filename> <url> <label>
  local file="$MODELS/$1"
  if [ -f "$file" ]; then
    echo "    $3: already downloaded"
    return
  fi
  echo "    $3: downloading…"
  # -f: fail on HTTP errors instead of saving the error page as a model.
  # .part + rename: an interrupted download never masquerades as complete,
  # and -C - resumes it on the next run.
  curl -fL --retry 3 -C - -o "$file.part" "$2"
  mv "$file.part" "$file"
}

echo "==> models → $MODELS"
dl ggml-large-v3-turbo-q8_0.bin \
   "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin" \
   "Whisper large-v3-turbo q8_0 (874 MB)"
dl ggml-silero-v6.2.0.bin \
   "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin" \
   "Silero VAD v6.2 (1 MB)"
dl gemma-4-E2B-it-Q4_0.gguf \
   "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf" \
   "Gemma 4 E2B Q4_0 (2.8 GB)"

# Optional Core ML encoder: runs Whisper's encoder on the Neural Engine
# instead of the GPU. Matters most with external monitors, where the GPU is
# also compositing displays — dictation stays fast either way, but the ANE
# keeps it fast under load. Everything works without it (Metal fallback).
# Same .part discipline as dl(), and a staged unzip + atomic rename so the
# .mlmodelc directory either exists complete or not at all — whisper would
# otherwise trip over a half-extracted encoder on every launch.
CML="ggml-large-v3-turbo-encoder.mlmodelc"
if [ -d "$MODELS/$CML" ]; then
  echo "    Core ML encoder: already installed"
else
  echo "    Core ML encoder (Neural Engine, 1.1 GB): downloading…"
  if curl -fL --retry 3 -C - -o "$MODELS/$CML.zip.part" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$CML.zip"; then
    mv "$MODELS/$CML.zip.part" "$MODELS/$CML.zip"
    STAGE="$(mktemp -d "$MODELS/.$CML.XXXXXX")"
    if unzip -q "$MODELS/$CML.zip" -x "__MACOSX/*" -d "$STAGE"; then
      mv "$STAGE/$CML" "$MODELS/$CML"
      rm -rf "$STAGE" "$MODELS/$CML.zip"
    else
      rm -rf "$STAGE" "$MODELS/$CML.zip"
      echo "    Core ML encoder archive was corrupt — skipped (Metal fallback works fine)." >&2
    fi
  else
    echo "    Core ML encoder unavailable — skipped (Metal fallback works fine; re-run to resume)." >&2
  fi
fi
rm -rf "$MODELS/__MACOSX"

# Optional speaker-diarization models (ADR 31): pyannote community-1
# segmentation + WeSpeaker embeddings, converted to Core ML by FluidInference
# (CC-BY-4.0, ungated — https://huggingface.co/FluidInference/speaker-diarization-coreml).
# The app loads these fully offline; when they're missing the speaker pass
# just skips, so failure here downgrades the feature, never the app.
# Layout must match FluidAudio's ModelHub: models/diarizer/speaker-diarization/<file>.
# .mlmodelc bundles are directories, so the file list comes from the HF tree
# API and everything lands in a staging dir first — the target either exists
# complete or not at all (same discipline as the Core ML encoder above).
DIAR_DIR="$MODELS/diarizer/speaker-diarization"
DIAR_REPO="FluidInference/speaker-diarization-coreml"
echo "==> speaker diarization models (optional, ~100 MB)"
diar_complete() {
  [ -d "$DIAR_DIR/Segmentation.mlmodelc" ] && [ -d "$DIAR_DIR/FBank.mlmodelc" ] \
    && [ -d "$DIAR_DIR/Embedding.mlmodelc" ] && [ -d "$DIAR_DIR/PldaRho.mlmodelc" ] \
    && [ -f "$DIAR_DIR/plda-parameters.json" ]
}
if diar_complete; then
  echo "    already installed"
else
  DIAR_STAGE="$(mktemp -d "$MODELS/.diarizer.XXXXXX")"
  diar_fail() {
    rm -rf "$DIAR_STAGE"
    echo "    diarization models unavailable — skipped (speaker labels stay off; re-run to retry)." >&2
  }
  if curl -fsL --retry 3 \
       "https://huggingface.co/api/models/$DIAR_REPO/tree/main?recursive=true" \
       -o "$DIAR_STAGE/tree.json" \
     && python3 - "$DIAR_STAGE/tree.json" > "$DIAR_STAGE/files.txt" <<'PY'
import json, sys
roots = ("Segmentation.mlmodelc/", "FBank.mlmodelc/",
         "Embedding.mlmodelc/", "PldaRho.mlmodelc/")
for entry in json.load(open(sys.argv[1])):
    path = entry.get("path", "")
    if entry.get("type") == "file" and (path.startswith(roots) or path == "plda-parameters.json"):
        print(path)
PY
  then
    if [ ! -s "$DIAR_STAGE/files.txt" ]; then
      diar_fail
    else
      echo "    downloading $(wc -l < "$DIAR_STAGE/files.txt" | tr -d ' ') files…"
      DIAR_OK=1
      while IFS= read -r p; do
        mkdir -p "$DIAR_STAGE/repo/$(dirname "$p")"
        if ! curl -fsL --retry 3 -o "$DIAR_STAGE/repo/$p" \
             "https://huggingface.co/$DIAR_REPO/resolve/main/$p"; then
          DIAR_OK=0; break
        fi
      done < "$DIAR_STAGE/files.txt"
      if [ "$DIAR_OK" = 1 ]; then
        mkdir -p "$(dirname "$DIAR_DIR")"
        rm -rf "$DIAR_DIR"
        mv "$DIAR_STAGE/repo" "$DIAR_DIR"
        rm -rf "$DIAR_STAGE"
        echo "    installed → $DIAR_DIR"
      else
        diar_fail
      fi
    fi
  else
    diar_fail
  fi
fi

echo "==> done"
ls -lh "$MODELS"
