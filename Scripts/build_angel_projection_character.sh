#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPOSITORY_ROOT}/.tools/angel-projection-blendshape/bin/python"

"${REPOSITORY_ROOT}/Tools/AngelProjectionBlendshape/bootstrap.sh"
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" doctor
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" validate-target
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" build
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" validate-runtime

if [[ "${1:-}" == "--capture-poses" ]]; then
  "${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" capture-poses
fi
