#!/usr/bin/env bash
set -euo pipefail

# Developer-only asset installer for Gravitas Plague Turing Phase 0.
# This script may use Python and the Hugging Face CLI to DOWNLOAD assets.
# Do not add Python, qwen-tts, mlx-audio Python, or PyTorch to the app target.

ROOT="${ROOT:-$(pwd)}"
APP_ROOT="${APP_ROOT:-Gravitas Plague/Gravitas Plague}"
RESOURCE_ROOT="${RESOURCE_ROOT:-${ROOT}/Gravitas Plague/TuringResources/Turing}"

MODEL_ID="qwen3-tts-12hz-1.7b-base-4bit"
MODEL_REPO="${MODEL_REPO:-mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit}"
MODEL_REVISION="${MODEL_REVISION:-37e955a1deb861c088ae5f3a67043185f3d1a60c}"
MODEL_DIR="${MODEL_DIR:-${RESOURCE_ROOT}/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit}"
TOKENIZER_DIR="${TOKENIZER_DIR:-${RESOURCE_ROOT}/SpeechTokenizer/Qwen3-TTS-Tokenizer-12Hz}"
CONFIG_DIR="${CONFIG_DIR:-${RESOURCE_ROOT}/Config}"
VOICE_DIR="${VOICE_DIR:-${RESOURCE_ROOT}/Voices/Library}"

FORCE_CONFIG="${FORCE_CONFIG:-0}"
INSTALL_HF_CLI="${INSTALL_HF_CLI:-1}"

log() { printf '\n[TuringAssets] %s\n' "$*"; }
fail() { printf '\n[TuringAssets][ERROR] %s\n' "$*" >&2; exit 1; }

if [[ ! -d "${ROOT}" ]]; then
  fail "ROOT does not exist: ${ROOT}"
fi

mkdir -p "${MODEL_DIR}" "${TOKENIZER_DIR}" "${CONFIG_DIR}" "${VOICE_DIR}"

if [[ "${INSTALL_HF_CLI}" == "1" ]]; then
  log "Installing/updating Hugging Face Hub CLI with Xet support into the active Python environment."
  python3 -m pip install -U "huggingface_hub[hf_xet]"
fi

# User-site installs often land outside PATH. Add Python's scripts directory for this process.
PY_SCRIPTS_DIR="$(python3 - <<'PY'
import sysconfig
print(sysconfig.get_path('scripts') or '')
PY
)"
if [[ -n "${PY_SCRIPTS_DIR}" ]]; then
  export PATH="${PY_SCRIPTS_DIR}:${PATH}"
fi

command -v hf >/dev/null 2>&1 || fail "The 'hf' CLI was not found after installing huggingface_hub. Check Python/pip PATH."

log "Downloading pinned MLX Qwen model."
log "repo=${MODEL_REPO}"
log "revision=${MODEL_REVISION}"
log "destination=${MODEL_DIR}"
hf download "${MODEL_REPO}" \
  --revision "${MODEL_REVISION}" \
  --local-dir "${MODEL_DIR}"

[[ -f "${MODEL_DIR}/config.json" ]] || fail "Missing ${MODEL_DIR}/config.json"
[[ -f "${MODEL_DIR}/generation_config.json" ]] || fail "Missing ${MODEL_DIR}/generation_config.json"
[[ -f "${MODEL_DIR}/model.safetensors" ]] || fail "Missing ${MODEL_DIR}/model.safetensors"
[[ -d "${MODEL_DIR}/speech_tokenizer" ]] || fail "Missing ${MODEL_DIR}/speech_tokenizer; the Swift Qwen runtime needs the MLX tokenizer assets."

log "Copying bundled speech tokenizer into the Turing SpeechTokenizer resource slot."
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${MODEL_DIR}/speech_tokenizer/" "${TOKENIZER_DIR}/"
else
  rm -rf "${TOKENIZER_DIR}"
  mkdir -p "$(dirname "${TOKENIZER_DIR}")"
  cp -R "${MODEL_DIR}/speech_tokenizer" "${TOKENIZER_DIR}"
fi

log "Writing checksum manifests."
(
  cd "${MODEL_DIR}"
  find . -type f ! -name 'checksums.sha256' ! -name 'model-metadata.json' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 > checksums.sha256
)
(
  cd "${TOKENIZER_DIR}"
  find . -type f ! -name 'checksums.sha256' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 > checksums.sha256
)

