#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${REPOSITORY_DIR}/Gravitas Plague"
PYTHON="${REPOSITORY_DIR}/.mind-eye-toolchains/python/bin/python"
DRIVER="${PROJECT_DIR}/Scripts/generate_dad_vocal_visemes.py"
SOURCE="${REPOSITORY_DIR}/Tools/DadVocalVisemeCompiler/main.swift"
BUILD_DIR="${REPOSITORY_DIR}/.build/dad-vocal-viseme-compiler"
EXECUTABLE="${BUILD_DIR}/DadVocalVisemeCompiler"

if [[ ! -x "${PYTHON}" ]]; then
  echo "Pinned Mind's Eye Python toolchain is missing: ${PYTHON}" >&2
  exit 2
fi

CMAKE_DIR="${REPOSITORY_DIR}/.build/runtime-lipsync/tools/cmake/data/bin"
MEDIA_DIR="${REPOSITORY_DIR}/.mind-eye-toolchains/mfa/bin"
[[ -d "${MEDIA_DIR}" ]] && export PATH="${MEDIA_DIR}:${PATH}"
[[ -x "${CMAKE_DIR}/cmake" ]] && export PATH="${CMAKE_DIR}:${PATH}"

mkdir -p "${BUILD_DIR}"
if [[ ! -x "${EXECUTABLE}" || "${SOURCE}" -nt "${EXECUTABLE}" ]]; then
  SWIFTC="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    xcrun --sdk macosx --find swiftc)"
  SDK="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    xcrun --sdk macosx --show-sdk-path)"
  "${SWIFTC}" \
    -target arm64-apple-macosx15.0 \
    -sdk "${SDK}" \
    "${SOURCE}" \
    -o "${EXECUTABLE}"
fi

exec "${EXECUTABLE}" \
  --repository-root "${REPOSITORY_DIR}" \
  --python "${PYTHON}" \
  --driver "${DRIVER}" \
  "$@"
