#!/bin/bash
set -euo pipefail

PROJECTION_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTION_REPO_ROOT="$(cd "$PROJECTION_SCRIPT_DIR/../.." && pwd)"
cd "$PROJECTION_REPO_ROOT"

GR_MIND_EYE_JOB_ONLY=material-parity \
  "$PROJECTION_SCRIPT_DIR/capture_angel_projection_reference.sh"

PROJECTION_SOURCE="$PROJECTION_REPO_ROOT/.build/mind-eye-projection/angel_head_v1/material-parity"
PROJECTION_QUALIFICATION="$PROJECTION_SOURCE/angel_head_v1.material-parity.json"
PROJECTION_RUNTIME="$PROJECTION_REPO_ROOT/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/qualification/angel_head_v1.material-parity.json"
PROJECTION_EVIDENCE="$PROJECTION_REPO_ROOT/Authoring/MindEyeProjectionQualification/angel_head_v1"

python3 - "$PROJECTION_QUALIFICATION" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
if not value.get("passed"):
    raise SystemExit(
        "material parity failed: "
        f"RMSE={value.get('RMSELinearRGB')} "
        f"p99={value.get('p99AbsoluteErrorLinearRGB')} "
        f"max={value.get('maximumAbsoluteErrorLinearRGB')} "
        f"PSNR={value.get('PSNRDecibels')}"
    )
PY

mkdir -p "$PROJECTION_EVIDENCE"
cp "$PROJECTION_SOURCE"/*.png "$PROJECTION_EVIDENCE/"
cp "$PROJECTION_QUALIFICATION" "$PROJECTION_RUNTIME"
cp "$PROJECTION_QUALIFICATION" "$PROJECTION_EVIDENCE/"

python3 Scripts/mind_eye_projection/validate_projection_source.py \
  --repository-root "$PROJECTION_REPO_ROOT"

printf '\nAngel material parity qualified:\n%s\n' "$PROJECTION_RUNTIME"
