#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ -d /Users/richardfallat/Downloads/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/richardfallat/Downloads/Xcode-beta.app/Contents/Developer
fi

CAPTURE_ID=angel_head_v1
DERIVED_DATA="$REPO_ROOT/.build/mind-eye-projection/DerivedData"
STAGING="$REPO_ROOT/.build/mind-eye-projection/$CAPTURE_ID"
FINAL="$REPO_ROOT/Authoring/MindEyeProjectionCaptures/$CAPTURE_ID"
RUNTIME_ROOT="$REPO_ROOT/Gravitas Plague/TuringResources/Turing/MindsEye/Projection"
COMMIT="$(git rev-parse HEAD)"
if [[ -n "$(git status --short)" ]]; then WORKTREE_DIRTY=1; else WORKTREE_DIRTY=0; fi

mkdir -p "$STAGING"
python3 Scripts/mind_eye_projection/resolve_visionos_simulator.py \
  --output "$STAGING/simulator.json"
UDID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$STAGING/simulator.json")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

build_app() {
  xcodebuild \
    -project "Gravitas Plague/Gravitas Plague.xcodeproj" \
    -scheme "Gravitas Plague" \
    -sdk xrsimulator \
    -destination "platform=visionOS Simulator,id=$UDID" \
    -configuration Debug \
    ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) GR_MIND_EYE_PROJECTION_AUTHORING' \
    'EXCLUDED_SOURCE_FILE_NAMES=Turing *.wav *.mp3 *.m4a *.aac *.aiff *.caf *.usdz *.reality *.png *.jpg *.jpeg *.safetensors *.bin *.npy *.npz' \
    -derivedDataPath "$DERIVED_DATA" \
    build

  python3 Scripts/mind_eye_projection/locate_built_app.py \
    --derived-data "$DERIVED_DATA" \
    --output "$STAGING/build.json"
  APP_PATH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appPath"])' "$STAGING/build.json")"
  BUNDLE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleID"])' "$STAGING/build.json")"
  # Authoring never starts Turing. Package only the two scene assets and tiny
  # JSON contracts it consumes, excluding the multi-gigabyte model payload.
  mkdir -p \
    "$APP_PATH/Turing/MindsEye/Projection" \
    "$APP_PATH/Turing/Chapters/Chapter03"
  cp "$REPO_ROOT/angel_posed_01.usdz" "$APP_PATH/angel_posed_01.usdz"
  cp "$REPO_ROOT/heaven-sunrise.exr" "$APP_PATH/heaven-sunrise.exr"
  cp -R "$RUNTIME_ROOT/profiles" "$APP_PATH/Turing/MindsEye/Projection/"
  cp -R "$RUNTIME_ROOT/cameras" "$APP_PATH/Turing/MindsEye/Projection/"
  cp -R "$RUNTIME_ROOT/targets" "$APP_PATH/Turing/MindsEye/Projection/"
  cp -R "$RUNTIME_ROOT/masks" "$APP_PATH/Turing/MindsEye/Projection/"
  cp \
    "$REPO_ROOT/Gravitas Plague/TuringResources/Turing/Chapters/Chapter03/chapter03_light_tunnel_test.json" \
    "$APP_PATH/Turing/Chapters/Chapter03/chapter03_light_tunnel_test.json"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP_PATH"
}

run_job() {
  local job="$1"
  local output="$STAGING/$job"
  python3 - "$output" <<'PY'
import os, shutil, sys
path = os.path.realpath(sys.argv[1])
if os.path.exists(path):
    shutil.rmtree(path)
PY
  SIMCTL_CHILD_GR_REPOSITORY_COMMIT="$COMMIT" \
  SIMCTL_CHILD_GR_WORKTREE_DIRTY="$WORKTREE_DIRTY" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$STAGING/$job.stdout.log" \
      --stderr="$STAGING/$job.stderr.log" \
      "$UDID" \
      "$BUNDLE_ID" \
      "--mind-eye-projection-job=$job" \
      "--mind-eye-projection-capture-id=$CAPTURE_ID"
  python3 Scripts/mind_eye_projection/wait_for_capture.py \
    --udid "$UDID" \
    --bundle-id "$BUNDLE_ID" \
    --capture-id "$CAPTURE_ID" \
    --timeout-seconds 120 \
    --copy-to "$output"
}

build_app
run_job inspect-subject

# The runtime target descriptor is generated from the owner-authored framing
# cube. The hierarchy report remains useful evidence, but must never overwrite
# that more precise camera-control contract with whole-body visual bounds.
python3 - "$RUNTIME_ROOT/targets/$CAPTURE_ID.target.json" <<'PY'
import json, pathlib, sys
target = json.loads(pathlib.Path(sys.argv[1]).read_text())
if "authoringFramingControl" not in target:
    raise SystemExit("cube-driven authoringFramingControl is missing")
print("Using owner-authored camera framing cube:",
      target["authoringFramingControl"]["controlPrimPath"])
PY

# Rebuild so camera resolution uses the inspected, exact target descriptor.
build_app
run_job resolve-camera

python3 Scripts/mind_eye_projection/publish_projection_camera.py \
  --candidate "$STAGING/resolve-camera/$CAPTURE_ID.camera.json" \
  --target "$RUNTIME_ROOT/cameras/$CAPTURE_ID.camera.json" \
  --profile "$RUNTIME_ROOT/profiles/$CAPTURE_ID.json" \
  --target-descriptor "$RUNTIME_ROOT/targets/$CAPTURE_ID.target.json"

# Rebuild so final capture consumes the exact runtime-bundled camera bytes.
build_app
run_job capture-reference

python3 - "$STAGING/capture-reference" "$FINAL" <<'PY'
import os, shutil, sys
source, final = map(os.path.realpath, sys.argv[1:])
stage = final + ".stage"
if os.path.exists(stage):
    shutil.rmtree(stage)
os.makedirs(os.path.dirname(final), exist_ok=True)
shutil.copytree(source, stage)
if os.path.exists(final):
    shutil.rmtree(final)
os.replace(stage, final)
PY

python3 Scripts/mind_eye_projection/validate_projection_capture.py \
  --directory "$FINAL" \
  --runtime-camera "$RUNTIME_ROOT/cameras/$CAPTURE_ID.camera.json"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
printf '\nMind’s Eye projection capture complete:\n%s\n' "$FINAL"
