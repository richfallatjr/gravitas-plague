#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install exactly one active Qwen3-TTS Phase 0 model for Gravitas Plague.

Usage:
  install_qwen_phase0_one_active_model.sh --root /path/to/gravitas-plague [--variant 8bit|bf16]

Default variant: 8bit

This script purges inactive Qwen3-TTS model folders from the app resource folder
so Vision Pro builds do not carry multiple Qwen models.
EOF
}

ROOT=""
VARIANT="8bit"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:-}"; shift 2 ;;
    --variant)
      VARIANT="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  echo "Missing --root" >&2
  usage
  exit 2
fi

case "$VARIANT" in
  8bit)
    MODEL_ID="qwen3-tts-12hz-0.6b-base-8bit"
    HF_REPO="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    QUANTIZATION="8bit"
    DISPLAY_NAME="Qwen3-TTS 12Hz 0.6B Base 8-bit Phase 0"
    EXPECTED_SIZE_GB="1.99"
    ;;
  bf16)
    MODEL_ID="qwen3-tts-12hz-0.6b-base-bf16"
    HF_REPO="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16"
    QUANTIZATION="bf16"
    DISPLAY_NAME="Qwen3-TTS 12Hz 0.6B Base bf16 Phase 0"
    EXPECTED_SIZE_GB="2.51"
    ;;
  *)
    echo "Unsupported --variant '$VARIANT'. Use 8bit or bf16." >&2
    exit 2
    ;;
esac

RESOURCE_ROOT="$ROOT/Gravitas Plague/TuringResources/Turing"
MODEL_PARENT="$RESOURCE_ROOT/Models/Qwen3TTS"
MODEL_DIR="$MODEL_PARENT/$(basename "$HF_REPO")"
CONFIG_DIR="$RESOURCE_ROOT/Config"
MANIFEST_DIR="$MODEL_DIR/TuringMetadata"

mkdir -p "$MODEL_PARENT" "$CONFIG_DIR" "$MANIFEST_DIR"

echo "[Phase0Install] Root: $ROOT"
echo "[Phase0Install] Active model: $HF_REPO ($EXPECTED_SIZE_GB GB listed by Hugging Face)"
echo "[Phase0Install] Purging inactive Qwen3-TTS model folders from app resources..."
find "$MODEL_PARENT" -mindepth 1 -maxdepth 1 -type d ! -name "$(basename "$HF_REPO")" -print -exec rm -rf {} +

VENV="$ROOT/.venv-hf"
if [[ ! -d "$VENV" ]]; then
  python3 -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip >/dev/null
python -m pip install -U "huggingface_hub[hf_xet]" >/dev/null

if ! command -v hf >/dev/null 2>&1; then
  echo "hf CLI was not installed into the venv." >&2
  exit 1
fi

echo "[Phase0Install] Downloading with hf download..."
hf download "$HF_REPO" --local-dir "$MODEL_DIR"

REVISION=$(python - <<PY
from huggingface_hub import HfApi
api = HfApi()
info = api.model_info("$HF_REPO")
print(info.sha)
PY
)

printf "%s\n" "$REVISION" > "$MANIFEST_DIR/model-revision.txt"

REQUIRED=(
  "config.json"
  "model.safetensors"
  "tokenizer_config.json"
  "generation_config.json"
  "vocab.json"
  "merges.txt"
  "speech_tokenizer"
)
for item in "${REQUIRED[@]}"; do
  if [[ ! -e "$MODEL_DIR/$item" ]]; then
    echo "Missing required model asset: $MODEL_DIR/$item" >&2
    exit 1
  fi
done

(
  cd "$MODEL_DIR"
  find . -type f \
    ! -path './.cache/*' \
    ! -path './TuringMetadata/checksums.sha256' \
    -print0 | sort -z | xargs -0 shasum -a 256
) > "$MANIFEST_DIR/checksums.sha256"

