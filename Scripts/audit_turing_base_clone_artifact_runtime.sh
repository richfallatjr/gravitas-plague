#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: $0 /path/to/gravitas-plague" >&2
  exit 2
fi
cd "$ROOT"
fail=0
say(){ printf '%s\n' "$*"; }
check_file(){ if [[ ! -f "$1" ]]; then say "FAIL missing file: $1"; fail=1; else say "ok file: $1"; fi }
check_rg(){ local pat="$1"; local path="$2"; local desc="$3"; if rg -n "$pat" "$path" >/tmp/audit_rg.$$ 2>/dev/null; then say "ok $desc"; cat /tmp/audit_rg.$$ | head -5; else say "FAIL missing $desc ($pat in $path)"; fail=1; fi; rm -f /tmp/audit_rg.$$; }
forbid_rg(){ local pat="$1"; local path="$2"; local desc="$3"; if rg -n "$pat" "$path" >/tmp/audit_rg.$$ 2>/dev/null; then say "FAIL forbidden $desc"; cat /tmp/audit_rg.$$ | head -20; fail=1; else say "ok forbidden absent: $desc"; fi; rm -f /tmp/audit_rg.$$; }

NATIVE="Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative"
PROFILE="Gravitas Plague/TuringResources/Turing/Voices/Cloned/BigMike/BaseClone/big_mike_base_clone_v1.qwenclone"

check_file "$NATIVE/TuringQwenNativeBaseCloneEngine.swift"
check_file "$NATIVE/TuringQwenNativeCloneProfileLoader.swift"
check_file "$NATIVE/TuringQwenNativeQuantizedLinear.swift"
check_file "$NATIVE/TuringQwenNativeConfig.swift"
check_file "$PROFILE/metadata.json"
check_file "$PROFILE/selection-catalog.json"

check_rg "case[[:space:]]+base|voiceDesign|customVoice" "$NATIVE/TuringQwenNativeConfig.swift" "model family enum supports base"
check_rg "tts_model_type|ttsModelType" "$NATIVE/TuringQwenNativeConfig.swift" "config decodes tts_model_type"
check_rg "quantizedMatmul" "$NATIVE/TuringQwenNativeQuantizedLinear.swift" "4-bit backend uses MLX quantizedMatmul"
check_rg "group[_A-Za-z]*Size|group_size" "$NATIVE/TuringQwenNativeQuantizedLinear.swift" "quantized backend uses group size"
check_rg "bits" "$NATIVE/TuringQwenNativeQuantizedLinear.swift" "quantized backend uses bit width"
check_rg "clone_prompt_manifest|reference_codes|speaker_embedding|ref_text_tokens" "$NATIVE" "runtime loads precomputed clone artifacts"
check_rg "fixtureRowsUsed:[[:space:]]*false|fixtureRowsUsed = false|fixtureRowsUsed" "$NATIVE/TuringQwenNativeBaseCloneEngine.swift" "Base clone logs fixtureRowsUsed false"
check_rg "officialBaseICL|baseCloneICL|xVectorOnlyMode" "$NATIVE" "Base clone ICL mode is explicit"

forbid_rg "raw-reference runtime not implemented|Base clone raw-reference runtime not implemented|TODO:.*Base clone|fatalError\(|preconditionFailure\(" "$NATIVE/TuringQwenNativeBaseCloneEngine.swift" "placeholder/unimplemented Base clone runtime"
forbid_rg "VoiceDesign|voiceDesign|generateVoiceDesign" "$NATIVE/TuringQwenNativeBaseCloneEngine.swift" "Base clone engine must not call VoiceDesign"
forbid_rg "CustomVoice|customVoice" "$NATIVE/TuringQwenNativeBaseCloneEngine.swift" "Base clone engine must not call CustomVoice"
forbid_rg "system TTS|AVSpeechSynthesizer" "Gravitas Plague/Gravitas Plague/Turing" "system TTS fallback"
forbid_rg "expectedFixtureRows\[[^]]*1\.\." "$NATIVE" "fixture continuation rows in active runtime"
forbid_rg "play.*ref_24000|play.*big-mike-clone-reading|AudioFileResource.*ref_audio" "Gravitas Plague/Gravitas Plague/Turing" "playing reference audio as output"

if [[ -d "$PROFILE/variants/broadcast_reading_lazy/qwen_artifacts" ]]; then
  check_file "$PROFILE/variants/broadcast_reading_lazy/qwen_artifacts/clone_prompt_manifest.json"
  check_file "$PROFILE/variants/broadcast_reading_lazy/qwen_artifacts/reference_codes.i32le"
  check_file "$PROFILE/variants/broadcast_reading_lazy/qwen_artifacts/speaker_embedding.f32le"
  check_file "$PROFILE/variants/broadcast_reading_lazy/qwen_artifacts/ref_text_tokens.i32le"
else
  say "WARN qwen_artifacts missing; runtime should fail clearly until precompute script is run"
fi

if [[ "$fail" -ne 0 ]]; then
  say "audit failed"
  exit 1
fi
say "audit passed"
