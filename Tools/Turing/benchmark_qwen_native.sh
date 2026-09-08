#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 OUTPUT.json [quick|full] [BASELINE.json]" >&2
  exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
package_root="$repo_root/Gravitas Plague/Gravitas Plague/Turing/QwenNative"
model_root="$repo_root/Gravitas Plague/TuringResources/Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit"
bundle_root="$repo_root/Gravitas Plague/TuringResources"
output_path=$1
suite=${2:-quick}
baseline_path=${3:-}

swift build \
  --package-path "$package_root" \
  -c release

bin_dir=$(swift build \
  --package-path "$package_root" \
  -c release \
  --show-bin-path)
benchmark_binary="$bin_dir/turing-qwen-benchmark"

if [ ! -x "$benchmark_binary" ]; then
  echo "benchmark executable was not produced at $benchmark_binary" >&2
  exit 69
fi

metallib_path=${TURING_MLX_METALLIB:-}
if [ "$metallib_path" = "" ]; then
  metallib_path=$(find "$package_root/.build" -type f \
    \( -name default.metallib -o -name mlx.metallib \) \
    -print -quit 2>/dev/null || true)
fi

if [ "$metallib_path" = "" ] || [ ! -f "$metallib_path" ]; then
  echo "MLX Metal library not found. Build the app/package once with Xcode or set TURING_MLX_METALLIB to default.metallib/mlx.metallib." >&2
  exit 69
fi

run_dir=$(mktemp -d /private/tmp/turing-qwen-benchmark.XXXXXX)
trap 'rm -rf "$run_dir"' EXIT HUP INT TERM
cp "$benchmark_binary" "$run_dir/turing-qwen-benchmark"
cp "$metallib_path" "$run_dir/mlx.metallib"

set -- \
  --model-root "$model_root" \
  --bundle-root "$bundle_root" \
  --output "$output_path" \
  --suite "$suite" \
  --label "$(git -C "$repo_root" rev-parse --short=12 HEAD)-$suite"

if [ "$baseline_path" != "" ]; then
  set -- "$@" --baseline "$baseline_path"
fi

"$run_dir/turing-qwen-benchmark" "$@"
