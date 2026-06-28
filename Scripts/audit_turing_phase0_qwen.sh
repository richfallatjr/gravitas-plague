#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
CONFIG_DIR="$ROOT/Gravitas Plague/TuringResources/Turing/Config"
APP_DIR="$ROOT/Gravitas Plague/Gravitas Plague/Turing"

fail() {
  echo "[TuringPhase0Audit] ERROR: $1" >&2
  exit 1
}

[[ -d "$CONFIG_DIR" ]] || fail "Config directory not found: $CONFIG_DIR"
[[ -d "$APP_DIR" ]] || fail "Turing app directory not found: $APP_DIR"

if grep -R --line-number '"voiceArgument"[[:space:]]*:[[:space:]]*"' "$CONFIG_DIR"; then
  fail "Phase 0 config must not contain a string voiceArgument."
fi

if grep -R --line-number '"qwenVoiceArgument"[[:space:]]*:[[:space:]]*"' "$CONFIG_DIR"; then
  fail "Phase 0 voice registry must not contain a string qwenVoiceArgument."
fi

if grep -R --line-number 'Ryan\|Aiden' "$CONFIG_DIR"; then
  fail "Phase 0 config must not mention Ryan or Aiden. Named voices are not Phase 0."
fi

if grep -R --line-number 'voice:[[:space:]]*qwenVoiceArgument\|voice:[[:space:]]*voiceArgument' "$APP_DIR"; then
  fail "Phase 0 generation must not forward a variable voice argument."
fi

echo "[TuringPhase0Audit] OK: Phase 0 Qwen smoke config has no named voice argument."
