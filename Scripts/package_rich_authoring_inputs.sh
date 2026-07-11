#!/usr/bin/env bash
set -euo pipefail

GRAVITAS_ROOT="${1:-/Users/richardfallat/Projects/dev/gravitas-plague}"
REF_SOURCE="${2:-$GRAVITAS_ROOT/rich-clone-ref-fast.mp3}"
FILLER_SOURCE="${3:-$GRAVITAS_ROOT/rich-filler}"
SP02_SOURCE="${4:-$GRAVITAS_ROOT/pr-script-point-02-rich.mp3}"
SP03_SOURCE="${5:-$GRAVITAS_ROOT/pr-script-point-03-big-mike.mp3}"

PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Rich/BaseClone/rich_base_clone_v1.qwenclone"
VARIANT="$PROFILE/variants/rich_reference_01"
ORIGINAL="$VARIANT/ref_audio/original/rich-clone-ref-fast.mp3"
NORMALIZED="$VARIANT/ref_audio/normalized/ref_24000_mono.wav"
FILLER_DEST="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Audio/rich-filler"
PR_DEST="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Audio/prerecordings"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required."
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is required."

[[ -s "$REF_SOURCE" ]] || fail "Missing Rich reference MP3: $REF_SOURCE"
[[ -d "$FILLER_SOURCE" ]] || fail "Missing Rich filler source directory: $FILLER_SOURCE"
[[ -s "$SP02_SOURCE" ]] || fail "Missing Rich ScriptPoint02 PR MP3: $SP02_SOURCE"
[[ -s "$SP03_SOURCE" ]] || fail "Missing ScriptPoint03 PR MP3: $SP03_SOURCE"
[[ -s "$VARIANT/ref_text.txt" ]] || fail "Missing exact Rich reference transcript: $VARIANT/ref_text.txt"
[[ -s "$PROFILE/metadata.json" ]] || fail "Missing Rich metadata.json"
[[ -s "$VARIANT/variant.json" ]] || fail "Missing Rich variant.json"

mkdir -p "$(dirname "$ORIGINAL")"
mkdir -p "$(dirname "$NORMALIZED")"
mkdir -p "$FILLER_DEST"
mkdir -p "$PR_DEST"

# Preserve the original reference bytes exactly.
cp -f "$REF_SOURCE" "$ORIGINAL"
cmp -s "$REF_SOURCE" "$ORIGINAL" || fail "Original Rich reference copy is not byte-identical."

# Speed-preserving format normalization only. Never use atempo, asetrate, rubberband,
# or any filter that changes reference timing.
ffmpeg -hide_banner -loglevel error -y \
  -i "$ORIGINAL" \
  -map_metadata -1 \
  -vn \
  -ac 1 \
  -ar 24000 \
  -c:a pcm_f32le \
  "$NORMALIZED"

sample_rate="$(ffprobe -v error -select_streams a:0 \
  -show_entries stream=sample_rate \
  -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED")"
channels="$(ffprobe -v error -select_streams a:0 \
  -show_entries stream=channels \
  -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED")"
format_name="$(ffprobe -v error -show_entries format=format_name \
  -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED")"

[[ "$sample_rate" == "24000" ]] || fail "Normalized Rich reference is not 24 kHz."
[[ "$channels" == "1" ]] || fail "Normalized Rich reference is not mono."
[[ "$format_name" == *"wav"* ]] || fail "Normalized Rich reference is not WAV."

rm -rf "$FILLER_DEST"
mkdir -p "$FILLER_DEST"

supported_count=0
while IFS= read -r -d '' source_file; do
  extension="${source_file##*.}"
  extension="$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')"
  case "$extension" in
    wav|mp3|m4a|aiff|aif|caf)
      base="$(basename "$source_file")"
      stem="${base%.*}"
      suffix="${stem##*_}"
      [[ "$suffix" =~ ^[0-9]+$ ]] || fail "Rich filler lacks trailing numeric weight: $base"
      (( suffix >= 1 && suffix <= 10 )) || fail "Rich filler weight must be 1...10: $base"
      cp -f "$source_file" "$FILLER_DEST/$base"
      supported_count=$((supported_count + 1))
      ;;
    sesx)
      # Authoring-only file. Deliberately ignored.
      ;;
    *)
      ;;
  esac
done < <(find "$FILLER_SOURCE" -type f -print0)

(( supported_count > 0 )) || fail "No supported Rich filler audio was copied."

cp -f "$SP02_SOURCE" "$PR_DEST/pr-rich-script-point-02.mp3"
cp -f "$SP03_SOURCE" "$PR_DEST/pr-big-mike-script-point-03.mp3"

[[ -s "$PR_DEST/pr-rich-script-point-02.mp3" ]] || fail "Rich ScriptPoint02 copy failed."
[[ -s "$PR_DEST/pr-big-mike-script-point-03.mp3" ]] || fail "ScriptPoint03 copy failed."

printf 'Rich authoring inputs packaged successfully.\n'
printf '  reference original: %s\n' "$ORIGINAL"
printf '  reference normalized: %s\n' "$NORMALIZED"
printf '  filler files: %s\n' "$supported_count"
printf '  ScriptPoint02: %s\n' "$PR_DEST/pr-rich-script-point-02.mp3"
printf '  ScriptPoint03: %s\n' "$PR_DEST/pr-big-mike-script-point-03.mp3"
