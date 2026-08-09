#!/usr/bin/env bash
set -euo pipefail

CLONER_ROOT="${CLONER_ROOT:-/Users/richardfallat/Projects/dev/turing-native-qwen-cloner}"
GRAVITAS_ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"
VARIANT="$PROFILE/variants/dad_reference_fast_01"
MODEL="$CLONER_ROOT/Authoring/Models/Qwen3-TTS-12Hz-1.7B-Base"
TOOL="$CLONER_ROOT/Tools/precompute_qwen_base_clone_artifacts.py"
PYTHON="$CLONER_ROOT/.venv-qwen-authoring/bin/python"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -s "$TOOL" ]] || fail "Missing generalized precompute tool: $TOOL"
[[ -x "$PYTHON" ]] || fail "Missing authoring virtual environment Python: $PYTHON"
[[ -d "$PROFILE" ]] || fail "Missing Dad qwenclone profile: $PROFILE"
[[ -d "$MODEL" ]] || fail "Missing local Qwen authoring model: $MODEL"
grep -qv '^AUTHOR INPUT REQUIRED:' "$VARIANT/ref_text.txt" || \
  fail "Dad clone precompute is blocked on the author-approved exact transcript."

"$PYTHON" "$TOOL" \
  --root "$GRAVITAS_ROOT" \
  --profile "$PROFILE" \
  --voice-id dad_base_clone_v1 \
  --character-id dad \
  --variant-id dad_reference_fast_01 \
  --authoring-model "$MODEL" \
  --language English \
  --write-smoke-wav \
  --smoke-text "Rich, you copy? Keep the doors locked and stay by the radio."

"$PYTHON" "$GRAVITAS_ROOT/Scripts/finalize_qwen_voice_registry.py" \
  --root "$GRAVITAS_ROOT" \
  --profile "$PROFILE" \
  --voice-id dad_base_clone_v1 \
  --character-id dad \
  --variant-id dad_reference_fast_01 \
  --registry "$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Config/voice-registry.json"
