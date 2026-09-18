#!/bin/bash
set -euo pipefail
qwen_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$qwen_script_dir/turing/qwen_build_provenance.py" verify "$@"
