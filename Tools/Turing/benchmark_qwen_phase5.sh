#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 OUTPUT.json [quick|full]" >&2
  exit 64
fi

output_path=$1
suite=${2:-quick}
case "$suite" in
  quick|full) ;;
  *)
    echo "suite must be quick or full" >&2
    exit 64
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
package_root="$repo_root/Gravitas Plague/Gravitas Plague/Turing/QwenNative"
model_root="$repo_root/Gravitas Plague/TuringResources/Turing/Models/Qwen3TTS/Qwen3-TTS-12Hz-1.7B-Base-4bit"
bundle_root="$repo_root/Gravitas Plague/TuringResources"

if [ ! -d "$model_root" ]; then
  echo "Qwen model root not found at $model_root" >&2
  exit 66
fi
if [ ! -d "$bundle_root" ]; then
  echo "Turing resource root not found at $bundle_root" >&2
  exit 66
fi

swift build \
  --package-path "$package_root" \
  -c release \
  --product turing-qwen-benchmark

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
if [ "$metallib_path" != "" ] && [ ! -f "$metallib_path" ]; then
  echo "TURING_MLX_METALLIB is not a file: $metallib_path" >&2
  exit 66
fi

if [ "$metallib_path" = "" ]; then
  for search_root in \
    "$package_root/.build" \
    "$repo_root/.build"
  do
    [ -d "$search_root" ] || continue
    metallib_path=$(find "$search_root" -type f \
      \( -path '*/mlx-swift_Cmlx.bundle/default.metallib' \
         -o -name mlx.metallib \) \
      -print -quit 2>/dev/null || true)
    [ "$metallib_path" = "" ] || break
  done
fi

if [ "$metallib_path" = "" ]; then
  derived_data_root=${TURING_XCODE_DERIVED_DATA:-"$HOME/Library/Developer/Xcode/DerivedData"}
  for search_root in "$derived_data_root"/Gravitas_Plague-*
  do
    [ -d "$search_root" ] || continue
    metallib_path=$(find "$search_root" -type f \
      -path '*/mlx-swift_Cmlx.bundle/default.metallib' \
      -print -quit 2>/dev/null || true)
    [ "$metallib_path" = "" ] || break
  done
fi

if [ "$metallib_path" = "" ] || [ ! -f "$metallib_path" ]; then
  echo "MLX Metal library not found. Build the app/package once with Xcode or set TURING_MLX_METALLIB to its default.metallib or mlx.metallib." >&2
  exit 69
fi

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/turing-qwen-phase5.XXXXXX")
cleanup() {
  rm -rf -- "$run_dir"
}
trap cleanup EXIT HUP INT TERM

cp "$benchmark_binary" "$run_dir/turing-qwen-benchmark"
cp "$metallib_path" "$run_dir/mlx.metallib"

label=$(git -C "$repo_root" rev-parse --short=12 HEAD)
"$run_dir/turing-qwen-benchmark" \
  --mode phase5-matrix \
  --model-root "$model_root" \
  --bundle-root "$bundle_root" \
  --output "$output_path" \
  --suite "$suite" \
  --label "$label-phase5-$suite"
