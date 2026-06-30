#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
python3 "$ROOT/Tools/TuringVoicePackager/turing_voicepackager_mvp.py" \
  --root "$ROOT" \
  --manifest "Authoring/Voices/BigMike/elevenlabs/big_mike_reading_manifest.json" \
  --update-voice-registry
