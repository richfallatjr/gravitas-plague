#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-.}"
PROJECT_ROOT="$ROOT/Gravitas Plague"

BAD_PATTERNS=(
  "zombie-breathing-loop"
  "robot-damaged-01"
  "robot-damaged-02"
  "robot-walking-loop"
  "fleshy-face-punch-01"
)

ALLOWED_PATHS=(
  "CharacterLibrary/Characters"
  "CharacterAttributes"
)

for pattern in "${BAD_PATTERNS[@]}"; do
  hits=$(find "$PROJECT_ROOT" \
    -path "*/.build" -prune -o \
    -name "*.swift" -type f -print0 |
    xargs -0 grep -H "$pattern" || true)

  if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
      allowed=false

      for allowed_path in "${ALLOWED_PATHS[@]}"; do
        if [[ "$line" == *"$allowed_path"* ]]; then
          allowed=true
        fi
      done

      if [[ "$allowed" == false ]]; then
        echo "[CharacterAudioRouting] ERROR hardcoded sound outside sidecar/router:"
        echo "$line"
        exit 1
      fi
    done <<< "$hits"
  fi
done

echo "[CharacterAudioRouting] OK"
