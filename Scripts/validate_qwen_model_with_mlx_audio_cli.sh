#!/usr/bin/env bash
set -euo pipefail

ROOT=""
MODEL_PATH=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="$2"; shift 2 ;;
    --model)
      MODEL_PATH="$2"; shift 2 ;;
    --out)
      OUT_DIR="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROOT" || -z "$MODEL_PATH" ]]; then
  echo "Usage: $0 --root /path/to/repo --model /path/to/Qwen3-TTS-model [--out /path/to/out]" >&2
  exit 2
fi

if [[ ! -d "$ROOT" ]]; then
  echo "Repo root does not exist: $ROOT" >&2
  exit 1
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "Model path does not exist: $MODEL_PATH" >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT/TuringQwenKnownImplementationValidation"
fi

mkdir -p "$OUT_DIR"

for file in config.json model.safetensors; do
  if [[ ! -s "$MODEL_PATH/$file" ]]; then
    echo "Missing or empty required model file: $MODEL_PATH/$file" >&2
    exit 1
  fi
done

if [[ ! -d "$MODEL_PATH/speech_tokenizer" ]]; then
  echo "Missing speech_tokenizer directory: $MODEL_PATH/speech_tokenizer" >&2
  exit 1
fi

VENV="$ROOT/.venv-qwen-mlx-audio"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install --upgrade "huggingface_hub[hf_xet]" mlx-audio

echo "[QwenKnownMac] versions"
python - <<'PY'
import importlib.metadata as md

for package in ["mlx", "mlx-audio", "huggingface_hub"]:
    try:
        print(f"  {package}: {md.version(package)}")
    except Exception as error:
        print(f"  {package}: unavailable ({error})")
PY

echo "[QwenKnownMac] running mlx-audio CLI"
python -m mlx_audio.tts.generate \
  --model "$MODEL_PATH" \
  --text "Hello world" \
  --file-prefix "$OUT_DIR/hello_world"

echo "[QwenKnownMac] output files"
find "$OUT_DIR" -maxdepth 1 -type f -print -exec ls -lh {} \;

if ! find "$OUT_DIR" -maxdepth 1 -type f \( -name 'hello_world*.wav' -o -name 'hello_world*.flac' -o -name 'hello_world*.mp3' \) -size +1000c | grep -q .; then
  echo "No non-empty hello_world audio output found in $OUT_DIR" >&2
  exit 1
fi

echo "[QwenKnownMac] PASS"
