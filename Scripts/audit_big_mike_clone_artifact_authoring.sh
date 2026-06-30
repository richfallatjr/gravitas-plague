#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
PROFILE="$ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/BigMike/BaseClone/big_mike_base_clone_v1.qwenclone"
VARIANT="$PROFILE/variants/broadcast_reading_lazy"
ART="$VARIANT/qwen_artifacts"
FAIL=0
fail(){ echo "[audit] FAIL: $*" >&2; FAIL=1; }
pass(){ echo "[audit] pass: $*"; }

[[ -d "$PROFILE" ]] || fail "missing profile $PROFILE"
[[ -f "$VARIANT/ref_audio/normalized/ref_24000_mono.wav" ]] || fail "missing normalized ref wav"
[[ -f "$VARIANT/ref_text.txt" ]] || fail "missing ref_text.txt"
[[ -d "$ART" ]] || fail "missing qwen_artifacts directory"
[[ -f "$ART/clone_prompt_manifest.json" ]] || fail "missing clone_prompt_manifest.json"
[[ -f "$ART/clone_artifacts.safetensors" ]] || fail "missing clone_artifacts.safetensors"
[[ -f "$ART/speaker_embedding.f32le" ]] || fail "missing speaker_embedding.f32le"
[[ -f "$ART/reference_codes.i32le" ]] || fail "missing reference_codes.i32le"
[[ -f "$ART/ref_text_tokens.i32le" ]] || fail "missing ref_text_tokens.i32le"
[[ -f "$ART/checksums.sha256" ]] || fail "missing checksums.sha256"

if [[ -f "$ART/clone_prompt_manifest.json" ]]; then
python3 - "$ART/clone_prompt_manifest.json" <<'PY' || exit 1
import json, sys
p=sys.argv[1]
o=json.load(open(p))
assert o["schemaVersion"] == 1
assert o["artifactKind"] == "qwen3_tts_base_voice_clone_prompt"
assert o["voiceID"] == "big_mike_base_clone_v1"
assert o["variantID"] == "broadcast_reading_lazy"
assert o["mode"] == "icl"
assert o["xVectorOnlyMode"] is False
assert o["iclMode"] is True
assert o["runtimeModelID"] == "qwen3-tts-12hz-1.7b-base-4bit"
assert o["artifacts"]["referenceCodesShape"], "missing ref code shape"
assert o["artifacts"]["speakerEmbeddingShape"], "missing speaker embedding shape"
assert o["artifacts"]["refTextTokensShape"], "missing ref text token shape"
print("[audit] manifest ok")
PY
fi

# App/runtime must not implement raw WAV extraction as the preferred path after artifacts exist.
if rg -n "raw-reference runtime|decode ref WAV|speech-tokenizer encode ref audio|extract speaker embedding" "$ROOT/Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources" >/tmp/qwen_raw_ref_hits.$$ 2>/dev/null; then
  echo "[audit] WARN: raw-reference phrases found. Verify they are error messages or authoring-only, not active runtime fallback:" >&2
  cat /tmp/qwen_raw_ref_hits.$$ >&2
fi
rm -f /tmp/qwen_raw_ref_hits.$$

# Hard no fallbacks in Base clone path.
if rg -n "VoiceDesign|CustomVoice|nil-ref Base|system TTS|AVSpeechSynthesizer|play.*big-mike-clone-reading|ref_audio/normalized/ref_24000_mono.wav.*play" "$ROOT/Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources" >/tmp/qwen_fallback_hits.$$ 2>/dev/null; then
  echo "[audit] WARN: possible fallback/unwanted path references in QwenNative sources:" >&2
  cat /tmp/qwen_fallback_hits.$$ >&2
fi
rm -f /tmp/qwen_fallback_hits.$$

if [[ $FAIL -ne 0 ]]; then exit 1; fi
pass "Big Mike clone artifacts present"
