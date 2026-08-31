#!/bin/bash
set -euo pipefail

PROJECTION_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTION_REPO_ROOT="$(cd "$PROJECTION_SCRIPT_DIR/../.." && pwd)"
cd "$PROJECTION_REPO_ROOT"

PROJECTION_PYTHON="$PROJECTION_REPO_ROOT/.tools/angel-projection-blendshape/bin/python"
PROJECTION_ASSET="$PROJECTION_REPO_ROOT/angel_posed_01.usdz"
PROJECTION_TARGET="$PROJECTION_REPO_ROOT/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/targets/angel_head_v1.target.json"
PROJECTION_CONTRACT="$PROJECTION_REPO_ROOT/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/materials/angel_head_v1.pbr-binding.json"

"$PROJECTION_PYTHON" Scripts/mind_eye_projection/extract_angel_pbr_contract.py \
  --asset "$PROJECTION_ASSET" \
  --target "$PROJECTION_TARGET" \
  --output "$PROJECTION_CONTRACT"
"$PROJECTION_PYTHON" Scripts/mind_eye_projection/validate_angel_pbr_contract.py \
  --asset "$PROJECTION_ASSET" \
  --target "$PROJECTION_TARGET" \
  --contract "$PROJECTION_CONTRACT"

# This publishes the qualification only after every numeric gate passes. A
# failed A/B render stops here and leaves the production fail-soft gate closed.
"$PROJECTION_SCRIPT_DIR/qualify_angel_projection_material.sh"

GR_MIND_EYE_JOB_ONLY=coordinate-space-proof \
  "$PROJECTION_SCRIPT_DIR/capture_angel_projection_reference.sh"

PROJECTION_PROOF="$PROJECTION_REPO_ROOT/.build/mind-eye-projection/angel_head_v1/coordinate-space-proof"
python3 - "$PROJECTION_PROOF/angel_head_v1.coordinate-space-proof.json" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if len(set(report["checkerFrameSHA256"])) < 2:
    raise SystemExit("coordinate proof checker did not respond to deformation")
if report["receiverUVSetName"] != "primvars:st" or report["receiverUVSetIndex"] != 0:
    raise SystemExit("coordinate proof used the wrong receiver UV set")
print("PASS simulator coordinate-space evidence; physical Vision Pro proof remains required")
PY

python3 Scripts/mind_eye_projection/audit_angel_projection_runtime_resources.py \
  --repository-root "$PROJECTION_REPO_ROOT"

printf '\nAngel material and coordinate evidence:\n%s\n%s\n' \
  "$PROJECTION_REPO_ROOT/.build/mind-eye-projection/angel_head_v1/material-parity" \
  "$PROJECTION_PROOF"