cat > "$CONFIG_DIR/model-registry.json" <<JSON
{
  "schemaVersion": 3,
  "activeModelID": "$MODEL_ID",
  "qwenModels": [
    {
      "id": "$MODEL_ID",
      "displayName": "$DISPLAY_NAME",
      "huggingFaceRepo": "$HF_REPO",
      "revision": "$REVISION",
      "resourcePath": "Turing/Models/Qwen3TTS/$(basename "$HF_REPO")",
      "modelType": "qwen3_tts",
      "family": "qwen3-tts-12hz-base",
      "parameterClass": "0.6B",
      "quantization": "$QUANTIZATION",
      "swiftSupportStatus": "phase0_local_package_override_required",
      "phase0RuntimeAllowed": true,
      "requiresGPU": true,
      "allowCPUFallback": false,
      "voiceArgumentPolicy": "baseNilOnly",
      "refAudioPolicy": "phase0NilOnly",
      "refTextPolicy": "phase0NilOnly",
      "customVoiceAllowed": false,
      "voiceDesignAllowed": false,
      "cloneProfilesAllowed": false,
      "requiresMetalCanaryPass": true,
      "metalCanaryStatus": "notRun",
      "notes": "Phase 0 proves local Qwen/MLX audio generation using the vendored mlx-audio-swift Turing host-safe sampler patch. Bare Base smoke only: voice=nil, refAudio=nil, refText=nil."
    }
  ],
  "blockedModels": [
    {
      "id": "qwen3-tts-12hz-1.7b-base-4bit",
      "reason": "Current device log aborts inside Metal validation during generate(). Do not include in Phase 0 app resources."
    },
    {
      "id": "qwen3-tts-12hz-1.7b-voicedesign-bf16",
      "reason": "VoiceDesign is a later macOS-authoring phase, not Phase 0 headset smoke."
    },
    {
      "id": "qwen3-tts-12hz-1.7b-customvoice-bf16",
      "reason": "CustomVoice/cloning is a later phase, not Phase 0 headset smoke."
    }
  ]
}
JSON

cat > "$CONFIG_DIR/turing-runtime.json" <<JSON
{
  "schemaVersion": 3,
  "foundation": {
    "maxParallelRequests": 4,
    "maxChunkTokens": 2000,
    "aggregateBudgetTokens": 1250,
    "perChunkMetadataOverheadCharacters": 120
  },
  "tts": {
    "modelID": "$MODEL_ID",
    "generationMode": "bareBaseSmoke",
    "synthesisMode": "sequential",
    "phase0AudioOnly": true,
    "targetSegmentSecondsMin": 3.0,
    "targetSegmentSecondsMax": 5.0,
    "maxSegmentsBeforeSplit": 5,
    "requireGPU": true,
    "allowCPUFallback": false,
    "language": "English",
    "maxTokens": 96,
    "temperature": 0.0,
    "topP": 1.0,
    "repetitionPenalty": 1.0,
    "voiceArgumentPolicy": "baseNilOnly",
    "refAudioPolicy": "phase0NilOnly",
    "refTextPolicy": "phase0NilOnly"
  },
  "debug": {
    "enableMemoryMetrics": true,
    "soakTestIterations": 20,
    "phase0SmokeText": "Hello from Qwen3-TTS."
  }
}
JSON

cat > "$CONFIG_DIR/voice-registry.json" <<JSON
{
  "schemaVersion": 3,
  "activeVoiceID": "qwen_phase0_default",
  "voices": [
    {
      "id": "qwen_phase0_default",
      "displayName": "Qwen Phase 0 Default",
      "kind": "library",
      "revision": "$REVISION",
      "resourcePath": null,
      "qwenVoiceArgument": null,
      "refAudioPath": null,
      "refText": null,
      "phase0RuntimeAllowed": true,
      "notes": "No cloning. No reference audio. Phase 0 bare Base smoke forwards voice=nil, refAudio=nil, and refText=nil."
    }
  ]
}
JSON

echo "[Phase0Install] Installed $HF_REPO"
echo "[Phase0Install] Revision $REVISION"
echo "[Phase0Install] Wrote schemaVersion 3 config files under $CONFIG_DIR"
echo "[Phase0Install] Only one active model directory remains under $MODEL_PARENT"
