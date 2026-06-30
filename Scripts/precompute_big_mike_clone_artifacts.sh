#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$ROOT/Tools/TuringVoicePackager/precompute_big_mike_clone_artifacts.py"
MODEL="$ROOT/Authoring/Models/Qwen3-TTS-12Hz-1.7B-Base"
VENV="$ROOT/.venv-qwen-authoring"

if [[ ! -f "$TOOL" ]]; then
  echo "Missing tool: $TOOL" >&2
  exit 2
fi

if [[ ! -d "$VENV" ]]; then
  python3 -m venv "$VENV"
fi
source "$VENV/bin/activate"
python -m pip install -U pip
python -m pip install -U qwen-tts safetensors soundfile librosa numpy torch

if [[ ! -d "$MODEL" ]]; then
  cat >&2 <<EOF
Missing local official Qwen PyTorch Base authoring model:
  $MODEL

Download it explicitly on the Mac authoring machine, for example:
  source "$VENV/bin/activate"
  python -m pip install -U "huggingface_hub[cli]"
  hf download Qwen/Qwen3-TTS-12Hz-1.7B-Base --local-dir "$MODEL"

This authoring download is not part of the visionOS app and must not be used at runtime.
EOF
  exit 3
fi

python "$TOOL" \
  --root "$ROOT" \
  --authoring-model "$MODEL" \
  --variant-id broadcast_reading_lazy
