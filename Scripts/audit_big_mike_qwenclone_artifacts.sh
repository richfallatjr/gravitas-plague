#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: $0 /path/to/gravitas-plague" >&2
  exit 2
fi

cd "$ROOT"

PROFILE="Gravitas Plague/TuringResources/Turing/Voices/Cloned/BigMike/BaseClone/big_mike_base_clone_v1.qwenclone"
VARIANT="$PROFILE/variants/broadcast_reading_lazy"
ARTIFACTS="$VARIANT/qwen_artifacts"
MANIFEST="$ARTIFACTS/clone_prompt_manifest.json"

fail=0
check_file() {
  if [[ ! -s "$1" ]]; then
    echo "FAIL missing or empty: $1"
    fail=1
  else
    echo "ok file: $1"
  fi
}

check_file "$MANIFEST"
check_file "$ARTIFACTS/reference_codes.i32le"
check_file "$ARTIFACTS/speaker_embedding.f32le"
check_file "$ARTIFACTS/ref_text_tokens.i32le"
check_file "$ARTIFACTS/official_trace.json"
check_file "$ARTIFACTS/checksums.sha256"

if [[ -s "$MANIFEST" ]]; then
  python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())
required = [
    ("runtimeMode", "baseCloneICL"),
    ("xVectorOnlyMode", False),
    ("voiceID", "big_mike_base_clone_v1"),
    ("variantID", "broadcast_reading_lazy"),
]
for key, expected in required:
    actual = manifest.get(key)
    if actual != expected:
        raise SystemExit(f"FAIL manifest {key}: expected {expected!r}, got {actual!r}")

ref_codes = manifest["referenceCodes"]
if ref_codes.get("shape", [0, 0])[-1] != 16:
    raise SystemExit(f"FAIL reference code shape: {ref_codes.get('shape')}")
if ref_codes.get("shape", [0])[0] <= 0:
    raise SystemExit("FAIL reference code rows are empty")
if manifest["speakerEmbedding"].get("shape", [0])[0] <= 0:
    raise SystemExit("FAIL speaker embedding is empty")
if manifest["refTextTokens"].get("shape", [0])[0] <= 0:
    raise SystemExit("FAIL ref text tokens are empty")

print("ok manifest: baseCloneICL artifacts have non-empty shapes")
PY
fi

if [[ "$fail" -ne 0 ]]; then
  echo "audit_big_mike_qwenclone_artifacts failed"
  exit 1
fi

(
  cd "$ARTIFACTS"
  shasum -a 256 -c checksums.sha256
)

echo "audit_big_mike_qwenclone_artifacts passed"
