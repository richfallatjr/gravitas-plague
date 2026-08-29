#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPOSITORY_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"
BUILD_DIR="${REPOSITORY_DIR}/.build/runtime-lipsync"
SOURCE_DIR="${BUILD_DIR}/source/pocketsphinx"
OUTPUT_DIR="${PROJECT_DIR}/ThirdParty/TuringPocketSphinx"
XCFRAMEWORK="${OUTPUT_DIR}/PocketSphinx.xcframework"
EXPECTED_COMMIT="511126b492dcb267cf30d49d631946d7b61a9530"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/richardfallat/Downloads/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

CMAKE_BIN="$(command -v cmake || true)"
if [[ -z "${CMAKE_BIN}" && -x "${BUILD_DIR}/tools/cmake/data/bin/cmake" ]]; then
    CMAKE_BIN="${BUILD_DIR}/tools/cmake/data/bin/cmake"
fi
if [[ -z "${CMAKE_BIN}" ]]; then
    echo "cmake 3.25 or newer is required" >&2
    exit 2
fi

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --branch v5.1.1 --depth 1 \
        https://github.com/cmusphinx/pocketsphinx.git "${SOURCE_DIR}"
fi

ACTUAL_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
if [[ "${ACTUAL_COMMIT}" != "${EXPECTED_COMMIT}" ]]; then
    echo "PocketSphinx commit mismatch: ${ACTUAL_COMMIT}" >&2
    exit 3
fi

if [[ -e "${XCFRAMEWORK}" && "${1:-}" != "--replace" ]]; then
    echo "Refusing to replace ${XCFRAMEWORK}; pass --replace" >&2
    exit 4
fi

rm -rf "${BUILD_DIR}/xros" "${BUILD_DIR}/xrsimulator" \
       "${BUILD_DIR}/combined" "${BUILD_DIR}/public-headers"
mkdir -p "${BUILD_DIR}/combined/xros" \
         "${BUILD_DIR}/combined/xrsimulator" \
         "${BUILD_DIR}/public-headers"

for SDK in xros xrsimulator; do
    "${CMAKE_BIN}" \
        -S "${SOURCE_DIR}" \
        -B "${BUILD_DIR}/${SDK}" \
        -DCMAKE_TOOLCHAIN_FILE="${SCRIPT_DIR}/cmake/visionos.toolchain.cmake" \
        -DTURING_APPLE_SDK="${SDK}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_GSTREAMER=OFF \
        -DFIXED_POINT=OFF \
        -DPS_THREAD_LOCAL_RNG=ON \
        -DCMAKE_BUILD_TYPE=Release
    "${CMAKE_BIN}" --build "${BUILD_DIR}/${SDK}" \
        --config Release --target pocketsphinx --parallel

    SDK_PATH="$(xcrun --sdk "${SDK}" --show-sdk-path)"
    CLANG="$(xcrun --sdk "${SDK}" --find clang)"
    if [[ "${SDK}" == "xros" ]]; then
        TARGET="arm64-apple-xros27.0"
    else
        TARGET="arm64-apple-xros27.0-simulator"
    fi
    "${CLANG}" \
        -target "${TARGET}" \
        -isysroot "${SDK_PATH}" \
        -O2 -fvisibility=hidden -ffunction-sections -fdata-sections \
        -I "${SOURCE_DIR}/include" \
        -I "${BUILD_DIR}/${SDK}/include" \
        -c "${SCRIPT_DIR}/bridge/TuringPocketSphinxBridge.c" \
        -o "${BUILD_DIR}/combined/${SDK}/TuringPocketSphinxBridge.o"
    /usr/bin/libtool -static \
        -o "${BUILD_DIR}/combined/${SDK}/libTuringPocketSphinx.a" \
        "${BUILD_DIR}/combined/${SDK}/TuringPocketSphinxBridge.o" \
        "${BUILD_DIR}/${SDK}/libpocketsphinx.a"
done

cp "${SCRIPT_DIR}/bridge/TuringPocketSphinxBridge.h" \
   "${BUILD_DIR}/public-headers/TuringPocketSphinxBridge.h"
cp "${SCRIPT_DIR}/bridge/module.modulemap" \
   "${BUILD_DIR}/public-headers/module.modulemap"

rm -rf "${XCFRAMEWORK}"
mkdir -p "${OUTPUT_DIR}"
xcodebuild -create-xcframework \
    -library "${BUILD_DIR}/combined/xros/libTuringPocketSphinx.a" \
    -headers "${BUILD_DIR}/public-headers" \
    -library "${BUILD_DIR}/combined/xrsimulator/libTuringPocketSphinx.a" \
    -headers "${BUILD_DIR}/public-headers" \
    -output "${XCFRAMEWORK}"

echo "Built ${XCFRAMEWORK}"
