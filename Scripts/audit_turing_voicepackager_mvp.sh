#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: $0 /path/to/gravitas-plague" >&2
  exit 2
fi

fail() { echo "[audit_turing_voicepackager_mvp] FAIL: $*" >&2; exit 1; }
pass() { echo "[audit_turing_voicepackager_mvp] PASS: $*"; }

TOOL="$ROOT/Tools/TuringVoicePackager/turing_voicepackager_mvp.py"
MANIFEST="$ROOT/Authoring/Voices/BigMike/elevenlabs/big_mike_reading_manifest.json"
PROFILE="$ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/BigMike/BaseClone/big_mike_base_clone_v1.qwenclone"
REGISTRY="$ROOT/Gravitas Plague/TuringResources/Turing/Config/voice-registry.json"

[[ -f "$TOOL" ]] || fail "missing tool: $TOOL"
[[ -x "$TOOL" ]] || fail "tool is not executable: $TOOL"
[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"
[[ -d "$PROFILE" ]] || fail "missing profile directory: $PROFILE"
[[ -f "$PROFILE/metadata.json" ]] || fail "missing metadata.json"
[[ -f "$PROFILE/selection-catalog.json" ]] || fail "missing selection-catalog.json"
[[ -f "$PROFILE/checksums.sha256" ]] || fail "missing profile checksums"
[[ -f "$PROFILE/variants/broadcast_reading_lazy/variant.json" ]] || fail "missing variant.json"
[[ -f "$PROFILE/variants/broadcast_reading_lazy/ref_text.txt" ]] || fail "missing ref_text.txt"
[[ -f "$PROFILE/variants/broadcast_reading_lazy/ref_audio/original/big-mike-clone-reading.mp3" ]] || fail "missing original mp3"
[[ -f "$PROFILE/variants/broadcast_reading_lazy/ref_audio/normalized/ref_24000_mono.wav" ]] || fail "missing normalized wav"
[[ -f "$PROFILE/variants/broadcast_reading_lazy/checksums.sha256" ]] || fail "missing variant checksums"
[[ -f "$REGISTRY" ]] || fail "missing voice-registry.json"

PROFILE="$PROFILE" REGISTRY="$REGISTRY" python3 - <<'PY'
import json, pathlib, sys
import os
profile = pathlib.Path(os.environ['PROFILE'])
meta = json.loads((profile / 'metadata.json').read_text())
variant = json.loads((profile / 'variants/broadcast_reading_lazy/variant.json').read_text())
catalog = json.loads((profile / 'selection-catalog.json').read_text())
registry = json.loads(pathlib.Path(os.environ['REGISTRY']).read_text())
assert meta['voiceID'] == 'big_mike_base_clone_v1'
assert meta['profileKind'] == 'qwenBaseCloneReferenceProfile'
assert meta['modelID'] == 'qwen3-tts-12hz-1.7b-base-4bit'
assert meta['allowFallback'] is False
assert meta['allowPrerecordedDialoguePlayback'] is False
assert variant['variantID'] == 'broadcast_reading_lazy'
assert variant['reference']['textPath'] == 'ref_text.txt'
assert variant['reference']['normalizedAudioPath'] == 'ref_audio/normalized/ref_24000_mono.wav'
assert variant['qwenArtifacts']['status'] == 'notPrecomputed'
assert catalog['defaultVariantID'] == 'broadcast_reading_lazy'
text = (profile / 'variants/broadcast_reading_lazy/ref_text.txt').read_text().strip()
assert 'The gravitas plague spreads.' in text
assert 'If speech fails, do not negotiate.' in text
blob = json.dumps(registry)
assert 'big_mike_base_clone_v1' in blob
assert 'big_mike_base_clone_v1.qwenclone' in blob
assert 'allowFallback' in blob
PY

if rg -n "VoiceDesign|CustomVoice|system TTS|AVSpeechSynthesizer|fallback" "$PROFILE" >/tmp/turing_voicepackager_mvp_rg.txt 2>&1; then
  # allow explicit allowFallback false fields; block obvious route strings in profile metadata/catalog.
  if rg -n "VoiceDesign|CustomVoice|system TTS|AVSpeechSynthesizer" "$PROFILE" >/dev/null 2>&1; then
    cat /tmp/turing_voicepackager_mvp_rg.txt >&2
    fail "forbidden route string found in profile"
  fi
fi

pass "Big Mike .qwenclone MVP profile is packaged and registry is wired"
