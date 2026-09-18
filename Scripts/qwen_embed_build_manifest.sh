#!/bin/bash
set -euo pipefail
qwen_repo_dir="$(cd -- "${SRCROOT}/.." && pwd)"
qwen_args=(embed --repo "$qwen_repo_dir"
  --output "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/qwen-build-manifest.json"
  --configuration "${CONFIGURATION}")
if [[ -n "${QWEN_BUILD_MANIFEST_PATH:-}" ]]; then
  qwen_args+=(--manifest "$QWEN_BUILD_MANIFEST_PATH")
fi
exec python3 "$qwen_repo_dir/scripts/turing/qwen_build_provenance.py" "${qwen_args[@]}"