MODEL_BYTES="$(python3 - <<PY
from pathlib import Path
root = Path(r'''${MODEL_DIR}''')
print(sum(p.stat().st_size for p in root.rglob('*') if p.is_file()))
PY
)"
DOWNLOADED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${MODEL_DIR}/model-metadata.json" <<JSON
{
  "schemaVersion": 1,
  "modelID": "${MODEL_ID}",
  "sourceRepository": "${MODEL_REPO}",
  "sourceRevision": "${MODEL_REVISION}",
  "quantization": "4bit",
  "format": "MLX safetensors",
  "license": "apache-2.0",
  "downloadedAt": "${DOWNLOADED_AT}",
  "byteCount": ${MODEL_BYTES},
  "tokenizerResourcePath": "Turing/SpeechTokenizer/Qwen3-TTS-Tokenizer-12Hz",
  "checksumManifest": "checksums.sha256"
}
JSON

write_file() {
  local path="$1"
  local tmp="$2"
  if [[ -f "${path}" && "${FORCE_CONFIG}" != "1" ]]; then
    log "Keeping existing ${path}. Set FORCE_CONFIG=1 to overwrite."
    rm -f "${tmp}"
  else
    mv "${tmp}" "${path}"
    log "Wrote ${path}."
  fi
}

MODEL_REGISTRY_TMP="${CONFIG_DIR}/model-registry.json.tmp"
cat > "${MODEL_REGISTRY_TMP}" <<JSON
{
  "schemaVersion": 1,
  "models": [
    {
      "id": "qwen3-tts-12hz-1.7b-base-4bit",
      "displayName": "Qwen3 TTS 12Hz 1.7B Base 4-bit MLX",
      "sourceRepository": "${MODEL_REPO}",
      "sourceRevision": "${MODEL_REVISION}",
      "resourcePath": "Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit",
      "tokenizerResourcePath": "Turing/SpeechTokenizer/Qwen3-TTS-Tokenizer-12Hz",
      "modelRevision": "${MODEL_REVISION}",
      "tokenizerRevision": "${MODEL_REVISION}:speech_tokenizer",
      "quantization": "4bit",
      "license": "apache-2.0",
      "checksumManifest": "Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit/checksums.sha256"
    }
  ]
}
JSON
write_file "${CONFIG_DIR}/model-registry.json" "${MODEL_REGISTRY_TMP}"

VOICE_REGISTRY_TMP="${CONFIG_DIR}/voice-registry.json.tmp"
cat > "${VOICE_REGISTRY_TMP}" <<JSON
{
  "schemaVersion": 1,
  "voices": [
    {
      "id": "phase0_ryan_dev",
      "kind": "library",
      "resourcePath": "qwen-preset:Ryan",
      "revision": "qwen3-base-preset-ryan-v1"
    },
    {
      "id": "phase0_aiden_dev",
      "kind": "library",
      "resourcePath": "qwen-preset:Aiden",
      "revision": "qwen3-base-preset-aiden-v1"
    }
  ]
}
JSON
write_file "${CONFIG_DIR}/voice-registry.json" "${VOICE_REGISTRY_TMP}"

RUNTIME_TMP="${CONFIG_DIR}/turing-runtime.json.tmp"
cat > "${RUNTIME_TMP}" <<'JSON'
{
  "schemaVersion": 1,
  "foundation": {
    "maxParallelRequests": 4,
    "maxChunkTokens": 2000,
    "aggregateBudgetTokens": 1250,
    "perChunkMetadataOverheadCharacters": 120
  },
  "tts": {
    "modelID": "qwen3-tts-12hz-1.7b-base-4bit",
    "synthesisMode": "sequential",
    "targetSegmentSecondsMin": 3.0,
    "targetSegmentSecondsMax": 5.0,
    "maxSegmentsBeforeSplit": 5,
    "requireGPU": true,
    "allowCPUFallback": false,
    "language": "English",
    "sampleRate": 24000,
    "temperature": 0.7,
    "topP": 0.95,
    "maxTokens": 4096
  },
  "debug": {
    "enableMemoryMetrics": true,
    "soakTestIterations": 20,
    "maxPostWarmupGrowthMB": 300
  }
}
JSON
write_file "${CONFIG_DIR}/turing-runtime.json" "${RUNTIME_TMP}"

log "Done. Add these resource folders to the Gravitas Plague app target, preferably through Git LFS:"
printf '  %s\n' "${MODEL_DIR}" "${TOKENIZER_DIR}" "${CONFIG_DIR}"
log "Recommended Git LFS patterns:"
cat <<'TXT'
  git lfs track "Gravitas Plague/TuringResources/Turing/Models/**/*.safetensors"
  git lfs track "Gravitas Plague/TuringResources/Turing/SpeechTokenizer/**/*"
TXT
