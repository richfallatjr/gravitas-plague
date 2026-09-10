#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPOSITORY_ROOT}/.tools/angel-projection-blendshape/bin/python"

"${REPOSITORY_ROOT}/Tools/AngelProjectionBlendshape/bootstrap.sh"
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/spouse_vocal_blendshape.py" doctor
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/spouse_vocal_blendshape.py" validate-donor

case "${1:-}" in
  "")
    "${PYTHON}" "${REPOSITORY_ROOT}/Scripts/spouse_vocal_blendshape.py" build
    ;;
  --check-only)
    ;;
  *)
    echo "Usage: $0 [--check-only]" >&2
    exit 64
    ;;
esac

"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/spouse_vocal_blendshape.py" validate-runtime
