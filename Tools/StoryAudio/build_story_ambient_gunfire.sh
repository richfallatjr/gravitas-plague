#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="$REPO_ROOT/Authoring/Audio/StoryAmbientGunfire/Source"
DESTINATION_DIR="$REPO_ROOT/Gravitas Plague/TuringResources/Turing/Audio/story-ambient-gunfire"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/story-gunfire.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

files=(
  automatic-pistol-01.wav
  automatic-pistol-02.wav
  automatic-pistol-03.wav
  automatic-pistol-04.wav
  automatic-pistol-05.wav
  pistol-volley-01.wav
  rifle-1-01.wav
  rifle-1-02.wav
  rifle-1-03.wav
  rifle-1-04.wav
  rifle-1-05.wav
  rifle-3-01.wav
  rifle-3-02.wav
  semi-auto-rifle-01.wav
  semi-auto-rifle-02.wav
  semi-auto-rifle-03.wav
  shotgun-01.wav
  shotgun-02.wav
  shotgun-2-01.wav
  distant-01.wav
  distant-02.wav
  distant-03.wav
  distant-04.wav
  distant-05.wav
  distant-06.wav
  distant-07.wav
)

for tool in ffmpeg ffprobe shasum; do
  command -v "$tool" >/dev/null || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

discovered_count="$(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.wav' -print | wc -l | tr -d ' ')"
if [[ "$discovered_count" -ne "${#files[@]}" ]]; then
  echo "Expected ${#files[@]} source WAVs, found $discovered_count." >&2
  exit 1
fi

for file in "${files[@]}"; do
  source="$SOURCE_DIR/$file"
  output="$TEMP_DIR/$file"
  [[ -f "$source" ]] || {
    echo "Missing source WAV: $source" >&2
    exit 1
  }

  ffmpeg -hide_banner -loglevel error -y \
    -i "$source" \
    -af 'pan=mono|c0=0.5*c0+0.5*c1' \
    -ar 48000 \
    -c:a pcm_s16le \
    "$output"

  codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$output")"
  sample_rate="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$output")"
  channels="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$output")"
  duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$output")"

  [[ "$codec" == "pcm_s16le" && "$sample_rate" == "48000" && "$channels" == "1" ]] || {
    echo "Invalid production WAV: $file codec=$codec rate=$sample_rate channels=$channels" >&2
    exit 1
  }

  echo "$file"
  echo "  sourceSHA256=$(shasum -a 256 "$source" | awk '{print $1}')"
  echo "  outputSHA256=$(shasum -a 256 "$output" | awk '{print $1}')"
  echo "  duration=$duration sampleRate=$sample_rate channels=$channels codec=$codec"
done

mkdir -p "$DESTINATION_DIR"
for file in "${files[@]}"; do
  mv "$TEMP_DIR/$file" "$DESTINATION_DIR/$file"
done

echo "Installed ${#files[@]} production WAVs in $DESTINATION_DIR"
