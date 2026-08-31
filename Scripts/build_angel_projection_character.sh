#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPOSITORY_ROOT}/.tools/angel-projection-blendshape/bin/python"

"${REPOSITORY_ROOT}/Tools/AngelProjectionBlendshape/bootstrap.sh"
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" doctor
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" validate-target
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" build
"${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" validate-runtime

# The handoff's default command is the complete qualification path. Keep an
# explicit host-only escape hatch for fast asset iteration; production runs
# always include the RealityKit import probe and four-pose capture gate.
if [[ "${1:-}" != "--skip-capture" ]]; then
  "${PYTHON}" "${REPOSITORY_ROOT}/Scripts/angel_projection_blendshape.py" capture-poses
fi
