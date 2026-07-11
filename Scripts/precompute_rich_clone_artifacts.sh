#!/usr/bin/env bash
set -euo pipefail

CLONER_ROOT="${CLONER_ROOT:-/Users/richardfallat/Projects/dev/turing-native-qwen-cloner}"
GRAVITAS_ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Rich/BaseClone/rich_base_clone_v1.qwenclone"
MODEL="$CLONER_ROOT/Authoring/Models/Qwen3-TTS-12Hz-1.7B-Base"
TOOL="$CLONER_ROOT/Tools/precompute_qwen_base_clone_artifacts.py"
PYTHON="$CLONER_ROOT/.venv-qwen-authoring/bin/python"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -s "$TOOL" ]] || fail "Missing generalized precompute tool: $TOOL"
[[ -x "$PYTHON" ]] || fail "Missing authoring virtual environment Python: $PYTHON"
[[ -d "$PROFILE" ]] || fail "Missing Rich qwenclone profile: $PROFILE"
[[ -d "$MODEL" ]] || fail "Missing local Qwen authoring model: $MODEL"

"$PYTHON" "$TOOL" \
  --root "$GRAVITAS_ROOT" \
  --profile "$PROFILE" \
  --voice-id rich_base_clone_v1 \
  --character-id rich \
  --variant-id rich_reference_01 \
  --authoring-model "$MODEL" \
  --language English \
  --write-smoke-wav \
  --smoke-text "Mike, I hear you. I'm here. What happened?"

"$PYTHON" "$(dirname "$0")/finalize_rich_voice_registry.py" "$GRAVITAS_ROOT"
