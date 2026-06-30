#!/usr/bin/env bash
set -euo pipefail

ROOT=""
OUT_REL="ExternalReference/Qwen3-TTS-official"
REPO_URL="https://github.com/QwenLM/Qwen3-TTS.git"
COMMIT="main"

usage() {
  cat <<USAGE
Usage: $0 --root /path/to/gravitas-plague [--out ExternalReference/Qwen3-TTS-official] [--commit <sha-or-main>]

Clones or updates the official Qwen3-TTS reference repo outside the app target and writes a lock file.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --out) OUT_REL="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  echo "--root is required" >&2
  usage
  exit 2
fi

cd "$ROOT"
mkdir -p "$(dirname "$OUT_REL")"

if [[ ! -d "$OUT_REL/.git" ]]; then
  git clone "$REPO_URL" "$OUT_REL"
fi

cd "$OUT_REL"
git fetch --all --tags --prune
git checkout "$COMMIT"
ACTUAL_COMMIT="$(git rev-parse HEAD)"

REQUIRED=(
  "qwen_tts/inference/qwen3_tts_model.py"
  "qwen_tts/inference/qwen3_tts_tokenizer.py"
  "qwen_tts/core/models/modeling_qwen3_tts.py"
  "qwen_tts/core/models/configuration_qwen3_tts.py"
  "qwen_tts/core/tokenizer_12hz/modeling_qwen3_tts_tokenizer_v2.py"
  "qwen_tts/core/tokenizer_12hz/configuration_qwen3_tts_tokenizer_v2.py"
  "examples/test_model_12hz_voice_design.py"
  "README.md"
  "pyproject.toml"
)

MISSING=0
for file in "${REQUIRED[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing required official reference file: $file" >&2
    MISSING=1
  fi
done
if [[ "$MISSING" -ne 0 ]]; then
  echo "Official repo layout is not the expected Qwen3-TTS layout. Stop." >&2
  find qwen_tts -maxdepth 4 -type f | sort >&2 || true
  exit 1
fi

LOCK_DIR="$ROOT/Gravitas Plague/Gravitas Plague/Turing/QwenNative/Reference"
mkdir -p "$LOCK_DIR"
python3 - <<PY
import hashlib, json, pathlib, subprocess
root = pathlib.Path(r"$ROOT")
repo = root / r"$OUT_REL"
required = [
  "qwen_tts/inference/qwen3_tts_model.py",
  "qwen_tts/inference/qwen3_tts_tokenizer.py",
  "qwen_tts/core/models/modeling_qwen3_tts.py",
  "qwen_tts/core/models/configuration_qwen3_tts.py",
  "qwen_tts/core/tokenizer_12hz/modeling_qwen3_tts_tokenizer_v2.py",
  "qwen_tts/core/tokenizer_12hz/configuration_qwen3_tts_tokenizer_v2.py",
  "examples/test_model_12hz_voice_design.py",
  "README.md",
  "pyproject.toml",
]
file_hashes = {}
for rel in required:
    data = (repo / rel).read_bytes()
    file_hashes[rel] = hashlib.sha256(data).hexdigest()
lock = {
    "schemaVersion": 1,
    "repoURL": "$REPO_URL",
    "resolvedCommit": "$ACTUAL_COMMIT",
    "requestedCommit": "$COMMIT",
    "referencePath": str(repo),
    "fileSHA256": file_hashes,
}
out = pathlib.Path(r"$LOCK_DIR") / "qwen-reference-lock.json"
out.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
print(out)
PY

echo "Official Qwen reference locked at $ACTUAL_COMMIT"
