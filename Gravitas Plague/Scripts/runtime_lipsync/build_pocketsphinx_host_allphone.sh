#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"
BUILD_ROOT="${REPOSITORY_DIR}/.build/runtime-lipsync"
SOURCE_DIR="${BUILD_ROOT}/source/pocketsphinx"
MACOS_BUILD="${BUILD_ROOT}/macos"
OUTPUT_DIR="${REPOSITORY_DIR}/.build/chapter03-angel-visemes"
OUTPUT_BIN="${OUTPUT_DIR}/pocketsphinx-host-allphone"

if [[ ! -f "${SOURCE_DIR}/include/pocketsphinx.h" ]]; then
  echo "Pinned PocketSphinx source is missing; run build_pocketsphinx_xcframework.sh first." >&2
  exit 2
fi

if [[ ! -f "${MACOS_BUILD}/libpocketsphinx.a" ]]; then
  cmake -S "${SOURCE_DIR}" -B "${MACOS_BUILD}" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_GSTREAMER=OFF \
    -DFIXED_POINT=OFF -DPS_THREAD_LOCAL_RNG=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "${MACOS_BUILD}" --config Release --target pocketsphinx --parallel
fi

mkdir -p "${OUTPUT_DIR}"
clang -O2 \
  -I "${SOURCE_DIR}/include" \
  -I "${MACOS_BUILD}/include" \
  -I "${SCRIPT_DIR}/bridge" \
  "${SCRIPT_DIR}/bridge/TuringPocketSphinxBridge.c" \
  "${SCRIPT_DIR}/host_allphone_main.c" \
  "${MACOS_BUILD}/libpocketsphinx.a" \
  -framework Accelerate \
  -o "${OUTPUT_BIN}"

echo "Built ${OUTPUT_BIN}"
