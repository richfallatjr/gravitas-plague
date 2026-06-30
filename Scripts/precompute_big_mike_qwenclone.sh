#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: $0 /path/to/gravitas-plague" >&2
  exit 2
fi
cd "$ROOT"
PROFILE="Gravitas Plague/TuringResources/Turing/Voices/Cloned/BigMike/BaseClone/big_mike_base_clone_v1.qwenclone"
SCRIPT="Tools/TuringVoicePackager/precompute_qwen_base_clone_prompt.py"
if [[ ! -f "$SCRIPT" ]]; then
  echo "missing $SCRIPT" >&2
  exit 1
fi
if [[ ! -d "$PROFILE" ]]; then
  echo "missing profile $PROFILE" >&2
  exit 1
fi
VENV="Tools/TuringVoicePackager/.venv-qwenclone"
python3 -m venv "$VENV"
source "$VENV/bin/activate"
python -m pip install -U pip wheel setuptools
python -m pip install -U qwen-tts soundfile numpy
python "$SCRIPT" \
  --repo-root "$ROOT" \
  --profile "$PROFILE" \
  --variant broadcast_reading_lazy \
  --official-qwen "ExternalReference/Qwen3-TTS-official" \
  --model "Qwen/Qwen3-TTS-12Hz-1.7B-Base" \
  --device cpu \
  --dtype bfloat16
bash Scripts/audit_big_mike_qwenclone_artifacts.sh "$ROOT"
