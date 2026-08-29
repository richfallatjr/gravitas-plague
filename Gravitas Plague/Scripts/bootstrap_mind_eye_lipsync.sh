#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLCHAIN_ROOT="${PROJECT_ROOT}/.mind-eye-toolchains"
MFA_PREFIX="${TOOLCHAIN_ROOT}/mfa"
PYTHON_VENV="${TOOLCHAIN_ROOT}/python"
MODEL_ROOT="${TOOLCHAIN_ROOT}/mfa-models"
SOURCE_TOOLCHAIN="${SCRIPT_DIR}/mind_eye_lipsync/toolchain"
MICROMAMBA="${TOOLCHAIN_ROOT}/bin/micromamba"
MFA_LOCK="${SOURCE_TOOLCHAIN}/mfa-lock-osx-arm64.yml"
REQUIREMENTS_LOCK="${SOURCE_TOOLCHAIN}/requirements.lock.txt"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Mind's Eye Phase 6 bootstrap requires native arm64." >&2
  exit 2
fi

mkdir -p "${TOOLCHAIN_ROOT}/bin" "${MODEL_ROOT}"
if [[ ! -x "${MICROMAMBA}" ]]; then
  archive="${TOOLCHAIN_ROOT}/micromamba-osx-arm64.tar.bz2"
  curl --fail --location --silent --show-error \
    "https://micro.mamba.pm/api/micromamba/osx-arm64/latest" \
    --output "${archive}"
  tar -xjf "${archive}" -C "${TOOLCHAIN_ROOT}" bin/micromamba
fi

if [[ ! -x "${MFA_PREFIX}/bin/mfa" ]]; then
  if [[ -s "${MFA_LOCK}" ]]; then
    "${MICROMAMBA}" create --yes --prefix "${MFA_PREFIX}" --file "${MFA_LOCK}"
  else
    "${MICROMAMBA}" create --yes --prefix "${MFA_PREFIX}" \
      --file "${SOURCE_TOOLCHAIN}/mfa-environment.yml"
  fi
fi

lock_tmp="${MFA_LOCK}.tmp"
"${MICROMAMBA}" list --prefix "${MFA_PREFIX}" --explicit > "${lock_tmp}"
mv "${lock_tmp}" "${MFA_LOCK}"

if [[ ! -x "${PYTHON_VENV}/bin/python" ]]; then
  "${MFA_PREFIX}/bin/python" -m venv --system-site-packages "${PYTHON_VENV}"
fi

if [[ ! -s "${REQUIREMENTS_LOCK}" ]]; then
  "${MFA_PREFIX}/bin/python" -m pip install --disable-pip-version-check \
    'pip-tools>=7.4,<8'
  "${MFA_PREFIX}/bin/python" -m piptools compile \
    --generate-hashes \
    --resolver=backtracking \
    --pip-args='--only-binary=:all: --platform=macosx_14_0_arm64 --python-version=3.11 --implementation=cp --no-cache-dir' \
    --output-file "${REQUIREMENTS_LOCK}.tmp" \
    "${SOURCE_TOOLCHAIN}/requirements.in"
  mv "${REQUIREMENTS_LOCK}.tmp" "${REQUIREMENTS_LOCK}"
fi
"${PYTHON_VENV}/bin/python" -m pip install --disable-pip-version-check \
  --require-hashes -r "${REQUIREMENTS_LOCK}"

export MFA_ROOT_DIR="${MODEL_ROOT}"
"${MFA_PREFIX}/bin/mfa" model download --version 3.0.0 acoustic english_us_arpa
"${MFA_PREFIX}/bin/mfa" model download --version 3.0.0 dictionary english_us_arpa
"${MFA_PREFIX}/bin/mfa" model download --version 2.0.0a g2p english_us_arpa
"${MFA_PREFIX}/bin/mfa" model inspect acoustic english_us_arpa
"${MFA_PREFIX}/bin/mfa" model inspect dictionary english_us_arpa
"${MFA_PREFIX}/bin/mfa" model inspect g2p english_us_arpa

XCODE_DEVELOPER_DIR="$(xcode-select --print-path)"
if [[ "${XCODE_DEVELOPER_DIR}" == *"CommandLineTools"* ]]; then
  XCODE_APP="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' | head -n 1)"
  if [[ -z "${XCODE_APP}" || ! -d "${XCODE_APP}/Contents/Developer" ]]; then
    echo "A full Xcode installation is required to compile the AVFoundation parity probe." >&2
    exit 2
  fi
  XCODE_DEVELOPER_DIR="${XCODE_APP}/Contents/Developer"
fi
DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun swiftc -O -framework AVFoundation \
  "${SCRIPT_DIR}/mind_eye_audio_timeline_probe.swift" \
  -o "${TOOLCHAIN_ROOT}/bin/mind-eye-audio-timeline-probe"

"${PYTHON_VENV}/bin/python" \
  "${SCRIPT_DIR}/generate_mind_eye_frame_manifests.py" \
  bootstrap-lock --toolchain-root "${TOOLCHAIN_ROOT}"
"${PYTHON_VENV}/bin/python" \
  "${SCRIPT_DIR}/generate_mind_eye_frame_manifests.py" \
  doctor --toolchain-root "${TOOLCHAIN_ROOT}" --json
