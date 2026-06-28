#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_ARG="${ROOT:-$(pwd)}"
if [[ $# -gt 0 ]]; then
  exec "$SCRIPT_DIR/install_qwen_phase0_one_active_model.sh" "$@"
else
  exec "$SCRIPT_DIR/install_qwen_phase0_one_active_model.sh" \
    --root "$ROOT_ARG" \
    --variant 8bit
fi

# Turing Phase 0 Qwen audio-only asset installer.
# Installs exactly one runtime model for visionOS:
#   mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit
# It intentionally does NOT install cloning, CustomVoice, VoiceDesign, reference audio,
# .plaguevoice profiles, Python runtime, PyTorch, or any fallback TTS path.

ROOT="${ROOT:-$(pwd)}"
RESOURCE_ROOT="$ROOT/Gravitas Plague/TuringResources/Turing"
MODEL_ROOT="$RESOURCE_ROOT/Models/Qwen3TTS"
CONFIG_ROOT="$RESOURCE_ROOT/Config"
VOICE_ROOT="$RESOURCE_ROOT/Voices"

MODEL_HF_REPO="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
MODEL_DIR_NAME="Qwen3-TTS-12Hz-0.6B-Base-8bit"
MODEL_REGISTRY_ID="qwen3-tts-12hz-0.6b-base-8bit"
MODEL_QUANTIZATION="8bit"
MODEL_FAMILY="qwen3-tts-12hz-base"
MODEL_TYPE="qwen3_tts"
PURGE_INCOMPATIBLE=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --root PATH             Repo root. Defaults to current directory.
  --resource-root PATH    Turing resource root override.
  --no-purge              Do not delete incompatible/non-Phase-0 model folders.
  -h, --help              Show help.

Installs only:
  $MODEL_HF_REPO

Phase 0 exclusions:
  - no 1.7B 4-bit
  - no CustomVoice
  - no VoiceDesign
  - no cloning/reference audio
  - no .plaguevoice profiles
  - no Python/PyTorch runtime in app resources
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="$2"
      RESOURCE_ROOT="$ROOT/Gravitas Plague/TuringResources/Turing"
      MODEL_ROOT="$RESOURCE_ROOT/Models/Qwen3TTS"
      CONFIG_ROOT="$RESOURCE_ROOT/Config"
      VOICE_ROOT="$RESOURCE_ROOT/Voices"
      shift 2
      ;;
    --resource-root)
      RESOURCE_ROOT="$2"
      MODEL_ROOT="$RESOURCE_ROOT/Models/Qwen3TTS"
      CONFIG_ROOT="$RESOURCE_ROOT/Config"
      VOICE_ROOT="$RESOURCE_ROOT/Voices"
      shift 2
      ;;
    --no-purge)
      PURGE_INCOMPATIBLE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$MODEL_ROOT" "$CONFIG_ROOT" "$VOICE_ROOT/Library" "$VOICE_ROOT/Cloned"

if [[ "$PURGE_INCOMPATIBLE" == "1" ]]; then
  echo "Purging non-Phase-0 Qwen model folders from app resources..."
  rm -rf \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-1.7B-Base-4bit" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-1.7B-Base-bf16" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-0.6B-Base-4bit" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit" \
    "$MODEL_ROOT/Qwen3-TTS-12Hz-0.6B-VoiceDesign-bf16" \
    "$RESOURCE_ROOT/AuthoringModels" \
    "$RESOURCE_ROOT/Models/VoiceDesign" \
    "$RESOURCE_ROOT/Models/CustomVoice" || true
fi

VENV="$ROOT/.venv-hf-turing-phase0"
python3 -m venv "$VENV"
# shellcheck source=/dev/null
source "$VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install --upgrade "huggingface_hub[hf_xet]"

DEST="$MODEL_ROOT/$MODEL_DIR_NAME"
mkdir -p "$DEST"

echo "Downloading $MODEL_HF_REPO"
echo "Destination: $DEST"
hf download "$MODEL_HF_REPO" --local-dir "$DEST"

