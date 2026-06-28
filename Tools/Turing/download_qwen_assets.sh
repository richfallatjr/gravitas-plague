#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

exec "${SCRIPT_DIR}/install_qwen_phase0_audio_only.sh" \
  --root "${ROOT}" \
  "$@"