MODEL_SHA=$(python - <<PY
from huggingface_hub import HfApi
repo = "$MODEL_HF_REPO"
info = HfApi().model_info(repo)
print(info.sha or "UNKNOWN")
PY
)

python - <<PY
import hashlib
import json
import pathlib
import sys
import time

root = pathlib.Path(r"$DEST")
required = [
    "config.json",
    "generation_config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "speech_tokenizer",
]
missing = []
for rel in required:
    path = root / rel
    if not path.exists():
        missing.append(rel)
if missing:
    print("Missing required Qwen Phase 0 model assets:", file=sys.stderr)
    for rel in missing:
        print(f"  - {rel}", file=sys.stderr)
    sys.exit(1)

files = []
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    rel = path.relative_to(root).as_posix()
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    files.append({
        "path": rel,
        "bytes": path.stat().st_size,
        "sha256": h.hexdigest(),
    })
manifest = {
    "schemaVersion": 1,
    "createdAtUnix": int(time.time()),
    "modelID": "$MODEL_REGISTRY_ID",
    "huggingFaceRepo": "$MODEL_HF_REPO",
    "revision": "$MODEL_SHA",
    "family": "$MODEL_FAMILY",
    "modelType": "$MODEL_TYPE",
    "quantization": "$MODEL_QUANTIZATION",
    "phase0AudioOnly": True,
    "forbiddenRuntimeFeatures": [
        "cloning",
        "referenceAudio",
        "plaguevoiceProfiles",
        "CustomVoice",
        "VoiceDesign",
        "systemTTSFallback",
        "cpuFallback",
    ],
    "files": files,
}
(root / "turing-checksums.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

cat > "$CONFIG_ROOT/model-registry.json" <<JSON
{
  "schemaVersion": 3,
  "activeModelID": "$MODEL_REGISTRY_ID",
  "qwenModels": [
    {
      "id": "$MODEL_REGISTRY_ID",
      "displayName": "Qwen3-TTS 12Hz 0.6B Base 8-bit Phase 0",
      "huggingFaceRepo": "$MODEL_HF_REPO",
      "revision": "$MODEL_SHA",
      "resourcePath": "Turing/Models/Qwen3TTS/$MODEL_DIR_NAME",
      "modelType": "$MODEL_TYPE",
      "family": "$MODEL_FAMILY",
      "parameterClass": "0.6B",
      "quantization": "$MODEL_QUANTIZATION",
      "swiftSupportStatus": "documented",
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
      "notes": "Phase 0 proves local Qwen/MLX audio generation using bare Base smoke only: voice=nil, refAudio=nil, refText=nil."
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

cat > "$CONFIG_ROOT/turing-runtime.json" <<JSON
{
  "schemaVersion": 3,
  "foundation": {
    "maxParallelRequests": 4,
    "maxChunkTokens": 2000,
    "aggregateBudgetTokens": 1250,
    "perChunkMetadataOverheadCharacters": 120
  },
  "tts": {
    "modelID": "$MODEL_REGISTRY_ID",
    "generationMode": "bareBaseSmoke",
    "synthesisMode": "sequential",
    "phase0AudioOnly": true,
    "targetSegmentSecondsMin": 3.0,
    "targetSegmentSecondsMax": 5.0,
    "maxSegmentsBeforeSplit": 5,
    "requireGPU": true,
    "allowCPUFallback": false,
    "language": "English",
    "maxTokens": 512,
    "temperature": 0.7,
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

cat > "$CONFIG_ROOT/voice-registry.json" <<JSON
{
  "schemaVersion": 3,
  "activeVoiceID": "qwen_phase0_default",
  "voices": [
    {
      "id": "qwen_phase0_default",
      "displayName": "Qwen Phase 0 Default",
      "kind": "library",
      "revision": "builtin-default-v1",
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

echo
cat <<DONE
Turing Phase 0 Qwen audio-only assets installed.

Model:
  $MODEL_HF_REPO
Revision:
  $MODEL_SHA
Resource root:
  $RESOURCE_ROOT

Next required app step:
  Run the native in-app Metal canary. It must generate one WAV and play it
  through the existing GravitasDemoAudioController path. Do not promote this
  to Story runtime until that canary passes on device.
DONE
